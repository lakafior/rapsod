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
    @State private var dropTargeted = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appearsActive) private var appearsActive
    @FocusState private var searchFocused: Bool

    init(listening: ListeningController, supervisor: ServerSupervisor, account: ServerAccount, settings: SettingsNavigation) {
        self.listening = listening
        self.supervisor = supervisor
        self.account = account
        self.settings = settings
        _browser = State(initialValue: LibraryBrowser(listening: listening, account: account))
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
        .task { await LibraryTour.runIfRequested(browser: browser, account: account) }
        .onDisappear {
            listening.windowClosed()
            browser.manager.tasks.shutdown()
        }
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
        // Wgrywanie (etap 9e): foldery albo pliki upuszczone na okno trafiają do arkusza wgrywania.
        .dropDestination(for: URL.self) { urls, _ in
            guard browser.manager.isAvailable, !browser.showsUpload, !urls.isEmpty else { return false }
            browser.upload(urls)
            return true
        } isTargeted: { dropTargeted = $0 && browser.manager.isAvailable }
        .overlay {
            if dropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.tint.opacity(0.08))
                    RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    Label("Upuść, żeby wgrać do biblioteki", systemImage: "square.and.arrow.down")
                        .font(.title2.weight(.medium)).padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(8)
                .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $browser.showsUpload) {
            if let upload = browser.upload { UploadSheet(model: upload) }
        }
        .searchable(text: $browser.searchText, placement: .toolbar, prompt: browser.isPodcastLibrary ? "Szukaj podcastów i odcinków" : "Szukaj książek, autorów, serii")
        .searchFocused($searchFocused)
        .onChange(of: searchFocused) { browser.textField("search", focused: searchFocused) }
        .inspector(isPresented: $showsPlayer) {
            PlayerPanel(listening: listening)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
        }
        .toolbar {
            if let upload = browser.upload, upload.isRunning, !browser.showsUpload {
                ToolbarItem {
                    Button {
                        browser.showsUpload = true
                    } label: {
                        HStack(spacing: 6) {
                            ProgressView(value: upload.overallProgress).frame(width: 60)
                            Text("Wysyłanie…")
                        }
                    }
                    .help("Wgrywanie do biblioteki — pokaż szczegóły")
                    .accessibilityIdentifier("upload.toolbar")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(showsPlayer ? "Schowaj odtwarzacz" : "Pokaż odtwarzacz", systemImage: "sidebar.trailing") { showsPlayer.toggle() }
            }
        }
        .task {
            await listening.windowActivated()
            browser.ensureLibrary()
        }
        .onChange(of: appearsActive) {
            // Powrót do okna: świeży postęp, nawet gdyby zdarzenia serwera coś zgubiły.
            if appearsActive { Task { await listening.refreshMe() } }
        }
        .onChange(of: listening.libraries) { browser.ensureLibrary() }
        // Kolejność, nazwy i foldery bibliotek zmieniane w ustawieniach (etap 9i).
        .onChange(of: account.libraries) { Task { await listening.refresh() } }
        .task(id: browser.libraryID) { await browser.loadPlaylists() }
        // `item:` przekazuje pozycję do akcji — zamknięcie alertu zeruje `newPlaylistEntry` wcześniej.
        .alert("Nowa playlista", item: $browser.newPlaylistEntry) { entry in
            TextField("Nazwa", text: $newPlaylistName)
            Button("Utwórz") {
                let name = newPlaylistName
                Task { await browser.createPlaylist(name: name, with: entry) }
                newPlaylistName = ""
            }
            Button("Anuluj", role: .cancel) { newPlaylistName = "" }
        }
        .alert("Nie udało się", item: Bindable(listening).loadError) { _ in
            Button("OK") { listening.loadError = nil }
        } message: {
            Text($0)
        }
        // Menu Widok: „Jako kafelki” / „Jako lista” dla widoku na wierzchu (etap 14c).
        .focusedSceneValue(\.libraryBrowser, browser)
        // Spacja przełącza odtwarzanie tylko wtedy, gdy nie pisze się w polu tekstowym okna.
        .environment(\.playPauseOnSpace, browser.focusedTextFields.isEmpty)
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
                case .downloads: DownloadsView(browser: browser, libraryID: libraryID)
                case .stats: StatsView(listening: listening)
                case .libraryStats: LibraryStatsView(browser: browser, libraryID: libraryID)
                case .metadata: MetadataValuesSection(browser: browser, libraryID: libraryID)
                }
            }
        } else if listening.libraries.isEmpty, !listening.isRefreshing {
            ContentUnavailableView("Brak bibliotek", systemImage: "books.vertical", description: Text("Dodaj bibliotekę w Ustawieniach → Biblioteki („Dodaj audiobooki…”)."))
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
                    // Licznik przed `tag` — `.badge` na gotowym wierszu odbierał mu zaznaczanie.
                    row("Pobieranie", "arrow.down.circle", .downloads, badge: browser.listening.episodeDownloads.activeCount(libraryID: browser.libraryID))
                } else {
                    row("Książki", "books.vertical", .items)
                    row("Serie", "square.stack", .series)
                    row("Autorzy", "person.2", .authors)
                    row("Lektorzy", "waveform", .narrators)
                    row("Kolekcje", "rectangle.stack", .collections)
                }
                row("Playlisty", "music.note.list", .playlists)
                row("Statystyki biblioteki", "chart.pie", .libraryStats)
                if browser.manager.isAvailable {
                    row("Tagi i gatunki", "tag", .metadata)
                }
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
    func row(_ title: String, _ symbol: String, _ section: LibraryBrowser.Section, badge: Int = 0) -> some View {
        Label(title, systemImage: symbol)
            .badge(badge)
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
            ItemGrid(browser: browser, libraryID: libraryID, filter: filter, sort: $browser.itemSort, context: .filtered, emptyTitle: "Brak pozycji")
                .navigationTitle(filter.title)
                .toolbar {
                    ToolbarItem { ViewModePicker(browser: browser, context: .filtered) }
                    ToolbarItem { SortMenu(sort: $browser.itemSort, options: SortMenu.bookOptions) }
                }
        }
    }
}
