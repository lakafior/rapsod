// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: odtwarzacz z projektu Dove tego samego autora
// (`Packages/DoveKit/Sources/DoveAppCore/AudiobookPlayer.swift`, MPL-2.0), w etapie 9a dostosowany
// w aplikacji na Maca (`Rapsod/Listening/AudiobookPlayer.swift`: jedna oś czasu książki
// z serwera, rozdziały z serwera, kolejka plików w `AVQueuePlayer`), a tu (etap 10c) przeniesiony
// do pakietu dla iOS: obliczenia osi czasu w `PlaybackTimeline`, okładka jako `PlatformImage`,
// pliki przez otwartą sesję zamiast z dysku. Sesja audio iOS (kategoria, przerwania, trasy)
// jest w aplikacji — tu tylko punkt zaczepienia `onWillPlay`.

import AVFoundation
import AudiobookshelfKit
import MediaPlayer
import Observation

/// Odtwarzacz audiobooka: jeden plik albo wiele po kolei jako jedna oś czasu, rozdziały,
/// prędkość, przewijanie o stały odstęp, wyłącznik czasowy, „Teraz odtwarzane” i polecenia
/// z ekranu blokady i słuchawek. Nie wie nic o serwerze: pliki dostaje przez `assetProvider`,
/// a o zmianach mówi przez `onEvent`.
@MainActor
@Observable
public final class AudiobookPlayer {
    public enum Event: Sendable {
        /// Odtwarzanie zatrzymane (pauza, wyłącznik czasowy, przerwanie, błąd).
        case paused
        /// Książka dobiegła końca.
        case finished
        /// Plik z serwera przestał działać (np. serwer zapomniał sesję) — trzeba go odbudować.
        case remoteFailed
    }

    public private(set) var book: PlaybackBook?
    /// Pozycja na osi czasu całej książki (sekundy). Zmienia się dwa razy na sekundę —
    /// czytają ją tylko małe widoki z czasem.
    public private(set) var currentTime: Double = 0 {
        didSet {
            let id = PlaybackTimeline.chapter(in: chapters, at: currentTime)?.id
            if id != currentChapterID { currentChapterID = id }
        }
    }
    /// Zmienia się tylko przy zmianie rozdziału — tę wartość czytają większe widoki.
    public private(set) var currentChapterID: Int?
    public private(set) var trackIndex = 0
    public private(set) var isPlaying = false
    /// Słuchacz chce, żeby grało: ustawiane przy „Odtwarzaj”, czyszczone tylko przez pauzę,
    /// zamknięcie i koniec książki — nie przez system (przerwanie, brak danych z sieci).
    public private(set) var wantsToPlay = false
    public private(set) var isLoading = false
    public var error: String?

    /// Od ostatniej udanej synchronizacji pozycja zmieniła się przez odtwarzanie albo przewinięcie.
    /// Pozycji, której odtwarzacz nie wytworzył, nie wolno wysyłać (nadpisałaby postęp z innego urządzenia).
    @ObservationIgnored public var isDirty = false
    /// Sekundy faktycznie przesłuchane (czas zegarowy) od ostatniego `takeListenedTime()`.
    @ObservationIgnored private var listened: Double = 0
    @ObservationIgnored private var lastTick: Date?

    public var rate: Float {
        didSet {
            UserDefaults.standard.set(rate, forKey: Self.rateKey)
            player.defaultRate = rate
            if player.rate != 0 { player.rate = rate }
            updateNowPlaying()
        }
    }

    public private(set) var sleepTimer: SleepTimer?
    public private(set) var sleepDeadline: Date?
    @ObservationIgnored private var sleepChapter: PlaybackChapter?

    /// Okładka do „Teraz odtwarzane”.
    public var artwork: PlatformImage? {
        didSet { nowPlayingArtwork = artwork.map(Self.makeArtwork); updateNowPlaying() }
    }

    /// Otwiera plik; `fresh` — poprzednia próba się nie udała (np. trzeba otworzyć nową sesję).
    @ObservationIgnored public var assetProvider: (@MainActor (PlaybackTrack, _ fresh: Bool) async throws -> AVURLAsset)?
    @ObservationIgnored public var onEvent: (@MainActor (Event) -> Void)?
    /// Strumień HLS: czeka, aż serwer przygotuje segment z czasem `local` (sekundy w strumieniu).
    @ObservationIgnored public var waitForStream: (@MainActor (_ local: Double) async -> Void)?
    /// Pozycja z serwera przed wznowieniem, jeśli zmieniła się gdzie indziej; `nil` = bez zmian.
    @ObservationIgnored public var resumeCheck: (@MainActor () async -> Double?)?
    /// Tuż przed rozpoczęciem odtwarzania (iOS: aktywacja sesji audio).
    @ObservationIgnored public var onWillPlay: (@MainActor () -> Void)?

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
    /// Ostatnie „Teraz odtwarzane”: zegar nie odświeża go co pół sekundy — system sam przesuwa
    /// czas z prędkości, więc wystarczy zmiana stanu, rozdziału albo co `nowPlayingInterval`.
    @ObservationIgnored private var nowPlayingUpdated: Date?
    @ObservationIgnored private var nowPlayingChapterID: Int?
    private static let nowPlayingInterval: TimeInterval = 10
    @ObservationIgnored private var retriedRemote = false

    // MARK: Segmenty sponsorowane (etap 13a)

    /// Segmenty bieżącego odcinka: znaczniki na pasku postępu i pomijanie. Ustawia je koordynator
    /// (plik znaczników, ustawienia podcastu, zgodność pliku); pusty dla książek.
    public private(set) var skipPlan: SkipPlan = .empty
    /// Ostatnie pominięcie — komunikat z „Cofnij” (znika po `skipUndoWindow`).
    public private(set) var lastSkip: SkipEvent?
    /// Jak długo „Cofnij” jest dostępne (dłużej przy VoiceOver — ustawia aplikacja).
    @ObservationIgnored public var skipUndoWindow: Duration = .seconds(10)
    /// Segmenty po „Cofnij” — grane do końca, dopóki pozycja z nich nie wyjdzie.
    @ObservationIgnored private var skipSuppressed: Set<String> = []
    /// Poprzednia pozycja do decyzji o pominięciu (po przewinięciu — cel przewinięcia).
    @ObservationIgnored private var skipPrevious: Double?
    /// Miejsce ostatniego przewinięcia albo startu.
    @ObservationIgnored private var skipAnchor: Double = 0
    @ObservationIgnored private var skipBoundary: Any?
    @ObservationIgnored private var lastSkipExpiry: Task<Void, Never>?
    /// Ostatnie przewinięcie w toku: zegar do jego końca podaje jeszcze starą pozycję (pominięcie albo
    /// „Cofnij” liczyłyby się od niej), więc wtedy go nie czytamy. Tylko ostatnie (wcześniejsze kończą
    /// się razem z nim), zerowane przy ładowaniu pliku i zamknięciu — zawieszone przewinięcie nie
    /// zatrzyma zegara na stałe.
    @ObservationIgnored private var pendingSeek: UUID?

    private static let rateKey = "listeningRate"
    public static let rates: [Float] = [0.8, 1, 1.1, 1.2, 1.3, 1.5, 1.75, 2, 2.5, 3]
    public static let skipBack: Double = 15
    public static let skipForward: Double = 30

    public init() {
        let stored = UserDefaults.standard.float(forKey: Self.rateKey)
        rate = stored > 0 ? stored : 1
        player.defaultRate = rate
        player.actionAtItemEnd = .advance
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
    }

    // MARK: - Stan

    public var chapters: [PlaybackChapter] { book?.chapters ?? [] }

    public var currentChapter: PlaybackChapter? {
        chapters.first { $0.id == currentChapterID }
    }

    public var duration: Double { book?.duration ?? 0 }

    /// Ma grać, ale czeka na dane (np. adres serwera przestał odpowiadać).
    public var isStalled: Bool {
        isLoading || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    /// Przesłuchane sekundy od poprzedniego wywołania (do `timeListened` w synchronizacji).
    public func takeListenedTime() -> Double {
        defer { listened = 0 }
        return listened
    }

    /// Oddaje nieudaną synchronizację — czas wróci przy następnej próbie.
    public func returnListenedTime(_ seconds: Double) {
        listened += seconds
    }

    // MARK: - Odtwarzanie

    /// Ładuje książkę i zaczyna od `position` (sekundy na osi całej książki).
    public func start(_ book: PlaybackBook, at position: Double, autoplay: Bool = true) {
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
    /// `resumeCheck`, czy pozycja nie przesunęła się gdzie indziej (np. na Macu).
    public func play() {
        guard book != nil, !isLoading else { return }
        wantsToPlay = true
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
        if player.currentItem == nil || error != nil {
            error = nil
            load(at: currentTime, autoplay: true, fresh: retriedRemote)
            return
        }
        onWillPlay?()
        player.playImmediately(atRate: rate)
        syncPlayingState()
    }

    public func pause() {
        wantsToPlay = false
        player.pause()
        syncPlayingState()
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Stan odtwarzania mógł się zmienić poza odtwarzaczem (przerwanie, zmiana trasy dźwięku).
    public func refreshPlayingState() {
        syncPlayingState()
    }

    /// Zamyka książkę.
    public func stop() {
        loadTask?.cancel()
        enqueueTask?.cancel()
        player.pause()
        clearQueue()
        book = nil
        isPlaying = false
        wantsToPlay = false
        isLoading = false
        currentTime = 0
        trackIndex = 0
        lastTick = nil
        artwork = nil
        error = nil
        cancelSleepTimer()
        resetSkips()
        pendingSeek = nil
        nowPlayingUpdated = nil
        nowPlayingChapterID = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    /// Nowe rozdziały bieżącej książki (np. po edycji rozdziałów); pliki i pozycja bez zmian.
    public func replaceChapters(_ chapters: [PlaybackChapter]) {
        guard book != nil else { return }
        book?.chapters = chapters
        let id = PlaybackTimeline.chapter(in: chapters, at: currentTime)?.id
        if id != currentChapterID { currentChapterID = id }
        updateNowPlaying()
    }

    /// Nowa okładka bieżącej książki (plik na serwerze), np. po jej zmianie.
    public func replaceCoverPath(_ path: String?) {
        guard book != nil, book?.coverPath != path else { return }
        book?.coverPath = path
    }

    /// Przewija do miejsca na osi czasu książki; między plikami ładuje właściwy plik.
    public func seek(to time: Double) {
        guard let book, !book.tracks.isEmpty else { return }
        let target = PlaybackTimeline.clamp(time, duration: book.duration)
        isDirty = true
        markSkipAnchor(target)
        let index = PlaybackTimeline.trackIndex(in: book.tracks, at: target)
        // Strumień HLS przewijamy, budując element od nowa: przewinięcie trwającego strumienia
        // potrafiło nigdy się nie zakończyć, a start od zadanej pozycji działa zawsze.
        let isStream = book.tracks[index].source == .sessionStream
        if !isStream, index == trackIndex, let item = player.currentItem, itemTracks[ObjectIdentifier(item)] == index, item.status == .readyToPlay {
            currentTime = target
            let local = PlaybackTimeline.localTime(target, in: book.tracks[index])
            let token = UUID()
            pendingSeek = token
            Task {
                await player.seek(to: CMTime(seconds: local, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                if pendingSeek == token { pendingSeek = nil }
                updateNowPlaying()
            }
        } else {
            load(at: target, autoplay: isPlaying)
        }
    }

    public func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    public func jump(to chapter: PlaybackChapter) {
        seek(to: chapter.start)
        if !isPlaying { play() }
    }

    public func nextChapter() {
        guard let next = PlaybackTimeline.nextChapter(in: chapters, at: currentTime) else { return }
        jump(to: next)
    }

    /// Początek bieżącego rozdziału albo poprzedni, gdy ten dopiero się zaczął.
    public func previousChapter() {
        guard let target = PlaybackTimeline.previousChapterTarget(in: chapters, at: currentTime) else { return }
        jump(to: target)
    }

    /// Odbudowuje bieżący plik w tym samym miejscu: `fresh` — po błędzie (nowa sesja na serwerze),
    /// bez niego — po zmianie adresu serwera (sieć lokalna ↔ tunel).
    public func reload(fresh: Bool) {
        guard book != nil else { return }
        load(at: currentTime, autoplay: isPlaying || isLoading, fresh: fresh)
    }

    // MARK: - Wyłącznik czasowy

    public func setSleepTimer(_ timer: SleepTimer?) {
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
        updateItemEndAction()
    }

    /// Wyłącznik „do końca rozdziału”, gdy rozdział kończy się razem z grającym plikiem: kolejka
    /// staje na końcu pliku zamiast przechodzić do następnego. Pauza wywołana dopiero w obsłudze
    /// końca pliku przychodziła za późno — `AVQueuePlayer` przechodził dalej i grał.
    private func updateItemEndAction() {
        var stopAtEnd = false
        if sleepTimer == .endOfChapter, let sleepChapter, let book, book.tracks.indices.contains(trackIndex) {
            let track = book.tracks[trackIndex]
            stopAtEnd = sleepChapter.end > track.startOffset && PlaybackTimeline.chapterEndsWithTrack(sleepChapter, track)
        }
        player.actionAtItemEnd = stopAtEnd ? .pause : .advance
    }

    private func cancelSleepTimer() {
        setSleepTimer(nil)
    }

    private func sleepNow() {
        cancelSleepTimer()
        pause()
    }

    // MARK: - Pliki

    /// Ładuje plik obejmujący `time` (i następny do kolejki) i przewija.
    private func load(at time: Double, autoplay: Bool, fresh: Bool = false) {
        guard let book, !book.tracks.isEmpty else { return }
        loadTask?.cancel()
        enqueueTask?.cancel()
        player.pause()
        clearQueue()
        let index = PlaybackTimeline.trackIndex(in: book.tracks, at: time)
        let track = book.tracks[index]
        let key = book.key
        trackIndex = index
        currentTime = time
        isLoading = true
        lastTick = nil
        pendingSeek = nil
        markSkipAnchor(time)
        updateItemEndAction()
        loadTask = Task {
            defer { if !Task.isCancelled { isLoading = false } }
            do {
                guard let assetProvider else { return }
                let asset = try await assetProvider(track, fresh)
                let local = PlaybackTimeline.localTime(time, in: track)
                if track.source == .sessionStream {
                    // AVPlayer nie ponawia segmentu, którego serwer jeszcze nie przetranskodował.
                    await waitForStream?(local)
                }
                guard !Task.isCancelled, self.book?.key == key else { return }
                let item = makeItem(asset, track: index)
                player.insert(item, after: nil)
                if local > 0 {
                    await player.seek(to: CMTime(seconds: local, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                guard !Task.isCancelled, self.book?.key == key else { return }
                if autoplay {
                    wantsToPlay = true
                    onWillPlay?()
                    player.playImmediately(atRate: rate)
                }
                syncPlayingState()
                enqueue(after: index)
                installSkipBoundaries()
                // Odcinek zaczyna się reklamą (np. pre-roll) — pomija od razu, bez pół sekundy reklamy.
                checkSkip(at: time)
            } catch {
                guard !Task.isCancelled else { return }
                // Pozycja zostaje: następne „Odtwarzaj” spróbuje od tego samego miejsca.
                self.error = error.localizedDescription
                retriedRemote = true
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
        let after = PlaybackTimeline.afterTrack(index, in: book.tracks)
        if sleepTimer == .endOfChapter, let sleepChapter, PlaybackTimeline.chapterEndsWithTrack(sleepChapter, book.tracks[index]) {
            // Rozdział kończy się razem z plikiem.
            if case .next(let next, let startsAt) = after {
                trackIndex = next
                currentTime = startsAt
                isDirty = true
                sleepNow()
                // Kolejka stoi na końcu skończonego pliku — przechodzimy do następnego bez grania.
                if let current = player.currentItem, itemTracks[ObjectIdentifier(current)] == nil {
                    player.advanceToNextItem()
                }
            } else {
                sleepNow()
                finish()
            }
            return
        }
        guard case .next(let next, let startsAt) = after else {
            finish()
            return
        }
        trackIndex = next
        currentTime = startsAt
        isDirty = true
        updateItemEndAction()
        installSkipBoundaries()
        if let current = player.currentItem, itemTracks[ObjectIdentifier(current)] == next {
            enqueue(after: next)
        } else {
            // Następny plik nie zdążył się załadować. Bez grania, gdy chwilę wcześniej zatrzymał
            // nas wyłącznik czasowy albo pauza (zegar potrafi dojść do końca pliku przed zdarzeniem
            // końca pliku i wtedy wyłącznik jest już wyłączony).
            load(at: currentTime, autoplay: wantsToPlay)
        }
    }

    private func finish() {
        wantsToPlay = false
        player.pause()
        clearQueue()
        currentTime = duration
        isDirty = false
        syncPlayingState()
        onEvent?(.finished)
        // Następne „Odtwarzaj” zaczyna od początku, jak w innych klientach audiobookshelf.
        currentTime = 0
        trackIndex = 0
        updateNowPlaying()
    }

    private func itemFailed(_ id: ObjectIdentifier, error message: String?) {
        guard book != nil, let index = itemTracks[id] else { return }
        let isCurrent = index == trackIndex
        forget(id)
        guard isCurrent else { return }
        if !retriedRemote {
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
        guard let book, !isLoading, pendingSeek == nil, let item = player.currentItem,
              let index = itemTracks[ObjectIdentifier(item)], book.tracks.indices.contains(index)
        else { return }
        trackIndex = index
        currentTime = PlaybackTimeline.bookTime(local: time.seconds, in: book.tracks[index])
        syncPlayingState(fromClock: true)

        let now = Date.now
        if isPlaying {
            if let lastTick { listened += min(now.timeIntervalSince(lastTick), 2) }
            lastTick = now
            isDirty = true
            retriedRemote = false
            checkSkip(at: currentTime)
        } else {
            lastTick = nil
            skipPrevious = currentTime
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

    /// `fromClock`: wywołanie z zegara (co pół sekundy) — „Teraz odtwarzane” tylko przy zmianie
    /// stanu albo rozdziału i co `nowPlayingInterval`; pozostałe wywołania odświeżają zawsze.
    private func syncPlayingState(fromClock: Bool = false) {
        let playing = player.timeControlStatus != .paused
        let changed = playing != isPlaying
        if changed {
            isPlaying = playing
            if !playing {
                lastTick = nil
                onEvent?(.paused)
            }
        }
        if fromClock, !changed, currentChapterID == nowPlayingChapterID,
           let nowPlayingUpdated, Date.now.timeIntervalSince(nowPlayingUpdated) < Self.nowPlayingInterval {
            return
        }
        updateNowPlaying()
    }

    // MARK: - Segmenty sponsorowane

    /// Nowy plan segmentów bieżącego odcinka (po wczytaniu znaczników, zmianie ustawień albo poprawce).
    public func setSkipPlan(_ plan: SkipPlan) {
        guard plan != skipPlan else { return }
        skipPlan = plan
        skipSuppressed = plan.stillSuppressed(skipSuppressed, at: currentTime)
        installSkipBoundaries()
        // Znaczniki przyszły chwilę po starcie: start sprzed segmentu (albo na jego początku)
        // liczy się jak przejście przez początek.
        if currentTime >= skipAnchor, currentTime - skipAnchor < 5 { skipPrevious = skipAnchor }
        checkSkip(at: currentTime)
    }

    /// Wraca na początek pominiętego fragmentu i gra go do końca.
    public func undoSkip() {
        guard let event = lastSkip, book != nil else { return }
        lastSkipExpiry?.cancel()
        lastSkip = nil
        skipSuppressed.formUnion(event.skippedIDs)
        seek(to: event.undoTime)
    }

    /// „Pomiń” — segment pod bieżącą pozycją (tylko znacznik albo po przewinięciu w jego środek).
    public func skipCurrentSegment() {
        guard book != nil, let entry = skipPlan.entry(at: currentTime) else { return }
        performSkip(entry: entry, undoTime: currentTime, to: entry.end, skippedIDs: [entry.id], automatic: false)
    }

    /// Chowa komunikat o pominięciu.
    public func dismissLastSkip() {
        lastSkipExpiry?.cancel()
        lastSkip = nil
    }

    private func resetSkips() {
        skipPlan = .empty
        lastSkipExpiry?.cancel()
        lastSkip = nil
        skipSuppressed = []
        skipPrevious = nil
        skipAnchor = 0
        removeSkipBoundaries()
    }

    private func markSkipAnchor(_ time: Double) {
        skipAnchor = time
        skipPrevious = time
    }

    /// Decyzja o pominięciu przy pozycji `current` (zegar, obserwator granic, koniec ładowania).
    private func checkSkip(at current: Double) {
        guard !skipPlan.isEmpty, book != nil, !isLoading, wantsToPlay else {
            skipPrevious = current
            return
        }
        skipSuppressed = skipPlan.stillSuppressed(skipSuppressed, at: current)
        let previous = skipPrevious ?? current
        skipPrevious = current
        guard let decision = skipPlan.decide(from: previous, to: current, suppressed: skipSuppressed) else { return }
        var target = decision.target
        // Wyłącznik „do końca rozdziału”: nie przeskakujemy za koniec rozdziału — tam zatrzyma zegar.
        if sleepTimer == .endOfChapter, let sleepChapter, sleepChapter.end > current, target > sleepChapter.end {
            target = sleepChapter.end
        }
        performSkip(entry: decision.entry, undoTime: decision.entry.start, to: target, skippedIDs: decision.skippedIDs, automatic: true)
    }

    private func performSkip(entry: SkipPlan.Entry, undoTime: Double, to target: Double, skippedIDs: [String], automatic: Bool) {
        lastSkipExpiry?.cancel()
        lastSkip = SkipEvent(entry: entry, undoTime: undoTime, target: target, skippedIDs: skippedIDs, automatic: automatic)
        // Koniec pliku: przewinięcie tuż przed koniec, dalej zwykłe zakończenie odcinka.
        seek(to: target)
        let window = skipUndoWindow
        let id = lastSkip?.id
        lastSkipExpiry = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled, let self, self.lastSkip?.id == id else { return }
            self.lastSkip = nil
        }
    }

    /// Obserwator granic na początkach segmentów bieżącego pliku: pominięcie bez czekania na zegar
    /// (co 0,5 s, czyli do 1,5 s reklamy przy 3×).
    private func installSkipBoundaries() {
        removeSkipBoundaries()
        guard let book, book.tracks.indices.contains(trackIndex) else { return }
        let track = book.tracks[trackIndex]
        let times: [NSValue] = skipPlan.entries.filter { $0.action == .skip }.compactMap { entry in
            let local = entry.start - track.startOffset
            guard local > 0.05, local < track.duration else { return nil }
            return NSValue(time: CMTime(seconds: local, preferredTimescale: 600))
        }
        guard !times.isEmpty else { return }
        skipBoundary = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.skipBoundaryReached() }
        }
    }

    private func removeSkipBoundaries() {
        if let skipBoundary { player.removeTimeObserver(skipBoundary) }
        skipBoundary = nil
    }

    private func skipBoundaryReached() {
        guard pendingSeek == nil, let book, let item = player.currentItem, let index = itemTracks[ObjectIdentifier(item)], book.tracks.indices.contains(index) else { return }
        checkSkip(at: PlaybackTimeline.bookTime(local: player.currentTime().seconds, in: book.tracks[index]))
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
        nowPlayingUpdated = .now
        nowPlayingChapterID = currentChapterID
        #if os(macOS)
        // Na macOS klawisze multimedialne trafiają do aplikacji, która ma stan „odtwarza”;
        // na iOS stan wynika z sesji audio.
        center.playbackState = isPlaying ? .playing : .paused
        #endif
    }

    nonisolated private static func makeArtwork(_ image: PlatformImage) -> MPMediaItemArtwork {
        // Zbudowane poza aktorem głównym: system prosi o obraz na innej kolejce.
        let box = UncheckedImage(image)
        return MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in box.image }
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

/// Obraz przekazywany systemowi na inną kolejkę; po utworzeniu nikt go nie zmienia.
private struct UncheckedImage: @unchecked Sendable {
    let image: PlatformImage
    init(_ image: PlatformImage) { self.image = image }
}
