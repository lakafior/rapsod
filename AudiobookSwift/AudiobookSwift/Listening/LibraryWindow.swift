import SwiftUI

/// Natywne okno „Biblioteka” — widok słuchacza zamiast web UI: pasek boczny z biblioteką
/// i sekcjami, w środku siatki okładek i strony (książka, seria, autor, podcast) z nawigacją
/// wstecz, na dole pasek odtwarzania, po prawej panel odtwarzacza.
///
/// Treść istnieje tylko przy otwartym oknie (`ReleasedWhenClosed`), a stan przeglądania
/// (`LibraryBrowser`) razem z nią; odtwarzacz żyje w `ListeningController`, więc słuchanie
/// trwa po zamknięciu okna.
struct LibraryWindow: View {
    static let windowID = "library"
    static let title = "Biblioteka"

    let listening: ListeningController
    let supervisor: ServerSupervisor
    let account: ServerAccount
    let settings: SettingsNavigation

    @State private var browser: LibraryBrowser
    @State private var showsPlayer = true
    @State private var newPlaylistName = ""
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var activeState

    init(listening: ListeningController, supervisor: ServerSupervisor, account: ServerAccount, settings: SettingsNavigation) {
        self.listening = listening
        self.supervisor = supervisor
        self.account = account
        self.settings = settings
        _browser = State(initialValue: LibraryBrowser(listening: listening))
    }

    private var needsUser: Bool {
        guard supervisor.state == .running, account.state == .ready else { return false }
        switch account.userState {
        case .missing, .invalid: return true
        case .unknown, .ready: return false
        }
    }

    var body: some View {
        Group {
            if needsUser {
                UserAccountSetup(account: account)
            } else if listening.availability == .ready {
                content
            } else {
                unavailable
            }
        }
        .frame(minWidth: 980, minHeight: 560)
        .navigationTitle(Self.title)
        .onDisappear { listening.windowClosed() }
    }

    private var content: some View {
        NavigationSplitView {
            LibrarySidebar(browser: browser)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            // Strony otwierane z list zastępują całą kolumnę szczegółów, więc pasek odtwarzania
            // dostaje i korzeń, i każda strona (na samym stosie znikał po przejściu dalej).
            NavigationStack(path: $browser.path) {
                withPlayerBar(root)
                    .navigationDestination(for: LibraryBrowser.Route.self) { route in
                        withPlayerBar(destination(route))
                    }
            }
        }
        .searchable(text: $browser.searchText, placement: .toolbar, prompt: browser.isPodcastLibrary ? "Szukaj podcastów i odcinków" : "Szukaj książek, autorów, serii")
        .inspector(isPresented: $showsPlayer) {
            PlayerPanel(listening: listening)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(showsPlayer ? "Schowaj odtwarzacz" : "Pokaż odtwarzacz", systemImage: "sidebar.trailing") { showsPlayer.toggle() }
            }
        }
        .task {
            await listening.windowActivated()
            browser.ensureLibrary()
        }
        .onChange(of: activeState) {
            // Powrót do okna: świeży postęp, nawet gdyby zdarzenia serwera coś zgubiły.
            if activeState == .key { Task { await listening.refreshMe() } }
        }
        .onChange(of: listening.libraries) { browser.ensureLibrary() }
        .task(id: browser.libraryID) { await browser.loadPlaylists() }
        // `presenting:` przekazuje pozycję do akcji — zamknięcie alertu zeruje `newPlaylistEntry` wcześniej.
        .alert("Nowa playlista", isPresented: Binding(get: { browser.newPlaylistEntry != nil }, set: { if !$0 { browser.newPlaylistEntry = nil } }),
               presenting: browser.newPlaylistEntry) { entry in
            TextField("Nazwa", text: $newPlaylistName)
            Button("Utwórz") {
                let name = newPlaylistName
                Task { await browser.createPlaylist(name: name, with: entry) }
                newPlaylistName = ""
            }
            Button("Anuluj", role: .cancel) { newPlaylistName = "" }
        }
        .alert("Nie udało się", isPresented: Binding(get: { listening.loadError != nil }, set: { if !$0 { listening.loadError = nil } })) {
            Button("OK") { listening.loadError = nil }
        } message: {
            Text(listening.loadError ?? "")
        }
    }

    @ViewBuilder private var root: some View {
        if let libraryID = browser.libraryID, browser.library != nil {
            if !browser.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                SearchView(browser: browser, libraryID: libraryID, text: browser.searchText)
            } else {
                switch browser.section {
                case .home: HomeView(browser: browser, libraryID: libraryID)
                case .items: ItemsSection(browser: browser, libraryID: libraryID)
                case .series: SeriesSection(browser: browser, libraryID: libraryID)
                case .authors: AuthorsSection(browser: browser, libraryID: libraryID)
                case .narrators: NarratorsSection(browser: browser, libraryID: libraryID)
                case .collections: CollectionsSection(browser: browser, libraryID: libraryID)
                case .playlists: PlaylistsSection(browser: browser, libraryID: libraryID)
                case .latestEpisodes: LatestEpisodesView(browser: browser, libraryID: libraryID)
                case .stats: StatsView(listening: listening)
                }
            }
        } else if listening.libraries.isEmpty, !listening.isRefreshing {
            ContentUnavailableView("Brak bibliotek", systemImage: "books.vertical", description: Text("Dodaj folder z audiobookami w ustawieniach aplikacji."))
        } else {
            ProgressView()
        }
    }

    private func withPlayerBar(_ content: some View) -> some View {
        // Panel odtwarzacza pokazuje to samo, więc pasek jest tylko wtedy, gdy panel jest schowany.
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if !showsPlayer {
                MiniPlayerBar(listening: listening, showsPlayer: $showsPlayer)
            }
        }
    }

    @ViewBuilder private func destination(_ route: LibraryBrowser.Route) -> some View {
        switch route {
        case .item(let id): ItemPage(browser: browser, itemID: id)
        case .series(let id, let name): SeriesPage(browser: browser, seriesID: id, name: name)
        case .author(let id, let name): AuthorPage(browser: browser, authorID: id, name: name)
        case .filtered(let filter): FilteredItems(browser: browser, filter: filter)
        case .collection(let id): CollectionPage(browser: browser, collectionID: id)
        case .playlist(let id): PlaylistPage(browser: browser, playlistID: id)
        }
    }

    @ViewBuilder private var unavailable: some View {
        switch supervisor.state {
        case .running:
            ProgressView("Łączenie…")
        case .starting:
            ProgressView("Uruchamianie serwera…")
        case .stopping:
            ProgressView("Zatrzymywanie serwera…")
        case .stopped:
            ContentUnavailableView {
                Label("Serwer zatrzymany", systemImage: "books.vertical")
            } actions: {
                Button("Uruchom serwer") { supervisor.start() }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Serwer nie działa", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Uruchom ponownie") { supervisor.start() }
                Button("Ustawienia i log…") { openWindow.openSettings(.general, navigation: settings) }
            }
        }
    }
}

/// Pasek boczny: wybór biblioteki i sekcje (inne dla książek i podcastów).
private struct LibrarySidebar: View {
    @Bindable var browser: LibraryBrowser

    var body: some View {
        let podcast = browser.isPodcastLibrary
        List(selection: Binding(get: { browser.section }, set: { if let section = $0 { browser.section = section } })) {
            Section(browser.library?.name ?? "Biblioteka") {
                row("Start", "house", .home)
                if podcast {
                    row("Podcasty", "mic", .items)
                    row("Najnowsze odcinki", "clock", .latestEpisodes)
                } else {
                    row("Książki", "books.vertical", .items)
                    row("Serie", "square.stack", .series)
                    row("Autorzy", "person.2", .authors)
                    row("Lektorzy", "waveform", .narrators)
                    row("Kolekcje", "rectangle.stack", .collections)
                }
                row("Playlisty", "music.note.list", .playlists)
            }
            Section("Twoje słuchanie") {
                row("Statystyki", "chart.bar", .stats)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if browser.listening.libraries.count > 1 {
                Picker("Biblioteka", selection: $browser.libraryID) {
                    ForEach(browser.listening.libraries) { library in
                        Label(library.name, systemImage: library.mediaType == "podcast" ? "mic" : "books.vertical")
                            .tag(Optional(library.id))
                    }
                }
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .accessibilityIdentifier("libraryPicker")
            }
        }
    }
}

extension LibrarySidebar {
    /// Wiersz sekcji; kliknięcie już wybranej sekcji wraca do jej korzenia (jak w Muzyce i Finderze) —
    /// zaznaczenie się wtedy nie zmienia, więc robi to gest, nie `selection`.
    func row(_ title: String, _ symbol: String, _ section: LibraryBrowser.Section) -> some View {
        Label(title, systemImage: symbol)
            .tag(section)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                if browser.section == section { browser.path = [] }
            })
    }
}

/// Lista pozycji z filtrem z innej strony (lektor, gatunek, tag, wydawca…).
struct FilteredItems: View {
    @Bindable var browser: LibraryBrowser
    let filter: LibraryBrowser.ItemFilter

    var body: some View {
        if let libraryID = browser.libraryID {
            ItemGrid(browser: browser, libraryID: libraryID, filter: filter, sort: browser.itemSort, emptyTitle: "Brak pozycji")
                .navigationTitle(filter.title)
                .toolbar {
                    ToolbarItem { SortMenu(sort: $browser.itemSort, options: SortMenu.bookOptions) }
                }
        }
    }
}
