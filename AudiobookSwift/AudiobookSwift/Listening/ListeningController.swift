import AppKit
import AVFoundation
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Listening")

/// Natywne słuchanie (etap 9a): listy z serwera, sesja odtwarzania i synchronizacja postępu.
///
/// Żyje przez cały czas działania aplikacji (w `AppDelegate`), niezależnie od okna, więc
/// odtwarzanie trwa po jego zamknięciu i przy ⌘Q. Kończy się przy pełnym zakończeniu aplikacji
/// (`shutdown()`) i gdy serwer przestaje działać.
///
/// **Pozycja.** Źródłem prawdy jest serwer — ten sam postęp, który czyta telefon. Książka zaczyna
/// od pozycji z serwera; podczas słuchania pozycja idzie na serwer co `syncInterval`, przy pauzie,
/// zmianie książki, zamknięciu okna i wyjściu. Wysyłana jest tylko pozycja, którą wytworzył ten
/// odtwarzacz (`AudiobookPlayer.isDirty`), żeby nie cofnąć postępu z telefonu. Nieudana wysyłka
/// trafia do `PendingPositions` i jest ponawiana; przed wznowieniem po pauzie odtwarzacz przejmuje
/// pozycję z serwera, jeśli ta zmieniła się gdzie indziej.
@MainActor
@Observable
final class ListeningController {
    enum Availability: Equatable {
        /// Serwer nie działa albo nie ma jeszcze konta do słuchania.
        case unavailable
        case ready
    }

    let player = AudiobookPlayer()
    private(set) var availability: Availability = .unavailable
    private(set) var libraries: [AudiobookshelfClient.Library] = []
    /// Postęp według `itemID` albo `itemID/episodeID`.
    private(set) var progress: [String: AudiobookshelfClient.MediaProgress] = [:]
    /// Zakładki według `itemID`, posortowane po czasie.
    private(set) var bookmarks: [String: [AudiobookshelfClient.Bookmark]] = [:]
    /// Rośnie, gdy serwer zgłosi zmianę pozycji w bibliotece (skan, nowa książka) — widoki
    /// okna przeładowują wtedy listy.
    private(set) var libraryRevision: [String: Int] = [:]
    /// Kolejka playlisty: po ukończeniu bieżącej pozycji gra następna.
    private(set) var queue: [QueueEntry] = []
    private(set) var isRefreshing = false
    var loadError: String?
    /// Pozycja, która właśnie się ładuje (wybrana z listy).
    private(set) var startingKey: String?

    static let syncInterval: Duration = .seconds(15)

    @ObservationIgnored private let supervisor: ServerSupervisor
    @ObservationIgnored private let account: ServerAccount
    @ObservationIgnored private var auth: ListeningAuth?
    @ObservationIgnored private var pending: PendingPositions?
    @ObservationIgnored private var session: (id: String, key: String)?
    @ObservationIgnored private var syncLoop: Task<Void, Never>?
    @ObservationIgnored private var syncInFlight: Task<Void, Never>?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    /// Ostatnia pozycja uzgodniona z serwerem (wysłana albo przejęta) dla bieżącej książki.
    @ObservationIgnored private var lastAgreed: Double?
    @ObservationIgnored let covers = CoverCache()
    @ObservationIgnored private var events: ListeningEvents?
    @ObservationIgnored private var playingFromQueue = false
    /// Plik okładki bieżącej książki (z sesji odtwarzania).
    @ObservationIgnored private(set) var nowPlayingCoverPath: String?

    init(supervisor: ServerSupervisor, account: ServerAccount) {
        self.supervisor = supervisor
        self.account = account
        player.assetProvider = { [weak self] track, fresh in
            guard let self else { throw CancellationError() }
            return try await asset(for: track, fresh: fresh)
        }
        player.onEvent = { [weak self] event in self?.handle(event) }
        player.resumeCheck = { [weak self] in await self?.serverPositionIfChanged() }
        player.waitForStream = { [weak self] path, local in await self?.waitForSegment(playlist: path, at: local) }
    }

    private var deviceInfo: AudiobookshelfClient.DeviceInfo {
        let key = "listeningDeviceID"
        let id = UserDefaults.standard.string(forKey: key) ?? {
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: key)
            return id
        }()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return AudiobookshelfClient.DeviceInfo(deviceId: id, clientVersion: version)
    }

    // MARK: - Cykl życia

    /// Śledzi stan serwera i konta do słuchania.
    func activate() {
        watcher = Task { [weak self] in
            let changes = Observations { [weak self] in
                self.map { ($0.supervisor.state, $0.account.state, $0.account.userState) }
            }
            for await change in changes {
                guard let self, let (server, accountState, user) = change else { return }
                let ready = server == .running && accountState == .ready && { if case .ready = user { true } else { false } }()
                await setAvailable(ready)
            }
        }
    }

    private func setAvailable(_ ready: Bool) async {
        if ready, availability != .ready {
            guard let environment = supervisor.environment else { return }
            pending = PendingPositions(dataRoot: environment.dataRoot)
            auth = ListeningAuth(client: AudiobookshelfClient(baseURL: ServerEnvironment.baseURL)) { [account] in
                try await account.webSession(.listening)
            }
            availability = .ready
            await flushPending()
            await refresh()
        } else if !ready, availability == .ready {
            availability = .unavailable
            serverStopped()
        }
    }

    /// Serwer przestał działać: odtwarzanie się kończy, a niewysłana pozycja czeka w buforze.
    private func serverStopped() {
        if player.book != nil {
            player.pause()
            rememberUnsent()
            player.stop()
        }
        endSyncLoop()
        session = nil
        lastAgreed = nil
        auth?.reset()
        auth = nil
        events?.stop()
        events = nil
        libraries = []
        progress = [:]
        bookmarks = [:]
        queue = []
    }

    /// Pełne zakończenie aplikacji: pozycja trafia na serwer, zanim ten zostanie zatrzymany.
    func shutdown() async {
        watcher?.cancel()
        guard player.book != nil else { return }
        player.pause()
        await closeSession()
        player.stop()
    }

    /// Okno zamknięte — odtwarzanie trwa, ale pozycja idzie na serwer od razu.
    /// Zdarzenia serwera są potrzebne tylko oknu, więc połączenie się kończy.
    func windowClosed() {
        events?.stop()
        events = nil
        covers.purge()
        if player.isDirty { Task { await sync() } }
        // Okno z siatką okładek zostawia po sobie pofragmentowaną stertę: zwolnione bloki trzymają
        // strony „brudne” do czasu presji pamięci. Po rozebraniu widoków oddajemy je systemowi od razu.
        Task {
            try? await Task.sleep(for: .seconds(3))
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    /// Okno otwarte albo znów aktywne: świeże dane i zdarzenia serwera na żywo
    /// (postęp z telefonu, nowe pozycje po skanie).
    func windowActivated() async {
        guard let auth else { return }
        if events == nil {
            let events = ListeningEvents(baseURL: auth.baseURL, token: { [weak self] expired in
                guard let auth = self?.auth else { throw AudiobookshelfClient.APIError.unauthorized }
                if let expired { return try await auth.renew(expired: expired) }
                return try await auth.token()
            }, handler: { [weak self] event in self?.handle(event) })
            self.events = events
            events.start()
        }
        await refresh()
    }

    private func handle(_ event: ListeningEvents.Event) {
        switch event {
        case .progress(let value):
            guard let itemID = value.libraryItemId else { return }
            let key = Self.key(itemID, value.episodeId)
            // Nie nadpisujemy pozycji, którą właśnie wytwarza ten odtwarzacz (zdarzenie bywa spóźnione).
            if player.book?.key == key, player.isDirty { return }
            progress[key] = value
        case .user(let me):
            apply(me)
        case .itemsChanged(let libraryIDs):
            for id in libraryIDs { libraryRevision[id, default: 0] += 1 }
        case .reconnected:
            Task { await refresh() }
        }
    }

    private func apply(_ me: AudiobookshelfClient.MeState) {
        var all = Dictionary(me.mediaProgress.elements.compactMap { p in p.libraryItemId.map { (Self.key($0, p.episodeId), p) } }, uniquingKeysWith: { $1 })
        if let book = player.book, player.isDirty, let local = progress[book.key] { all[book.key] = local }
        progress = all
        bookmarks = Dictionary(grouping: me.bookmarks?.elements ?? [], by: \.libraryItemId).mapValues { $0.sorted { $0.time < $1.time } }
    }

    /// Wywołanie API tokenem konta do słuchania (dla widoków okna).
    func api<T: Sendable>(_ operation: (AudiobookshelfClient, String) async throws -> T) async throws -> T {
        guard let auth else { throw AudiobookshelfClient.APIError.unauthorized }
        return try await auth.perform(operation)
    }

    // MARK: - Listy

    func refresh() async {
        guard let auth else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            libraries = try await auth.perform { try await $0.userLibraries(token: $1) }
            apply(try await auth.perform { try await $0.me(token: $1) })
            loadError = nil
        } catch {
            logger.error("Odświeżanie list: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
    }

    func cover(for itemID: String, path: String?, size: CGFloat) async -> NSImage? {
        await covers.image(itemID: itemID, path: path, pixels: Int(size * 2)) { [weak self] width in
            guard let auth = self?.auth else { return nil }
            return try? await auth.perform { try await $0.cover(itemID: itemID, width: width, token: $1) }
        }
    }

    /// Zdjęcie autora (pliki autorów leżą w folderze metadanych serwera, więc przez HTTP).
    func authorImage(id: String, path: String?, size: CGFloat) async -> NSImage? {
        guard path != nil else { return nil }
        return await covers.image(itemID: "author-" + id, path: nil, pixels: Int(size * 2)) { [weak self] width in
            guard let auth = self?.auth else { return nil }
            return try? await auth.perform { try await $0.authorImage(id: id, width: width, token: $1) }
        }
    }

    static func key(_ itemID: String, _ episodeID: String?) -> String {
        episodeID.map { "\(itemID)/\($0)" } ?? itemID
    }

    // MARK: - Odtwarzanie

    /// Zaczyna słuchać pozycji (albo odcinka) od miejsca zapisanego na serwerze.
    /// Gdy to już bieżąca książka — tylko wznawia albo zatrzymuje.
    func play(itemID: String, episodeID: String? = nil, at position: Double? = nil) async {
        let key = Self.key(itemID, episodeID)
        if player.book?.key == key {
            if let position {
                player.seek(to: position)
                if !player.isPlaying { player.togglePlayPause() }
            } else {
                player.togglePlayPause()
            }
            return
        }
        guard let auth, startingKey == nil else { return }
        // Wybór innej pozycji z listy kończy kolejkę playlisty.
        if !playingFromQueue { queue = [] }
        startingKey = key
        defer { startingKey = nil }
        loadError = nil

        // Poprzednia książka: pozycja na serwer, sesja zamknięta.
        if player.book != nil {
            player.pause()
            await closeSession()
            player.stop()
        }

        do {
            var playback = try await auth.perform {
                try await $0.startPlayback(itemID: itemID, episodeID: episodeID, device: deviceInfo, transcode: false, token: $1)
            }
            var tracks = playback.audioTracks.map(Self.track)
            if await !Self.allPlayable(playback.audioTracks, tracks) {
                // Formaty spoza AVFoundation (np. WMA): serwer transkoduje do HLS. Nowa sesja tego
                // samego urządzenia zamyka poprzednią.
                logger.notice("Książka w formacie spoza AVFoundation — odtwarzanie przez transkodowanie")
                playback = try await auth.perform {
                    try await $0.startPlayback(itemID: itemID, episodeID: episodeID, device: deviceInfo, transcode: true, token: $1)
                }
                tracks = playback.audioTracks.map(Self.track)
            }
            guard !tracks.isEmpty else { throw PlaybackError.noAudio }

            var start = playback.currentTime
            var adoptedLocal = false
            if let unsent = pending?[key] {
                let server = try? await auth.perform { try await $0.progress(itemID: itemID, episodeID: episodeID, token: $1) }
                if let server, server.lastUpdate / 1000 > unsent.savedAt.timeIntervalSince1970 {
                    pending?.set(nil, for: key)
                } else {
                    start = unsent.currentTime
                    adoptedLocal = true
                }
            }

            let book = AudiobookPlayer.Book(
                itemID: itemID,
                episodeID: episodeID,
                title: playback.displayTitle ?? "Bez tytułu",
                author: playback.displayAuthor,
                duration: playback.duration,
                tracks: tracks,
                chapters: Self.chapters(playback, tracks: tracks)
            )
            session = (playback.id, key)
            lastAgreed = adoptedLocal || position != nil ? nil : start
            if let position {
                // Wybrane miejsce (zakładka, rozdział ze strony książki).
                player.start(book, at: position)
                player.isDirty = true
            } else {
                // Kilka sekund wstecz: wejście w połowie zdania trudno śledzić.
                player.start(book, at: adoptedLocal ? start : max(0, start - (start > 10 ? 3 : 0)))
                if adoptedLocal { player.isDirty = true }
            }
            startSyncLoop()
            nowPlayingCoverPath = playback.coverPath
            loadArtwork(itemID: itemID, path: playback.coverPath)
        } catch {
            logger.error("Start odtwarzania: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
    }

    /// Zatrzymuje odtwarzanie i zamyka książkę (pozycja zostaje na serwerze).
    func stopPlayback() async {
        guard player.book != nil else { return }
        player.pause()
        await closeSession()
        player.stop()
        nowPlayingCoverPath = nil
    }

    /// Oznacza bieżącą książkę jako ukończoną (także przycisk w oknie).
    func markFinished() async {
        guard let book = player.book else { return }
        player.pause()
        player.isDirty = false
        await finish(book)
        player.stop()
        endSyncLoop()
        nowPlayingCoverPath = nil
    }

    private enum PlaybackError: LocalizedError {
        case noAudio
        var errorDescription: String? { "Ta pozycja nie ma plików audio." }
    }

    private static func track(_ track: AudiobookshelfClient.PlaybackSession.Track) -> AudiobookPlayer.Track {
        let source: AudiobookPlayer.Track.Source
        if let path = track.metadata?.path, FileManager.default.isReadableFile(atPath: path) {
            source = .file(URL(filePath: path))
        } else {
            source = .remote(track.contentUrl)
        }
        let title = track.title ?? track.metadata?.path.map { ($0 as NSString).lastPathComponent } ?? "Plik \(track.index)"
        return AudiobookPlayer.Track(startOffset: track.startOffset, duration: track.duration, title: title, source: source)
    }

    /// Kontenery, których AVFoundation nie otwiera (sprawdzone na macOS 27: WMA, Matroska, WebM).
    private static let unplayableExtensions: Set<String> = ["wma", "mka", "webm", "webma"]

    private static func allPlayable(_ raw: [AudiobookshelfClient.PlaybackSession.Track], _ tracks: [AudiobookPlayer.Track]) async -> Bool {
        for (info, track) in zip(raw, tracks) {
            let ext = ((info.metadata?.path ?? info.contentUrl) as NSString).pathExtension.lowercased()
            if unplayableExtensions.contains(ext) { return false }
            if case .file(let url) = track.source, await (try? AVURLAsset(url: url).load(.isPlayable)) != true { return false }
        }
        return true
    }

    /// Rozdziały z serwera; bez nich — po jednym na plik.
    private static func chapters(_ playback: AudiobookshelfClient.PlaybackSession, tracks: [AudiobookPlayer.Track]) -> [AudiobookPlayer.Chapter] {
        if !playback.chapters.isEmpty {
            return playback.chapters.enumerated().map { .init(id: $0.offset, start: $0.element.start, end: $0.element.end, title: $0.element.title) }
        }
        return tracks.enumerated().map {
            .init(id: $0.offset, start: $0.element.startOffset, end: $0.element.end, title: tracks.count == 1 ? (playback.displayTitle ?? $0.element.title) : $0.element.title)
        }
    }

    private func asset(for track: AudiobookPlayer.Track, fresh: Bool) async throws -> AVURLAsset {
        switch track.source {
        case .file(let url):
            return AVURLAsset(url: url)
        case .remote(let path):
            guard let auth else { throw AudiobookshelfClient.APIError.unauthorized }
            let token = fresh ? try await auth.renew(expired: try await auth.token()) : try await auth.token()
            let url = URL(string: auth.baseURL.absoluteString + path)!
            // Nagłówek obejmuje też segmenty strumienia HLS (token w adresie by ich nie objął).
            return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]])
        }
    }

    private func loadArtwork(itemID: String, path: String?) {
        Task {
            let image = await cover(for: itemID, path: path, size: 300)
            guard player.book?.itemID == itemID else { return }
            player.artwork = image
        }
    }

    private func handle(_ event: AudiobookPlayer.Event) {
        switch event {
        case .paused:
            if player.isDirty { Task { await sync() } }
        case .finished:
            guard let book = player.book else { return }
            Task {
                await finish(book)
                await playNextInQueue(after: book.key)
            }
        case .remoteFailed:
            player.reloadRemote()
        }
    }

    /// Czeka (do ok. 20 s), aż serwer przygotuje segment HLS z danym czasem. Upstream tnie strumień
    /// na segmenty po 6 s (`hls_time 6`, `output-<n>.ts`); brakujący segment każe mu przetranskodować
    /// od tego miejsca.
    private func waitForSegment(playlist: String, at local: Double) async {
        guard let auth else { return }
        let segment = (playlist as NSString).deletingLastPathComponent + "/output-\(Int(local / 6)).ts"
        for _ in 0..<40 {
            if (try? await auth.perform({ try await $0.streamFileExists(path: segment, token: $1) })) == true { return }
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
        }
        logger.error("Segment strumienia nie pojawił się na czas")
    }

    /// Przed wznowieniem: pozycja z serwera, jeśli ktoś (telefon) zmienił ją od naszej ostatniej.
    private func serverPositionIfChanged() async -> Double? {
        guard let book = player.book, let auth else { return nil }
        guard let server = try? await auth.perform({ try await $0.progress(itemID: book.itemID, episodeID: book.episodeID, token: $1) }),
              !server.isFinished
        else { return nil }
        let serverTime = server.currentTime ?? 0
        if let lastAgreed, abs(serverTime - lastAgreed) < 1 { return nil }
        logger.notice("Pozycja zmieniła się na serwerze — przejmuję ją przed wznowieniem")
        lastAgreed = serverTime
        progress[book.key] = server
        return serverTime
    }

    // MARK: - Synchronizacja

    private func startSyncLoop() {
        endSyncLoop()
        syncLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.syncInterval)
                guard let self, !Task.isCancelled else { return }
                if player.isDirty { await sync() }
            }
        }
    }

    private func endSyncLoop() {
        syncLoop?.cancel()
        syncLoop = nil
    }

    /// Wysyła bieżącą pozycję, jeśli ją wytworzył ten odtwarzacz. Jedna wysyłka naraz.
    func sync() async {
        if let syncInFlight { await syncInFlight.value }
        guard player.isDirty, let book = player.book, let auth else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            let data = AudiobookshelfClient.SyncData(currentTime: player.currentTime, timeListened: player.takeListenedTime(), duration: book.duration)
            player.isDirty = false
            do {
                if let session, session.key == book.key {
                    do {
                        try await auth.perform { try await $0.syncSession(id: session.id, data, token: $1) }
                    } catch AudiobookshelfClient.APIError.http(status: 404, _) {
                        // Serwer nie zna już sesji (uruchomiony ponownie) — sam postęp.
                        self.session = nil
                        try await saveProgress(book, time: data.currentTime)
                    }
                } else {
                    try await saveProgress(book, time: data.currentTime)
                }
                lastAgreed = data.currentTime
                pending?.set(nil, for: book.key)
                updateLocalProgress(book, time: data.currentTime)
            } catch {
                logger.error("Synchronizacja postępu: \(error.localizedDescription, privacy: .public)")
                if player.book?.key == book.key { player.isDirty = true }
                player.returnListenedTime(data.timeListened)
                pending?.set(.init(itemID: book.itemID, episodeID: book.episodeID, currentTime: data.currentTime, duration: book.duration, savedAt: .now), for: book.key)
            }
        }
        syncInFlight = task
        await task.value
        syncInFlight = nil
    }

    private func saveProgress(_ book: AudiobookPlayer.Book, time: Double) async throws {
        guard let auth else { throw AudiobookshelfClient.APIError.unauthorized }
        try await auth.perform {
            try await $0.updateProgress(itemID: book.itemID, episodeID: book.episodeID, currentTime: time, duration: book.duration, token: $1)
        }
    }

    /// Zamyka sesję; pozycję dosyła tylko wtedy, gdy zmieniła się tutaj.
    private func closeSession() async {
        if let syncInFlight { await syncInFlight.value }
        endSyncLoop()
        guard let book = player.book else { return }
        let dirty = player.isDirty
        let data = AudiobookshelfClient.SyncData(currentTime: player.currentTime, timeListened: player.takeListenedTime(), duration: book.duration)
        player.isDirty = false
        defer { session = nil; lastAgreed = nil }
        do {
            if let session, session.key == book.key, let auth {
                try await auth.perform { try await $0.closeSession(id: session.id, dirty ? data : nil, token: $1) }
            } else if dirty {
                try await saveProgress(book, time: data.currentTime)
            }
            if dirty {
                pending?.set(nil, for: book.key)
                updateLocalProgress(book, time: data.currentTime)
            }
        } catch {
            logger.error("Zamknięcie sesji: \(error.localizedDescription, privacy: .public)")
            if dirty {
                pending?.set(.init(itemID: book.itemID, episodeID: book.episodeID, currentTime: data.currentTime, duration: book.duration, savedAt: .now), for: book.key)
            }
        }
    }

    /// Książka dobiegła końca: ukończona na serwerze, sesja zamknięta bez pozycji
    /// (późniejsza synchronizacja z wcześniejszą pozycją cofnęłaby „ukończone”).
    private func finish(_ book: AudiobookPlayer.Book) async {
        if let syncInFlight { await syncInFlight.value }
        endSyncLoop()
        player.isDirty = false
        _ = player.takeListenedTime()
        guard let auth else { return }
        do {
            try await auth.perform {
                try await $0.updateProgress(itemID: book.itemID, episodeID: book.episodeID, currentTime: book.duration, duration: book.duration, isFinished: true, token: $1)
            }
            if let session, session.key == book.key {
                try? await auth.perform { try await $0.closeSession(id: session.id, nil, token: $1) }
            }
            pending?.set(nil, for: book.key)
        } catch {
            logger.error("Oznaczenie jako ukończone: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
        session = nil
        lastAgreed = nil
        // Książka zostaje załadowana od początku: ponowne „Odtwarzaj” słucha jej od nowa,
        // a postęp idzie na serwer bez sesji (`saveProgress`).
        if player.book?.key == book.key { startSyncLoop() }
        await refresh()
    }

    /// Pozycja niewysłana przy zatrzymaniu serwera — do bufora.
    private func rememberUnsent() {
        guard player.isDirty, let book = player.book else { return }
        player.isDirty = false
        pending?.set(.init(itemID: book.itemID, episodeID: book.episodeID, currentTime: player.currentTime, duration: book.duration, savedAt: .now), for: book.key)
    }

    /// Po połączeniu: niewysłane pozycje trafiają na serwer, o ile są nowsze niż jego postęp.
    private func flushPending() async {
        guard let auth, let entries = pending?.entries, !entries.isEmpty else { return }
        for (key, entry) in entries {
            do {
                let server = try await auth.perform { try await $0.progress(itemID: entry.itemID, episodeID: entry.episodeID, token: $1) }
                if server.map({ $0.lastUpdate / 1000 < entry.savedAt.timeIntervalSince1970 }) ?? true {
                    try await auth.perform {
                        try await $0.updateProgress(itemID: entry.itemID, episodeID: entry.episodeID, currentTime: entry.currentTime, duration: entry.duration, token: $1)
                    }
                    logger.notice("Wysłano zaległą pozycję słuchania")
                }
                pending?.set(nil, for: key)
            } catch AudiobookshelfClient.APIError.http(status: 404, _) {
                pending?.set(nil, for: key)
            } catch {
                logger.error("Zaległa pozycja: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func updateLocalProgress(_ book: AudiobookPlayer.Book, time: Double) {
        let old = progress[book.key]
        progress[book.key] = .init(
            id: old?.id, libraryItemId: book.itemID, episodeId: book.episodeID, duration: book.duration,
            progress: book.duration > 0 ? time / book.duration : 0, currentTime: time, isFinished: false,
            hideFromContinueListening: old?.hideFromContinueListening, lastUpdate: Date.now.timeIntervalSince1970 * 1000,
            startedAt: old?.startedAt ?? Date.now.timeIntervalSince1970 * 1000, finishedAt: nil
        )
    }
    // MARK: - Postęp, zakładki i kolejka (strony okna „Biblioteka”, etap 9b)

    struct QueueEntry: Hashable, Sendable {
        let itemID: String
        let episodeID: String?
        let title: String
    }

    /// Świeży postęp i zakładki (po akcjach okna; zdarzenia serwera też je przynoszą).
    func refreshMe() async {
        do {
            apply(try await api { try await $0.me(token: $1) })
        } catch {
            logger.error("Odświeżenie postępu: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Oznacza pozycję (albo odcinek) jako ukończoną lub nieukończoną.
    func setFinished(itemID: String, episodeID: String? = nil, _ finished: Bool) async {
        let key = Self.key(itemID, episodeID)
        if finished, player.book?.key == key {
            // Bieżąca książka: sesja zamykana bez pozycji, inaczej synchronizacja cofnęłaby „ukończone”.
            await markFinished()
            return
        }
        do {
            try await api { try await $0.setFinished(itemID: itemID, episodeID: episodeID, finished: finished, token: $1) }
            if finished { pending?.set(nil, for: key) }
        } catch {
            loadError = error.localizedDescription
        }
        await refreshMe()
    }

    /// Ukończone/nieukończone dla wielu pozycji (seria, wszystkie odcinki podcastu).
    func setFinished(_ entries: [AudiobookshelfClient.BatchProgress]) async {
        guard !entries.isEmpty else { return }
        if let book = player.book, entries.contains(where: { $0.isFinished && Self.key($0.libraryItemId, $0.episodeId) == book.key }) {
            await markFinished()
        }
        do {
            try await api { try await $0.setFinished(entries, token: $1) }
        } catch {
            loadError = error.localizedDescription
        }
        await refreshMe()
    }

    /// Usuwa postęp pozycji (web UI: „Wyzeruj postęp”). Gdy właśnie gra — odtwarzanie kończy się
    /// bez zapisu pozycji, bo następna synchronizacja założyłaby postęp od nowa.
    func resetProgress(itemID: String, episodeID: String? = nil) async {
        let key = Self.key(itemID, episodeID)
        if player.book?.key == key {
            player.pause()
            if let syncInFlight { await syncInFlight.value }
            endSyncLoop()
            player.isDirty = false
            _ = player.takeListenedTime()
            if let session, session.key == key {
                try? await api { try await $0.closeSession(id: session.id, nil, token: $1) }
            }
            session = nil
            lastAgreed = nil
            player.stop()
            nowPlayingCoverPath = nil
        }
        pending?.set(nil, for: key)
        do {
            var id = progress[key]?.id
            if id == nil {
                id = try await api { try await $0.progress(itemID: itemID, episodeID: episodeID, token: $1) }?.id
            }
            if let id {
                try await api { try await $0.deleteProgress(id: id, token: $1) }
            }
            progress[key] = nil
        } catch {
            loadError = error.localizedDescription
        }
        await refreshMe()
    }

    /// Chowa pozycję z „Słuchaj dalej” bez zmiany postępu.
    func removeFromContinueListening(itemID: String, episodeID: String? = nil) async {
        guard let id = progress[Self.key(itemID, episodeID)]?.id else { return }
        do {
            try await api { try await $0.removeFromContinueListening(progressID: id, token: $1) }
        } catch {
            loadError = error.localizedDescription
        }
        await refreshMe()
    }

    /// Zakładka w bieżącym miejscu odtwarzanej książki.
    func addBookmarkAtCurrentPosition() async {
        guard let book = player.book, book.episodeID == nil else { return }
        let time = (player.currentTime * 10).rounded() / 10
        let title = player.currentChapter.map { "\($0.title) — \(ChapterScrubber.time(time - $0.start))" } ?? ChapterScrubber.time(time)
        do {
            try await api { try await $0.createBookmark(itemID: book.itemID, time: time, title: title, token: $1) }
        } catch {
            loadError = error.localizedDescription
        }
        await refreshMe()
    }

    func renameBookmark(_ bookmark: AudiobookshelfClient.Bookmark, to title: String) async {
        do {
            try await api { try await $0.updateBookmark(itemID: bookmark.libraryItemId, time: bookmark.time, title: title, token: $1) }
        } catch {
            loadError = error.localizedDescription
        }
        await refreshMe()
    }

    func deleteBookmark(_ bookmark: AudiobookshelfClient.Bookmark) async {
        do {
            try await api { try await $0.deleteBookmark(itemID: bookmark.libraryItemId, time: bookmark.time, token: $1) }
        } catch {
            loadError = error.localizedDescription
        }
        await refreshMe()
    }

    /// Gra pozycje po kolei (playlista): pierwsza od razu, kolejne po ukończeniu poprzedniej.
    func playQueue(_ entries: [QueueEntry]) async {
        guard let first = entries.first else { return }
        playingFromQueue = true
        defer { playingFromQueue = false }
        queue = Array(entries.dropFirst())
        await play(itemID: first.itemID, episodeID: first.episodeID)
    }

    func clearQueue() {
        queue = []
    }

    private func playNextInQueue(after key: String) async {
        guard player.book?.key == key, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        playingFromQueue = true
        defer { playingFromQueue = false }
        await play(itemID: next.itemID, episodeID: next.episodeID)
    }
}
