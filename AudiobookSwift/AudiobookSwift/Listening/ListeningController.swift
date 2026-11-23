import AppKit
import AudiobookshelfKit
import AudiobookshelfPlayback
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Listening")

/// Natywne słuchanie (etap 9a): listy z serwera, zdarzenia, zakładki, kolejka playlisty
/// i odtwarzanie przez wspólny `PlaybackCoordinator` z pakietu (etap 12 — ten sam co na iOS).
///
/// Żyje przez cały czas działania aplikacji (w `AppDelegate`), niezależnie od okna, więc
/// odtwarzanie trwa po jego zamknięciu i przy ⌘Q. Kończy się przy pełnym zakończeniu aplikacji
/// (`shutdown()`) i gdy serwer przestaje działać.
///
/// **Pozycja.** Źródłem prawdy jest serwer — ten sam postęp, który czyta telefon. Sesją odtwarzania,
/// synchronizacją co `PlaybackCoordinator.syncInterval`, przy pauzie, zmianie książki i wyjściu
/// zajmuje się koordynator. Niewysłana pozycja (serwer zatrzymany albo chwilowo nie odpowiada)
/// czeka w dzienniku postępu (`ProgressJournal`, plik w folderze danych serwera) i idzie na serwer,
/// gdy ten znów odpowie — tylko jeśli serwer nie ma nowszej pozycji (np. z telefonu).
/// Dźwięk idzie prosto z dysku (`localFile`), bo serwer działa na tym samym Macu.
@MainActor
@Observable
final class ListeningController {
    enum Availability: Equatable {
        /// Serwer nie działa albo nie ma jeszcze konta do słuchania.
        case unavailable
        case ready
    }

    /// Wspólne odtwarzanie z pakietu: sesja na serwerze, synchronizacja postępu, dziennik.
    let playback: PlaybackCoordinator
    var player: AudiobookPlayer { playback.player }
    private(set) var availability: Availability = .unavailable
    private(set) var libraries: [AudiobookshelfClient.Library] = []
    /// Postęp według `itemID` albo `itemID/episodeID`.
    private(set) var progress: [String: AudiobookshelfClient.MediaProgress] = [:] {
        didSet { updateShelfRevision() }
    }
    /// Rośnie, gdy zmieni się zbiór rozpoczętych i ukończonych pozycji (albo ich ukrycie
    /// w „Słuchaj dalej”) — półki strony startowej wczytują się wtedy od nowa. Samo przesunięcie
    /// miejsca w książce (synchronizacja co kilkanaście sekund) go nie zmienia.
    private(set) var shelfRevision = 0
    @ObservationIgnored private var shelfSignature = 0
    /// Zakładki według `itemID`, posortowane po czasie.
    private(set) var bookmarks: [String: [AudiobookshelfClient.Bookmark]] = [:]
    /// Rośnie, gdy serwer zgłosi zmianę pozycji w bibliotece (skan, nowa książka) — widoki
    /// okna przeładowują wtedy listy.
    private(set) var libraryRevision: [String: Int] = [:]
    /// Kolejka pobierania odcinków podcastów (zdarzenia serwera przy otwartym oknie).
    let episodeDownloads = EpisodeDownloads()
    /// Synchronizacja e-booka z nagraniem (etap 11a) — żyje tu, nie w oknie, żeby przetrwała ⌘Q.
    let textSync = TextSyncController()
    /// Tekst bieżącej książki w odtwarzaczu (etap 11b) — wspólny dla panelu i okna tekstu.
    let text = TextFollowModel()
    /// Rośnie po zmianie okładki pozycji — `AsyncCover` wczytuje ją wtedy od nowa.
    private(set) var coverRevision: [String: Int] = [:]
    /// Kolejka playlisty: po ukończeniu bieżącej pozycji gra następna.
    private(set) var queue: [QueueEntry] = []
    private(set) var isRefreshing = false
    /// Błąd do pokazania w oknie: własny (listy, zakładki) albo z odtwarzania.
    var loadError: String? {
        get { ownError ?? playback.loadError }
        set {
            ownError = newValue
            if newValue == nil { playback.loadError = nil }
        }
    }
    private var ownError: String?
    /// Pozycja, która właśnie się ładuje (wybrana z listy).
    var startingKey: String? { playback.startingKey }

    @ObservationIgnored private let supervisor: ServerSupervisor
    @ObservationIgnored private let account: ServerAccount
    @ObservationIgnored private var auth: ListeningAuth?
    /// Plik dziennika postępu bieżącego folderu danych.
    @ObservationIgnored private var journalURL: URL?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var permissionsWatcher: Task<Void, Never>?
    @ObservationIgnored let covers = CoverCache()
    @ObservationIgnored private var events: ListeningEvents?
    @ObservationIgnored private var playingFromQueue = false
    @ObservationIgnored private var changedLibraries: Set<String> = []
    @ObservationIgnored private var changedItems: Set<String> = []
    @ObservationIgnored private var revisionFlush: Task<Void, Never>?

    init(supervisor: ServerSupervisor, account: ServerAccount) {
        self.supervisor = supervisor
        self.account = account
        playback = PlaybackCoordinator(device: Self.deviceInfo()) { nil }
        playback.authProvider = { [weak self] in self?.auth }
        playback.isReachable = { [weak self] in self?.availability == .ready }
        playback.unreachableMessage = "Serwer audiobookshelf nie odpowiada."
        // Serwer działa na tym samym Macu: pliki czytelne z dysku grają prosto z niego.
        playback.localFile = { path in FileManager.default.isReadableFile(atPath: path) ? URL(filePath: path) : nil }
        playback.coverLoader = { [weak self] itemID, path in await self?.cover(for: itemID, path: path, size: 300) }
        playback.onProgressSaved = { [weak self] record in self?.updateLocalProgress(record) }
        playback.onFinished = { [weak self] book in await self?.bookFinished(book) }
    }

    /// Stały identyfikator tego Maca dla serwera (nowa sesja tego samego urządzenia zamyka poprzednią).
    private static func deviceInfo() -> AudiobookshelfClient.DeviceInfo {
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
        // Administrator zmienił uprawnienia konta (np. dostęp do bibliotek albo treści dla dorosłych).
        permissionsWatcher = Task { [weak self] in
            let changes = Observations { [weak self] in self?.account.listenerRevision }
            var last: Int?
            for await revision in changes {
                guard let self, let revision else { return }
                defer { last = revision }
                guard last != nil, availability == .ready else { continue }
                // Jak po ponownym połączeniu: siatki i strony też wczytują się od nowa.
                await refresh()
                for library in libraries { libraryRevision[library.id, default: 0] += 1 }
            }
        }
    }

    private func setAvailable(_ ready: Bool) async {
        if ready, availability != .ready {
            guard let environment = supervisor.environment else { return }
            openJournal(dataRoot: environment.dataRoot)
            auth = ListeningAuth(client: AudiobookshelfClient(baseURL: ServerEnvironment.baseURL)) { [account] in
                try await account.webSession(.listening)
            }
            availability = .ready
            await playback.uploadJournal()
            await refresh()
        } else if !ready, availability == .ready {
            availability = .unavailable
            serverStopped()
        }
    }

    /// Dziennik postępu w folderze danych serwera (obok `sharing.json`), więc testowa kopia
    /// z `-ABSDataRoot` ma własny. Niewysłane pozycje z bufora sprzed etapu 12
    /// (`listening-pending.json`) przechodzą do dziennika.
    private func openJournal(dataRoot: URL) {
        let url = dataRoot.appending(path: "listening-journal.json")
        guard journalURL != url else { return }
        journalURL = url
        playback.journal = ProgressJournal(fileURL: url)
        let legacy = dataRoot.appending(path: "listening-pending.json")
        guard let data = try? Data(contentsOf: legacy) else { return }
        struct Pending: Decodable {
            let itemID: String
            let episodeID: String?
            let currentTime: Double
            let duration: Double
            let savedAt: Date
        }
        if let entries = try? JSONDecoder().decode([String: Pending].self, from: data) {
            for entry in entries.values {
                if let known = playback.journal.position(itemID: entry.itemID, episodeID: entry.episodeID), known.updatedAt >= entry.savedAt { continue }
                playback.journal.recordLocal(itemID: entry.itemID, episodeID: entry.episodeID, currentTime: entry.currentTime, duration: entry.duration, at: entry.savedAt)
            }
            logger.notice("Przeniesiono \(entries.count) niewysłanych pozycji do dziennika postępu")
        }
        try? FileManager.default.removeItem(at: legacy)
    }

    /// Serwer przestał działać: odtwarzanie się kończy, a niewysłana pozycja czeka w dzienniku
    /// (koordynator nie łączy się już z serwerem — `isReachable` jest fałszywe).
    private func serverStopped() {
        if player.book != nil {
            Task { await playback.stop() }
        }
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
        permissionsWatcher?.cancel()
        await playback.stop()
    }

    /// Okno zamknięte — odtwarzanie trwa, ale pozycja idzie na serwer od razu.
    /// Zdarzenia serwera są potrzebne tylko oknu, więc połączenie się kończy.
    func windowClosed() {
        events?.stop()
        events = nil
        covers.purge()
        if player.isDirty { Task { await playback.sync() } }
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
        case .itemsChanged(let libraryIDs, let itemIDs):
            changedLibraries.formUnion(libraryIDs)
            changedItems.formUnion(itemIDs)
            // Skan dodaje pozycje seriami zdarzeń — listy przeładowują się raz na sekundę, nie przy każdym.
            if revisionFlush == nil {
                revisionFlush = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self else { return }
                    for id in changedLibraries { libraryRevision[id, default: 0] += 1 }
                    // Zdarzenie nie mówi, czy zmieniła się okładka — wczytanie z dysku jest tanie.
                    for id in changedItems { forgetCover(itemID: id) }
                    changedLibraries = []
                    changedItems = []
                    revisionFlush = nil
                }
            }
        case .reconnected:
            // Zdarzenia z przerwy przepadły: świeży postęp i przeładowanie list.
            for library in libraries { libraryRevision[library.id, default: 0] += 1 }
            Task { await refresh() }
        case .episodeDownload(let download, let phase):
            episodeDownloads.apply(download, phase)
        case .downloadQueueCleared(let itemID):
            episodeDownloads.clear(itemID: itemID)
        case .connected, .task, .taskProgress, .trackStarted:
            break
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

    /// Zdjęcie autora się zmieniło (etap 9i) — `AuthorPhoto` wczyta je od nowa.
    func authorImageChanged(id: String) {
        forgetCover(itemID: "author-" + id)
    }

    /// Okładka pozycji się zmieniła: widoki wczytują ją od nowa, odtwarzacz (dla bieżącej
    /// książki) odświeża obrazek w „Teraz odtwarzane”.
    func coverChanged(itemID: String, path: String?) {
        forgetCover(itemID: itemID)
        if player.book?.itemID == itemID {
            player.replaceCoverPath(path)
            Task {
                let image = await cover(for: itemID, path: path, size: 300)
                guard player.book?.itemID == itemID else { return }
                player.artwork = image
            }
        }
    }

    private func forgetCover(itemID: String) {
        covers.forget(itemID: itemID)
        coverRevision[itemID, default: 0] += 1
    }

    /// Rozdziały pozycji zmienione w edycji: odtwarzana książka dostaje nowe bez przerywania odtwarzania.
    func chaptersChanged(itemID: String, chapters: [PlaybackChapter]) {
        guard player.book?.itemID == itemID, player.book?.episodeID == nil else { return }
        player.replaceChapters(chapters)
    }

    /// Podpis zbioru pozycji z półek „Słuchaj dalej” i „Posłuchaj ponownie”: suma skrótów
    /// niezależna od kolejności, bez sortowania słownika.
    private func updateShelfRevision() {
        var signature = 0
        for (key, value) in progress where (value.currentTime ?? 0) > 0 || value.isFinished {
            var hasher = Hasher()
            hasher.combine(key)
            hasher.combine(value.isFinished)
            hasher.combine(value.hideFromContinueListening)
            signature &+= hasher.finalize()
        }
        guard signature != shelfSignature else { return }
        shelfSignature = signature
        shelfRevision += 1
    }

    static func key(_ itemID: String, _ episodeID: String?) -> String {
        PlaybackTimeline.key(itemID, episodeID)
    }

    // MARK: - Odtwarzanie

    /// Zaczyna słuchać pozycji (albo odcinka) od miejsca zapisanego na serwerze, a z `position`
    /// — od tego miejsca (zakładka, rozdział ze strony książki). Gdy to już bieżąca książka —
    /// tylko wznawia albo zatrzymuje.
    func play(itemID: String, episodeID: String? = nil, at position: Double? = nil) async {
        guard availability == .ready else { return }
        // Wybór innej pozycji z listy kończy kolejkę playlisty.
        if player.book?.key != Self.key(itemID, episodeID), startingKey == nil, !playingFromQueue { queue = [] }
        await playback.play(itemID: itemID, episodeID: episodeID, from: position)
    }

    /// Zatrzymuje odtwarzanie i zamyka książkę (pozycja zostaje na serwerze).
    func stopPlayback() async {
        await playback.stop()
    }

    /// Narzędzie pozycji za chwilę usunie albo przepisze pliki tej książki (etap 9e):
    /// zatrzymuje ją, jeśli gra, i zapisuje pozycję, zanim pliki znikną spod odtwarzacza.
    func release(itemID: String) async {
        guard player.book?.itemID == itemID else { return }
        await stopPlayback()
    }

    /// Coś w bibliotece zmieniło się bez zdarzenia o pozycjach (autor, kolekcja, tagi — etap 9i):
    /// listy wczytują się od nowa.
    func libraryChanged(_ libraryID: String) {
        libraryRevision[libraryID, default: 0] += 1
    }

    /// Pozycja usunięta z biblioteki: serwer skasował jej postęp, więc i lokalna kopia znika
    /// (inaczej „Słuchaj dalej” pokazywałoby martwą książkę do następnego odświeżenia).
    func itemDeleted(itemID: String, libraryID: String) {
        progress = progress.filter { $0.key != itemID && !$0.key.hasPrefix(itemID + "/") }
        bookmarks[itemID] = nil
        libraryRevision[libraryID, default: 0] += 1
    }

    /// Czy ta pozycja jest teraz wczytana w odtwarzaczu (gra albo pauza).
    func isLoaded(itemID: String) -> Bool { player.book?.itemID == itemID }

    /// Oznacza bieżącą książkę jako ukończoną (także przycisk w oknie).
    func markFinished() async {
        guard player.book != nil else { return }
        await playback.markFinished()
        await refresh()
    }

    /// Książka dobiegła końca (ukończenie już zapisane): świeże listy i następna pozycja z kolejki.
    private func bookFinished(_ book: PlaybackBook) async {
        await refresh()
        await playNextInQueue(after: book.key)
    }

    /// Serwer przyjął pozycję bieżącej książki — widoki okna widzą ją od razu, bez czekania na zdarzenie.
    private func updateLocalProgress(_ record: PositionRecord) {
        let old = progress[record.key]
        let now = record.updatedAt.timeIntervalSince1970 * 1000
        progress[record.key] = .init(
            id: old?.id, libraryItemId: record.itemID, episodeId: record.episodeID, duration: record.duration,
            progress: record.fraction, currentTime: record.currentTime, isFinished: record.isFinished,
            hideFromContinueListening: old?.hideFromContinueListening, lastUpdate: now,
            startedAt: old?.startedAt ?? now, finishedAt: record.isFinished ? now : nil,
            // Postęp czytania tej samej pozycji zostaje (słuchanie go nie zmienia).
            ebookLocation: old?.ebookLocation, ebookProgress: old?.ebookProgress
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
            if finished { playback.journal.discardUnsent(itemID: itemID, episodeID: episodeID) }
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
            await playback.discardCurrent()
        }
        playback.journal.removePosition(itemID: itemID, episodeID: episodeID)
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
        let title = player.currentChapter.map { "\($0.title) — \(PlaybackFormat.clock(time - $0.start))" } ?? PlaybackFormat.clock(time)
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
