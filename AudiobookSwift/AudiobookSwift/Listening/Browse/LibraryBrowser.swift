import Foundation
import Observation

/// Stan przeglądania w oknie „Biblioteka”: wybrana biblioteka, sekcja, ścieżka nawigacji,
/// sortowanie i filtr. Żyje tylko razem z oknem (`@State` w `LibraryWindow`), więc po
/// zamknięciu okna listy i strony znikają z pamięci; trwałe dane słuchania są w `ListeningController`.
@MainActor
@Observable
final class LibraryBrowser {
    enum Section: Hashable {
        case home, items, series, authors, narrators, collections, playlists, latestEpisodes, downloads, stats
    }

    enum Route: Hashable {
        case item(String)
        case series(id: String, name: String)
        case author(id: String, name: String)
        case filtered(ItemFilter)
        case collection(String)
        case playlist(String)
    }

    /// Filtr listy pozycji (`grupa` jak w web UI, wartość jawna).
    struct ItemFilter: Hashable {
        let group: String
        let value: String
        let title: String

        /// Wartość dla parametru `filter`.
        var query: String { value.isEmpty ? group : AudiobookshelfClient.filter(group, value) }

        static func narrator(_ name: String) -> Self { .init(group: "narrators", value: name, title: "Lektor: \(name)") }
        static func genre(_ name: String) -> Self { .init(group: "genres", value: name, title: "Gatunek: \(name)") }
        static func tag(_ name: String) -> Self { .init(group: "tags", value: name, title: "Tag: \(name)") }
        static func publisher(_ name: String) -> Self { .init(group: "publishers", value: name, title: "Wydawca: \(name)") }
        static func language(_ name: String) -> Self { .init(group: "languages", value: name, title: "Język: \(name)") }
    }

    struct Sort: Hashable {
        var key: String
        var descending: Bool
    }

    let listening: ListeningController
    /// Zarządzanie pozycją (konto root) — osobno od słuchania.
    let manager: ItemManager
    var libraryID: String? {
        didSet {
            guard libraryID != oldValue else { return }
            UserDefaults.standard.set(libraryID, forKey: "libraryWindow.library")
            path = []
            filter = nil
            filterData = nil
            playlists = nil
            searchText = ""
            if let library, library.mediaType != "podcast", section == .downloads {
                section = .items
            } else if let library, library.mediaType == "podcast", ![.home, .items, .latestEpisodes, .downloads, .playlists, .stats].contains(section) {
                section = .items
            }
        }
    }
    var section: Section = .home {
        didSet { if section != oldValue { path = [] } }
    }
    var path: [Route] = []
    /// Wyniki wyszukiwania pokazuje korzeń okna, więc zapytanie wpisane na otwartej stronie wraca do niego.
    var searchText = "" {
        didSet { if !searchText.isEmpty, oldValue.isEmpty, !path.isEmpty { path = [] } }
    }
    /// Filtr siatki „Książki” (nie dotyczy stron serii, autora i list z filtrem w ścieżce).
    var filter: ItemFilter?
    var itemSort = Sort(key: "media.metadata.title", descending: false) {
        didSet { save(itemSort, "items") }
    }
    var podcastSort = Sort(key: "media.metadata.title", descending: false) {
        didSet { save(podcastSort, "podcasts") }
    }
    var seriesSort = Sort(key: "name", descending: false) {
        didSet { save(seriesSort, "series") }
    }
    var authorSort = Sort(key: "name", descending: false) {
        didSet { save(authorSort, "authors") }
    }
    private(set) var filterData: AudiobookshelfClient.FilterData?
    /// Własne playlisty użytkownika w bieżącej bibliotece (menu „Dodaj do playlisty”, sekcja „Playlisty”).
    private(set) var playlists: [AudiobookshelfClient.Playlist]?
    /// Pozycja, dla której okno pyta o nazwę nowej playlisty.
    var newPlaylistEntry: AudiobookshelfClient.PlaylistEntry?
    /// Wgrywanie (etap 9e). Model żyje z oknem, nie z arkuszem: arkusz można schować w trakcie
    /// wysyłania, a postęp zostaje w pasku narzędzi okna.
    private(set) var upload: UploadModel?
    var showsUpload = false

    /// Pliki upuszczone na okno albo wybrane przyciskiem → arkusz wgrywania (konto root).
    /// W trakcie wysyłania dokłada je do bieżącej listy.
    func upload(_ urls: [URL]) {
        guard manager.isAvailable else { return }
        if let upload, upload.isRunning {
            upload.add(urls)
        } else {
            upload = UploadModel(browser: self, urls: urls)
        }
        showsUpload = true
    }

    init(listening: ListeningController, account: ServerAccount) {
        self.listening = listening
        manager = ItemManager(account: account)
        libraryID = UserDefaults.standard.string(forKey: "libraryWindow.library")
        itemSort = Self.load("items") ?? itemSort
        podcastSort = Self.load("podcasts") ?? podcastSort
        seriesSort = Self.load("series") ?? seriesSort
        authorSort = Self.load("authors") ?? authorSort
    }

    var library: AudiobookshelfClient.Library? {
        listening.libraries.first { $0.id == libraryID }
    }

    var isPodcastLibrary: Bool { library?.mediaType == "podcast" }

    /// Po wczytaniu list bibliotek: zapamiętana albo pierwsza.
    func ensureLibrary() {
        if library == nil { libraryID = listening.libraries.first?.id }
    }

    func open(_ route: Route) {
        searchText = ""
        path.append(route)
    }

    func loadFilterData() async {
        guard filterData == nil, let libraryID else { return }
        filterData = try? await listening.api { try await $0.filterData(libraryID: libraryID, token: $1) }
    }

    /// Po edycji pozycji mogły dojść nowe wartości (autor, seria, gatunek, tag).
    func invalidateFilterData() {
        filterData = nil
    }

    func loadPlaylists() async {
        guard let libraryID else { return }
        do {
            playlists = try await listening.api { try await $0.playlists(libraryID: libraryID, token: $1) }
        } catch {
            listening.loadError = error.localizedDescription
        }
    }

    func createPlaylist(name: String, with entry: AudiobookshelfClient.PlaylistEntry) async {
        guard let libraryID, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        await playlistChange { _ = try await $0.createPlaylist(libraryID: libraryID, name: name, items: [entry], token: $1) }
    }

    func addToPlaylist(_ id: String, _ entry: AudiobookshelfClient.PlaylistEntry) async {
        await playlistChange { try await $0.addToPlaylist(id: id, entry, token: $1) }
    }

    func removeFromPlaylist(_ id: String, _ entry: AudiobookshelfClient.PlaylistEntry) async {
        await playlistChange { try await $0.removeFromPlaylist(id: id, entry, token: $1) }
    }

    func renamePlaylist(_ id: String, to name: String) async {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        await playlistChange { try await $0.renamePlaylist(id: id, name: name, token: $1) }
    }

    func deletePlaylist(_ id: String) async {
        await playlistChange { try await $0.deletePlaylist(id: id, token: $1) }
    }

    private func playlistChange(_ operation: (AudiobookshelfClient, String) async throws -> Void) async {
        do {
            try await listening.api(operation)
        } catch {
            listening.loadError = error.localizedDescription
        }
        await loadPlaylists()
    }

    /// Licznik zmian pozycji bieżącej biblioteki (zdarzenia serwera) — listy przeładowują się po nim.
    var revision: Int { libraryID.flatMap { listening.libraryRevision[$0] } ?? 0 }

    private func save(_ sort: Sort, _ name: String) {
        UserDefaults.standard.set([sort.key, sort.descending ? "1" : "0"], forKey: "libraryWindow.sort.\(name)")
    }

    private static func load(_ name: String) -> Sort? {
        guard let value = UserDefaults.standard.stringArray(forKey: "libraryWindow.sort.\(name)"), value.count == 2 else { return nil }
        return Sort(key: value[0], descending: value[1] == "1")
    }
}

/// Lista wczytywana stronami: rozmiar znany po pierwszej stronie, kolejne strony na żądanie
/// widocznych komórek. Siatka z kilkoma tysiącami pozycji pobiera i trzyma tylko oglądane strony.
@MainActor
@Observable
final class PagedList<Element: Sendable> {
    private(set) var total: Int?
    private(set) var error: String?
    private var pages: [Int: [Element]] = [:]
    @ObservationIgnored private var loading: Set<Int> = []
    @ObservationIgnored let pageSize: Int
    @ObservationIgnored private let fetch: (_ page: Int, _ limit: Int) async throws -> (items: [Element], total: Int?)

    init(pageSize: Int = 60, fetch: @escaping (_ page: Int, _ limit: Int) async throws -> (items: [Element], total: Int?)) {
        self.pageSize = pageSize
        self.fetch = fetch
    }

    func element(at index: Int) -> Element? {
        let page = pages[index / pageSize]
        let offset = index % pageSize
        return page.flatMap { offset < $0.count ? $0[offset] : nil }
    }

    /// Wczytuje stronę z daną pozycją (wołane, gdy komórka pojawia się na ekranie). Sąsiednią
    /// stronę też, żeby przy przewijaniu nie było widać pustych kart.
    func ensureLoaded(_ index: Int) {
        let page = index / pageSize
        load(page)
        if index % pageSize > pageSize * 2 / 3, let total, (page + 1) * pageSize < total { load(page + 1) }
    }

    func loadFirst() async {
        if total == nil { await loadPage(0) }
    }

    /// Ponownie pobiera wczytane strony (zmiana na serwerze); stare dane widać do czasu odpowiedzi.
    func refresh() async {
        let loaded = pages.keys.sorted()
        for page in loaded.isEmpty ? [0] : loaded { await loadPage(page) }
    }

    private func load(_ page: Int) {
        guard pages[page] == nil, !loading.contains(page) else { return }
        Task { await loadPage(page) }
    }

    private func loadPage(_ page: Int) async {
        guard !loading.contains(page) else { return }
        loading.insert(page)
        defer { loading.remove(page) }
        do {
            let result = try await fetch(page, pageSize)
            pages[page] = result.items
            total = result.total ?? max(total ?? 0, page * pageSize + result.items.count)
            error = nil
        } catch is CancellationError {
        } catch {
            if total == nil { self.error = error.localizedDescription }
        }
    }
}
