import AudiobookshelfKit
import Foundation
import Observation

/// Stan przeglądania w oknie „Biblioteka”: wybrana biblioteka, sekcja, ścieżka nawigacji,
/// sortowanie i filtr. Żyje tylko razem z oknem (`@State` w `LibraryWindow`), więc po
/// zamknięciu okna listy i strony znikają z pamięci; trwałe dane słuchania są w `ListeningController`.
@MainActor
@Observable
final class LibraryBrowser {
    enum Section: String, Hashable, CaseIterable {
        case home, items, series, authors, narrators, collections, playlists, latestEpisodes, downloads, stats
        /// Etap 9i: statystyki biblioteki i tagi/gatunki całego serwera.
        case libraryStats, metadata
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

    /// Siatka okładek albo lista jak w Finderze (etap 14c).
    enum ViewMode: String {
        case grid, list
    }

    /// Widoki z przełącznikiem siatka/lista; każdy pamięta swój tryb.
    enum ViewContext: String, CaseIterable {
        case books, podcasts, filtered, series, search, seriesPage, authorPage, collectionPage
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
            isSelecting = false
            if let library, library.mediaType != "podcast", section == .downloads {
                section = .items
            } else if let library, library.mediaType == "podcast", ![.home, .items, .latestEpisodes, .downloads, .playlists, .stats, .libraryStats, .metadata].contains(section) {
                section = .items
            }
        }
    }
    /// Sekcja paska bocznego; zapamiętana jak biblioteka (etap 14f, HIG: przywracanie stanu okna).
    var section: Section = LibraryBrowser.storedSection() {
        didSet {
            if section != oldValue {
                path = []
                isSelecting = false
                UserDefaults.standard.set(section.rawValue, forKey: Self.sectionKey)
            }
        }
    }
    /// Panel odtwarzacza po prawej (inspektor); zapamiętany, przełączany też z menu Widok (⌥⌘I).
    var showsPlayer = UserDefaults.standard.object(forKey: LibraryBrowser.showsPlayerKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsPlayer, forKey: Self.showsPlayerKey) }
    }
    static let sectionKey = "libraryWindow.section"
    static let showsPlayerKey = "libraryWindow.showsPlayer"

    private static func storedSection() -> Section {
        let stored = UserDefaults.standard.string(forKey: sectionKey)
        return stored.flatMap(Section.init(rawValue:)) ?? .home
    }

    // MARK: Zaznaczanie wielu pozycji (etap 9h)

    /// Tryb zaznaczania w siatce: kliknięcie karty zaznacza zamiast otwierać.
    var isSelecting = false {
        didSet { if !isSelecting { selection = [] } }
    }
    /// Zaznaczone pozycje w kolejności zaznaczania (kolejka odtwarzania idzie w tej kolejności).
    private(set) var selection: [AudiobookshelfClient.LibraryItem] = []

    func isSelected(_ id: String) -> Bool { selection.contains { $0.id == id } }

    func toggleSelection(_ item: AudiobookshelfClient.LibraryItem) {
        if let index = selection.firstIndex(where: { $0.id == item.id }) {
            selection.remove(at: index)
        } else {
            selection.append(item)
        }
    }

    func selectAll(_ items: [AudiobookshelfClient.LibraryItem]) {
        for item in items where !isSelected(item.id) { selection.append(item) }
    }

    func clearSelection() { selection = [] }

    /// Zmiana zaznaczenia z listy (etap 14c): zdejmuje i dokłada pozycje, nie ruszając
    /// pozostałych — także tych spoza wczytanych stron, których lista nie widzi.
    func changeSelection(removing removed: Set<String>, adding added: [AudiobookshelfClient.LibraryItem]) {
        selection.removeAll { removed.contains($0.id) }
        for item in added where !isSelected(item.id) { selection.append(item) }
    }

    /// „Zaznacz wczytane” dla jednej siatki (`scope`: sekcja pozycji albo strona serii) — siatka
    /// pod spodem stosu nawigacji nie może dołożyć swoich kart.
    struct SelectAllRequest: Equatable {
        let scope: String
        let serial: Int
    }
    var selectAllRequest: SelectAllRequest?

    func requestSelectAll(scope: String) {
        selectAllRequest = .init(scope: scope, serial: (selectAllRequest?.serial ?? 0) + 1)
    }

    /// Po usunięciu zaznaczone pozycje znikają z zaznaczenia.
    func deselect(_ ids: Set<String>) { selection.removeAll { ids.contains($0.id) } }
    /// Każda zmiana strony albo filtra kończy zaznaczanie — inaczej działanie (np. „Usuń…”)
    /// dotyczyłoby pozycji z poprzedniej, niewidocznej już listy.
    var path: [Route] = [] {
        didSet {
            guard path != oldValue else { return }
            isSelecting = false
            // Wstecz/Dalej jak w Finderze: krok wstecz odkłada stronę do historii „Dalej”,
            // każde inne przejście ją czyści.
            if !navigatingHistory {
                if path.count < oldValue.count, Array(oldValue.prefix(path.count)) == path {
                    forwardStack = Array(oldValue.suffix(from: path.count)) + forwardStack
                } else {
                    forwardStack = []
                }
            }
        }
    }
    /// Strony do ponownego otwarcia przez „Dalej” (⌘]); najbliższa pierwsza.
    private(set) var forwardStack: [Route] = []
    @ObservationIgnored private var navigatingHistory = false

    var canGoBack: Bool { !path.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Wstecz (⌘[): zdejmuje ostatnią stronę ze ścieżki.
    func goBack() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    /// Dalej (⌘]): wraca na stronę zdjętą przez „Wstecz”.
    func goForward() {
        guard let next = forwardStack.first else { return }
        navigatingHistory = true
        forwardStack.removeFirst()
        path.append(next)
        navigatingHistory = false
    }
    /// Wyniki wyszukiwania pokazuje korzeń okna, więc zapytanie wpisane na otwartej stronie wraca do niego.
    var searchText = "" {
        didSet { if !searchText.isEmpty, oldValue.isEmpty, !path.isEmpty { path = [] } }
    }
    /// Pola tekstowe okna, które mają teraz fokus (wyszukiwanie, filtr odcinków, filtr tagów).
    /// Póki jakieś ma, spacja pisze spację zamiast przełączać odtwarzanie (skrót bez modyfikatora).
    private(set) var focusedTextFields: Set<String> = []

    func textField(_ id: String, focused: Bool) {
        guard focusedTextFields.contains(id) != focused else { return }
        if focused { focusedTextFields.insert(id) } else { focusedTextFields.remove(id) }
    }

    /// Filtr siatki „Książki” (nie dotyczy stron serii, autora i list z filtrem w ścieżce).
    var filter: ItemFilter? {
        didSet { if filter != oldValue { isSelecting = false } }
    }
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
    /// Siatka albo lista, osobno dla każdego widoku (etap 14c).
    private(set) var viewModes: [ViewContext: ViewMode] = [:]

    func viewMode(_ context: ViewContext) -> ViewMode { viewModes[context] ?? .grid }

    func setViewMode(_ mode: ViewMode, for context: ViewContext) {
        viewModes[context] = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "libraryWindow.viewMode.\(context.rawValue)")
    }

    /// Widok na wierzchu okna, jeśli ma przełącznik siatka/lista (menu Widok, ⌘1/⌘2).
    var currentViewContext: ViewContext? {
        if let last = path.last {
            switch last {
            case .series: return .seriesPage
            case .author: return .authorPage
            case .filtered: return .filtered
            case .collection: return .collectionPage
            case .item, .playlist: return nil
            }
        }
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty { return .search }
        switch section {
        case .items: return isPodcastLibrary ? .podcasts : .books
        case .series: return .series
        default: return nil
        }
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
    /// „Dodaj podcast…” z menu na pasku menu — sekcja „Podcasty” otwiera wtedy swój arkusz.
    var addPodcastRequested = false

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
        for context in ViewContext.allCases {
            if let mode = UserDefaults.standard.string(forKey: "libraryWindow.viewMode.\(context.rawValue)").flatMap(ViewMode.init) {
                viewModes[context] = mode
            }
        }
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
    /// Ostatnio oglądane strony (najnowsza na końcu) — tylko one są odświeżane po zmianie na serwerze.
    @ObservationIgnored private var recent: [Int] = []
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored let pageSize: Int
    @ObservationIgnored private let fetch: (_ page: Int, _ limit: Int) async throws -> (items: [Element], total: Int?)

    init(pageSize: Int = 60, fetch: @escaping (_ page: Int, _ limit: Int) async throws -> (items: [Element], total: Int?)) {
        self.pageSize = pageSize
        self.fetch = fetch
    }

    /// Wczytane dotąd elementy (dla „Zaznacz wczytane”).
    var loadedElements: [Element] { pages.keys.sorted().flatMap { pages[$0] ?? [] } }

    /// Miejsca wczytanych elementów spełniających warunek (zaznaczenie w liście, etap 14c).
    func indices(where matches: (Element) -> Bool) -> Set<Int> {
        var result = Set<Int>()
        for (page, elements) in pages {
            for (offset, element) in elements.enumerated() where matches(element) { result.insert(page * pageSize + offset) }
        }
        return result
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
        if recent.last != page {
            recent.removeAll { $0 == page }
            recent.append(page)
            if recent.count > 3 { recent.removeFirst() }
        }
        load(page)
        if index % pageSize > pageSize * 2 / 3, let total, (page + 1) * pageSize < total { load(page + 1) }
    }

    func loadFirst() async {
        if total == nil { await loadPage(0) }
    }

    /// Zmiana na serwerze: ponownie pobiera ostatnio oglądane strony (równolegle; stare dane widać
    /// do czasu odpowiedzi), a pozostałe zwalnia — wczytają się od nowa, gdy wrócą na ekran.
    /// Wołania w trakcie odświeżania (skan zgłasza zmiany co sekundę) łączą się w jedno następne.
    func refresh() async {
        guard !isRefreshing else {
            refreshAgain = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshAgain = false
            let keep = Set(recent.isEmpty ? [0] : recent)
            for page in pages.keys where !keep.contains(page) { pages[page] = nil }
            await withTaskGroup(of: Void.self) { group in
                for page in keep { group.addTask { await self.loadPage(page) } }
            }
        } while refreshAgain && !Task.isCancelled
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
