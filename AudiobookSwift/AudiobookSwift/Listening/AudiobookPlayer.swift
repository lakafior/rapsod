// Pochodzenie: odtwarzacz przeniesiony z projektu Dove tego samego autora
// (`Packages/DoveKit/Sources/DoveAppCore/AudiobookPlayer.swift`, MPL-2.0) i dostosowany:
// jedna oś czasu książki z serwera audiobookshelf zamiast pozycji w pliku, rozdziały z serwera,
// kolejka plików w `AVQueuePlayer` (płynne przejścia), bez muzyki, iOS i zapisu pozycji
// w pęku kluczy (pozycję trzyma serwer — zob. `ListeningController`).

import AppKit
import AVFoundation
import MediaPlayer
import Observation

/// Odtwarzacz audiobooka: jeden plik (`.m4b`) albo wiele (`.mp3` po kolei) jako jedna oś czasu,
/// rozdziały, prędkość, przewijanie o stały odstęp, timer usypiania, „Teraz odtwarzane”
/// i klawisze multimedialne. Nie wie nic o serwerze: pliki dostaje przez `assetProvider`,
/// a o zmianach mówi przez `onEvent`.
@MainActor
@Observable
final class AudiobookPlayer {
    struct Track: Sendable, Hashable {
        enum Source: Sendable, Hashable {
            /// Plik prosto z dysku (serwer działa na tym samym Macu).
            case file(URL)
            /// Ścieżka względem adresu serwera (plik przez HTTP albo strumień HLS); wymaga tokenu.
            case remote(String)
        }

        /// Początek pliku na osi czasu książki — z serwera, nie z AVFoundation
        /// (długości plików według obu potrafią się różnić o ułamki sekund).
        let startOffset: Double
        let duration: Double
        let title: String
        var source: Source

        var end: Double { startOffset + duration }
    }

    struct Chapter: Sendable, Hashable, Identifiable {
        let id: Int
        let start: Double
        let end: Double
        let title: String

        var duration: Double { end - start }
    }

    /// Książka (albo odcinek podcastu) załadowana do odtwarzacza.
    struct Book: Sendable, Equatable {
        let itemID: String
        let episodeID: String?
        let title: String
        let author: String?
        let duration: Double
        var tracks: [Track]
        var chapters: [Chapter]

        var key: String { episodeID.map { "\(itemID)/\($0)" } ?? itemID }
    }

    enum Event {
        /// Odtwarzanie zatrzymane (pauza, timer usypiania, błąd).
        case paused
        /// Książka dobiegła końca.
        case finished
        /// Plik odtwarzany przez HTTP/HLS przestał działać (np. wygasł token) — trzeba go odbudować z nowym tokenem.
        case remoteFailed
    }

    enum SleepTimer: Hashable {
        case minutes(Int)
        /// Zatrzymuje się na końcu bieżącego rozdziału.
        case endOfChapter

        static let choices: [SleepTimer] = [.minutes(5), .minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfChapter]

        var label: String {
            switch self {
            case .minutes(let minutes): "\(minutes) min"
            case .endOfChapter: "Do końca rozdziału"
            }
        }
    }

    private(set) var book: Book?
    /// Pozycja na osi czasu całej książki (sekundy). Zmienia się dwa razy na sekundę —
    /// czytają ją tylko małe widoki z czasem, nie całe okno ani menu.
    private(set) var currentTime: Double = 0 {
        didSet {
            let id = Self.chapter(in: chapters, at: currentTime)?.id
            if id != currentChapterID { currentChapterID = id }
        }
    }
    /// Zmienia się tylko przy zmianie rozdziału — tę wartość czytają większe widoki.
    private(set) var currentChapterID: Int?
    private(set) var trackIndex = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    var error: String?

    /// Od ostatniej udanej synchronizacji pozycja zmieniła się przez odtwarzanie albo przewinięcie.
    /// Czyszczone przez `ListeningController` — pozycji, której odtwarzacz nie wytworzył,
    /// nie wolno wysyłać (nadpisałaby postęp z telefonu).
    @ObservationIgnored var isDirty = false
    /// Sekundy faktycznie przesłuchane (czas zegarowy) od ostatniego `takeListenedTime()`.
    @ObservationIgnored private var listened: Double = 0
    @ObservationIgnored private var lastTick: Date?

    var rate: Float {
        didSet {
            UserDefaults.standard.set(rate, forKey: Self.rateKey)
            player.defaultRate = rate
            if player.rate != 0 { player.rate = rate }
            updateNowPlaying()
        }
    }

    private(set) var sleepTimer: SleepTimer?
    private(set) var sleepDeadline: Date?
    @ObservationIgnored private var sleepChapter: Chapter?

    /// Okładka do „Teraz odtwarzane”; ustawia `ListeningController`.
    var artwork: NSImage? {
        didSet { nowPlayingArtwork = artwork.map(Self.makeArtwork); updateNowPlaying() }
    }

    /// Otwiera plik; `fresh` prosi o nowy token (poprzedni został odrzucony).
    @ObservationIgnored var assetProvider: (@MainActor (Track, _ fresh: Bool) async throws -> AVURLAsset)?
    @ObservationIgnored var onEvent: (@MainActor (Event) -> Void)?
    /// Strumień HLS: czeka, aż serwer przygotuje segment z czasem `local` (sekundy w strumieniu).
    @ObservationIgnored var waitForStream: (@MainActor (_ path: String, _ local: Double) async -> Void)?
    /// Pozycja z serwera przed wznowieniem, jeśli zmieniła się gdzie indziej; `nil` = bez zmian.
    @ObservationIgnored var resumeCheck: (@MainActor () async -> Double?)?

    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemObservers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    @ObservationIgnored private var statusObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    /// Który plik gra dany element kolejki.
    @ObservationIgnored private var itemTracks: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var enqueueTask: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?
    @ObservationIgnored private var commandsInstalled = false
    @ObservationIgnored private var retriedRemote = false

    private static let rateKey = "listeningRate"
    static let rates: [Float] = [0.8, 1, 1.1, 1.2, 1.3, 1.5, 1.75, 2, 2.5, 3]
    static let skipBack: Double = 15
    static let skipForward: Double = 30

    init() {
        let stored = UserDefaults.standard.float(forKey: Self.rateKey)
        rate = stored > 0 ? stored : 1
        player.defaultRate = rate
        player.actionAtItemEnd = .advance
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
    }

    // MARK: - Stan

    var chapters: [Chapter] { book?.chapters ?? [] }

    var currentChapter: Chapter? {
        chapters.first { $0.id == currentChapterID }
    }

    static func chapter(in chapters: [Chapter], at time: Double) -> Chapter? {
        chapters.last { $0.start <= time + 0.5 } ?? chapters.first
    }

    var duration: Double { book?.duration ?? 0 }

    /// Przesłuchane sekundy od poprzedniego wywołania (do `timeListened` w synchronizacji).
    func takeListenedTime() -> Double {
        defer { listened = 0 }
        return listened
    }

    /// Oddaje nieudaną synchronizację — czas wróci przy następnej próbie.
    func returnListenedTime(_ seconds: Double) {
        listened += seconds
    }

    // MARK: - Odtwarzanie

    /// Ładuje książkę i zaczyna od `position` (sekundy na osi całej książki).
    func start(_ book: Book, at position: Double, autoplay: Bool = true) {
        stop()
        self.book = book
        error = nil
        isDirty = false
        listened = 0
        retriedRemote = false
        installRemoteCommands()
        let start = min(max(0, position), max(0, book.duration - 1))
        load(at: start, autoplay: autoplay)
    }

    /// Wznawia odtwarzanie. Gdy od ostatniej synchronizacji nic się tu nie zmieniło, najpierw pyta
    /// `resumeCheck`, czy pozycja nie przesunęła się gdzie indziej (np. na telefonie).
    func play() {
        guard book != nil, !isLoading else { return }
        guard let resumeCheck, !isDirty else {
            resume()
            return
        }
        isLoading = true
        let key = book?.key
        Task {
            let position = await resumeCheck()
            isLoading = false
            guard book?.key == key else { return }
            if let position, abs(position - currentTime) > 1 {
                load(at: position, autoplay: true)
            } else {
                resume()
            }
        }
    }

    private func resume() {
        if player.currentItem == nil {
            load(at: currentTime, autoplay: true)
            return
        }
        player.playImmediately(atRate: rate)
        syncPlayingState()
    }

    func pause() {
        player.pause()
        syncPlayingState()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Zamyka książkę.
    func stop() {
        loadTask?.cancel()
        enqueueTask?.cancel()
        player.pause()
        clearQueue()
        book = nil
        isPlaying = false
        isLoading = false
        currentTime = 0
        trackIndex = 0
        lastTick = nil
        artwork = nil
        cancelSleepTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// Przewija do miejsca na osi czasu książki; między plikami ładuje właściwy plik.
    /// Nowe rozdziały bieżącej książki (edycja w oknie biblioteki); ścieżki i pozycja bez zmian.
    func replaceChapters(_ chapters: [Chapter]) {
        guard book != nil else { return }
        book?.chapters = chapters
        let id = Self.chapter(in: chapters, at: currentTime)?.id
        if id != currentChapterID { currentChapterID = id }
    }

    func seek(to time: Double) {
        guard let book else { return }
        let target = min(max(0, time), max(0, book.duration - 0.5))
        isDirty = true
        let index = Self.trackIndex(in: book.tracks, at: target)
        // Strumień z serwera (zwłaszcza transkodowany HLS) przewijamy, budując element od nowa:
        // przewinięcie trwającego strumienia HLS w aplikacji potrafiło nigdy się nie zakończyć,
        // a start od zadanej pozycji działa zawsze.
        let isRemote = if case .remote = book.tracks[index].source { true } else { false }
        if !isRemote, index == trackIndex, let item = player.currentItem, itemTracks[ObjectIdentifier(item)] == index, item.status == .readyToPlay {
            currentTime = target
            let local = localTime(target, in: book.tracks[index])
            Task {
                await player.seek(to: CMTime(seconds: local, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                updateNowPlaying()
            }
        } else {
            load(at: target, autoplay: isPlaying)
        }
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func jump(to chapter: Chapter) {
        seek(to: chapter.start)
        if !isPlaying { play() }
    }

    func nextChapter() {
        guard let current = currentChapter, let index = chapters.firstIndex(of: current), index + 1 < chapters.count else { return }
        jump(to: chapters[index + 1])
    }

    /// Początek bieżącego rozdziału albo poprzedni, gdy ten dopiero się zaczął.
    func previousChapter() {
        guard let current = currentChapter, let index = chapters.firstIndex(of: current) else { return }
        if currentTime - current.start > 3 || index == 0 {
            jump(to: current)
        } else {
            jump(to: chapters[index - 1])
        }
    }

    /// Odbudowuje bieżący plik z nowym tokenem (po wygaśnięciu tokenu w strumieniu HTTP/HLS).
    func reloadRemote() {
        guard book != nil else { return }
        load(at: currentTime, autoplay: isPlaying || isLoading, fresh: true)
    }

    // MARK: - Timer usypiania

    func setSleepTimer(_ timer: SleepTimer?) {
        sleepTimer = timer
        switch timer {
        case .minutes(let minutes):
            sleepDeadline = .now.addingTimeInterval(Double(minutes) * 60)
            sleepChapter = nil
        case .endOfChapter:
            sleepDeadline = nil
            sleepChapter = currentChapter
        case nil:
            sleepDeadline = nil
            sleepChapter = nil
        }
    }

    private func cancelSleepTimer() {
        setSleepTimer(nil)
    }

    private func sleepNow() {
        cancelSleepTimer()
        pause()
    }

    // MARK: - Pliki

    static func trackIndex(in tracks: [Track], at time: Double) -> Int {
        tracks.lastIndex { $0.startOffset <= time + 0.001 } ?? 0
    }

    /// Czas w pliku, przycięty do jego długości według serwera.
    private func localTime(_ time: Double, in track: Track) -> Double {
        min(max(0, time - track.startOffset), max(0, track.duration - 0.25))
    }

    /// Ładuje plik obejmujący `time` (i następny do kolejki) i przewija.
    private func load(at time: Double, autoplay: Bool, fresh: Bool = false) {
        guard let book, !book.tracks.isEmpty else { return }
        loadTask?.cancel()
        enqueueTask?.cancel()
        player.pause()
        clearQueue()
        let index = Self.trackIndex(in: book.tracks, at: time)
        let track = book.tracks[index]
        let key = book.key
        trackIndex = index
        currentTime = time
        isLoading = true
        lastTick = nil
        loadTask = Task {
            defer { if !Task.isCancelled { isLoading = false } }
            do {
                guard let assetProvider else { return }
                let asset = try await assetProvider(track, fresh)
                let local = localTime(time, in: track)
                if case .remote(let path) = track.source, path.hasSuffix(".m3u8") {
                    // AVPlayer nie ponawia segmentu, którego serwer jeszcze nie przetranskodował.
                    await waitForStream?(path, local)
                }
                guard !Task.isCancelled, self.book?.key == key else { return }
                let item = makeItem(asset, track: index)
                player.insert(item, after: nil)
                if local > 0 {
                    await player.seek(to: CMTime(seconds: local, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                guard !Task.isCancelled, self.book?.key == key else { return }
                if autoplay {
                    player.playImmediately(atRate: rate)
                }
                syncPlayingState()
                enqueue(after: index)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                isPlaying = false
                syncPlayingState()
            }
        }
    }

    /// Dokłada następny plik do kolejki, żeby przejście między plikami było bez przerwy.
    private func enqueue(after index: Int) {
        guard let book, book.tracks.indices.contains(index + 1), let assetProvider else { return }
        let next = index + 1
        let key = book.key
        enqueueTask?.cancel()
        enqueueTask = Task {
            guard let asset = try? await assetProvider(book.tracks[next], false),
                  !Task.isCancelled, self.book?.key == key,
                  let last = player.items().last, itemTracks[ObjectIdentifier(last)] == next - 1
            else { return }
            let item = makeItem(asset, track: next)
            if player.canInsert(item, after: last) {
                player.insert(item, after: last)
            }
        }
    }

    private func makeItem(_ asset: AVURLAsset, track: Int) -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        // Naturalny głos także przy 2× i więcej.
        item.audioTimePitchAlgorithm = .timeDomain
        let id = ObjectIdentifier(item)
        itemTracks[id] = track
        let center = NotificationCenter.default
        itemObservers[id] = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackEnded(id) }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.itemFailed(id, error: nil) }
            },
        ]
        statusObservations[id] = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription
            Task { @MainActor in self?.itemFailed(id, error: message) }
        }
        return item
    }

    private func forget(_ id: ObjectIdentifier) {
        itemObservers[id]?.forEach(NotificationCenter.default.removeObserver)
        itemObservers[id] = nil
        statusObservations[id]?.invalidate()
        statusObservations[id] = nil
        itemTracks[id] = nil
    }

    private func clearQueue() {
        player.removeAllItems()
        for id in Array(itemTracks.keys) { forget(id) }
    }

    /// Koniec pliku: `AVQueuePlayer` sam przechodzi do następnego z kolejki.
    private func trackEnded(_ id: ObjectIdentifier) {
        guard let book, let index = itemTracks[id] else { return }
        forget(id)
        if sleepTimer == .endOfChapter, let sleepChapter, sleepChapter.end <= book.tracks[index].end + 0.5 {
            // Rozdział kończy się razem z plikiem.
            trackIndex = min(index + 1, book.tracks.count - 1)
            currentTime = book.tracks[trackIndex].startOffset
            isDirty = true
            sleepNow()
            if index + 1 >= book.tracks.count { finish() }
            return
        }
        guard index + 1 < book.tracks.count else {
            finish()
            return
        }
        trackIndex = index + 1
        currentTime = book.tracks[index + 1].startOffset
        isDirty = true
        if let current = player.currentItem, itemTracks[ObjectIdentifier(current)] == index + 1 {
            enqueue(after: index + 1)
        } else {
            // Następny plik nie zdążył się załadować.
            load(at: currentTime, autoplay: true)
        }
    }

    private func finish() {
        player.pause()
        clearQueue()
        currentTime = duration
        isDirty = false
        syncPlayingState()
        onEvent?(.finished)
        // Następne „Odtwarzaj” zaczyna od początku, jak u upstreamu.
        currentTime = 0
        trackIndex = 0
        updateNowPlaying()
    }

    private func itemFailed(_ id: ObjectIdentifier, error message: String?) {
        guard let book, let index = itemTracks[id] else { return }
        let isCurrent = index == trackIndex
        forget(id)
        guard isCurrent else { return }
        if case .remote = book.tracks[index].source, !retriedRemote {
            retriedRemote = true
            onEvent?(.remoteFailed)
            return
        }
        player.pause()
        error = message ?? "Nie udało się odtworzyć pliku."
        syncPlayingState()
    }

    // MARK: - Zegar

    private func tick(_ time: CMTime) {
        guard let book, !isLoading, let item = player.currentItem,
              let index = itemTracks[ObjectIdentifier(item)], book.tracks.indices.contains(index)
        else { return }
        let track = book.tracks[index]
        trackIndex = index
        let local = time.seconds.isFinite ? max(0, time.seconds) : 0
        currentTime = min(track.startOffset + local, track.end)
        syncPlayingState()

        let now = Date.now
        if isPlaying {
            if let lastTick { listened += min(now.timeIntervalSince(lastTick), 2) }
            lastTick = now
            isDirty = true
            retriedRemote = false
        } else {
            lastTick = nil
            return
        }
        if let sleepDeadline, now >= sleepDeadline {
            sleepNow()
            return
        }
        if sleepTimer == .endOfChapter, let sleepChapter, currentTime >= sleepChapter.end - 0.25 {
            sleepNow()
        }
    }

    private func syncPlayingState() {
        let playing = player.timeControlStatus != .paused
        if playing != isPlaying {
            isPlaying = playing
            if !playing {
                lastTick = nil
                onEvent?(.paused)
            }
        }
        updateNowPlaying()
    }

    // MARK: - System

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let book else { return }
        let chapter = currentChapter
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapters.count > 1 ? (chapter?.title ?? book.title) : book.title,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPMediaItemPropertyMediaType: MPMediaType.audioBook.rawValue,
            MPMediaItemPropertyPlaybackDuration: book.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ]
        if let author = book.author { info[MPMediaItemPropertyArtist] = author }
        if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }
        if let chapter, let number = chapters.firstIndex(of: chapter), chapters.count > 1 {
            info[MPNowPlayingInfoPropertyChapterNumber] = number
            info[MPNowPlayingInfoPropertyChapterCount] = chapters.count
        }
        center.nowPlayingInfo = info
        // Na macOS klawisze multimedialne trafiają do aplikacji, która ma stan „odtwarza”.
        center.playbackState = isPlaying ? .playing : .paused
    }

    nonisolated private static func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        // Zbudowane poza aktorem głównym: system prosi o obraz na innej kolejce.
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    private func installRemoteCommands() {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        Self.on(center.playCommand) { [weak self] in self?.play() }
        Self.on(center.pauseCommand) { [weak self] in self?.pause() }
        Self.on(center.togglePlayPauseCommand) { [weak self] in self?.togglePlayPause() }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipForward)]
        Self.on(center.skipForwardCommand) { [weak self] in self?.skip(by: Self.skipForward) }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipBack)]
        Self.on(center.skipBackwardCommand) { [weak self] in self?.skip(by: -Self.skipBack) }
        Self.on(center.nextTrackCommand) { [weak self] in self?.nextChapter() }
        Self.on(center.previousTrackCommand) { [weak self] in self?.previousChapter() }
        Self.onPosition(center.changePlaybackPositionCommand) { [weak self] in self?.seek(to: $0) }
        center.changePlaybackRateCommand.supportedPlaybackRates = Self.rates.map { NSNumber(value: $0) }
        Self.onRate(center.changePlaybackRateCommand) { [weak self] in self?.rate = $0 }
    }

    // Obsługa poleceń jest budowana poza aktorem głównym i przeskakuje na niego: domknięcie
    // utworzone w metodzie aktora głównego wywołane przez system na innej kolejce kończy się pułapką.

    nonisolated private static func on(_ command: MPRemoteCommand, _ action: @escaping @Sendable @MainActor () -> Void) {
        command.addTarget { _ in
            Task { @MainActor in action() }
            return .success
        }
    }

    nonisolated private static func onPosition(
        _ command: MPChangePlaybackPositionCommand,
        _ action: @escaping @Sendable @MainActor (Double) -> Void
    ) {
        command.addTarget { event in
            guard let time = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in action(time) }
            return .success
        }
    }

    nonisolated private static func onRate(
        _ command: MPChangePlaybackRateCommand,
        _ action: @escaping @Sendable @MainActor (Float) -> Void
    ) {
        command.addTarget { event in
            guard let rate = (event as? MPChangePlaybackRateCommandEvent)?.playbackRate else { return .commandFailed }
            Task { @MainActor in action(rate) }
            return .success
        }
    }
}
