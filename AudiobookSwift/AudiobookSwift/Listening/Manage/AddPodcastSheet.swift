import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Arkusz „Dodaj podcast” (przycisk „+” w bibliotece podcastów): wyszukiwanie w iTunes, adres
/// kanału RSS albo import pliku OPML — to, co web UI ma na stronie `podcast/search`.
/// Wszystko tokenem root (`ItemManager`): w upstreamie tylko administrator może dodawać podcasty.
struct AddPodcastSheet: View {
    let browser: LibraryBrowser
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable {
        case search = "Szukaj w iTunes", rss = "Adres RSS", opml = "Plik OPML"
    }

    @State private var mode = Mode.search
    @State private var term = ""
    @AppStorage("podcastSearch.country") private var country = "pl"
    @State private var rssURL = ""
    @State private var results: [AudiobookshelfClient.PodcastSearchResult] = []
    @State private var searched = false
    @State private var existing: [AudiobookshelfClient.PodcastTitle] = []
    @State private var busy: String?
    @State private var error: String?
    /// Kanał wybrany do dodania (formularz zastępuje listę).
    @State private var draft: NewPodcastDraft?
    @State private var opmlFeeds: [AudiobookshelfClient.OPMLFeed]?
    @State private var listenerSeesExplicit: Bool?

    static let countries: [(String, String)] = [
        ("pl", "Polska"), ("us", "USA"), ("gb", "Wielka Brytania"), ("de", "Niemcy"), ("fr", "Francja"),
        ("es", "Hiszpania"), ("it", "Włochy"), ("ca", "Kanada"), ("au", "Australia"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            if let draft = Binding($draft) {
                NewPodcastForm(browser: browser, draft: draft, listenerSeesExplicit: listenerSeesExplicit, onBack: { self.draft = nil }) { id in
                    dismiss()
                    if let id { browser.open(.item(id)) }
                }
            } else if let feeds = Binding($opmlFeeds) {
                OPMLImportForm(browser: browser, feeds: feeds.wrappedValue, onBack: { opmlFeeds = nil }) { dismiss() }
            } else {
                chooser
            }
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 560, idealHeight: 640)
        .task {
            listenerSeesExplicit = try? await browser.listening.api { try await $0.canAccessExplicitContent(token: $1) }
            if let libraryID = browser.libraryID {
                existing = (try? await browser.manager.run { try await $0.podcastTitles(libraryID: libraryID, token: $1) }) ?? []
            }
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dodaj podcast").font(.title2.weight(.semibold))
            Picker("Źródło", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("addPodcast.mode")
            switch mode {
            case .search: searchPane
            case .rss: rssPane
            case .opml: opmlPane
            }
            Spacer(minLength: 0)
            HStack {
                if let busy {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(.secondary)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled).lineLimit(3)
                        .accessibilityIdentifier("addPodcast.error")
                }
                Spacer()
                Button("Anuluj") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .font(.callout)
        }
        .padding(20)
    }

    // MARK: iTunes

    private var searchPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Nazwa podcastu albo autor", text: $term)
                    .onSubmit(search)
                    .accessibilityIdentifier("addPodcast.term")
                Picker("Sklep", selection: $country) { ForEach(Self.countries, id: \.0) { Text($0.1).tag($0.0) } }
                    .fixedSize()
                    .help("Sklep iTunes, w którym szukać")
                Button("Szukaj", action: search)
                    .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty || busy != nil)
                    .keyboardShortcut(.defaultAction)
            }
            if results.isEmpty {
                if searched { Text("Brak wyników z kanałem RSS.").foregroundStyle(.secondary) }
            } else {
                List(results, id: \.key) { result in
                    resultRow(result)
                }
                .listStyle(.inset)
                .accessibilityIdentifier("addPodcast.results")
            }
        }
    }

    private func resultRow(_ result: AudiobookshelfClient.PodcastSearchResult) -> some View {
        let existingID = existingItem(for: result)
        return Button {
            if let existingID {
                dismiss()
                browser.open(.item(existingID))
            } else if let feed = result.feedUrl {
                loadFeed(feed, from: result)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RemoteThumbnail(url: result.cover.flatMap(URL.init(string:)), size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(result.title ?? "").font(.headline).lineLimit(2)
                        if result.explicit == true { Text("dla dorosłych").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let artist = result.artistName { Text(artist).foregroundStyle(.secondary).lineLimit(1) }
                    HStack(spacing: 8) {
                        if let count = result.trackCount { Text("Odcinków: \(count)") }
                        if let genres = result.genres, !genres.isEmpty { Text(genres.prefix(3).joined(separator: ", ")) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if existingID != nil {
                    Label("Już w bibliotece", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy != nil)
        .help(existingID != nil ? "Otwórz podcast w bibliotece" : "Pokaż kanał i dodaj")
        .accessibilityIdentifier("addPodcast.result")
    }

    private func existingItem(for result: AudiobookshelfClient.PodcastSearchResult) -> String? {
        let title = result.title?.lowercased()
        return existing.first { p in
            (result.id != nil && p.itunesId == result.id.map(String.init)) || (title != nil && p.title?.lowercased() == title)
        }?.libraryItemId
    }

    private func search() {
        let term = term.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        // Wklejony adres kanału zamiast nazwy — jak w web UI.
        if term.hasPrefix("http://") || term.hasPrefix("https://") {
            loadFeed(term, from: nil)
            return
        }
        let country = country
        run("Szukanie w iTunes…", failure: "Nie udało się wyszukać") {
            results = try await browser.manager.run { try await $0.searchPodcasts(term: term, country: country, token: $1) }.filter { $0.feedUrl != nil }
            searched = true
        }
    }

    // MARK: RSS

    private var rssPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Adres kanału RSS", text: $rssURL, prompt: Text("https://…/feed.xml"))
                    .onSubmit { loadRSS() }
                    .accessibilityIdentifier("addPodcast.rss")
                Button("Wczytaj kanał") { loadRSS() }
                    .disabled(!CoverTab.isWebURL(rssURL) || busy != nil)
                    .keyboardShortcut(.defaultAction)
            }
            Text("Serwer pobierze kanał i pokaże jego dane przed dodaniem.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func loadRSS() {
        let url = rssURL.trimmingCharacters(in: .whitespaces)
        guard CoverTab.isWebURL(url) else { return }
        loadFeed(url, from: nil)
    }

    private func loadFeed(_ url: String, from result: AudiobookshelfClient.PodcastSearchResult?) {
        run("Wczytywanie kanału…", failure: "Nie udało się wczytać kanału") {
            do {
                let feed = try await browser.manager.run { try await $0.podcastFeed(url: url, token: $1) }
                guard let library = browser.library else { return }
                draft = NewPodcastDraft(feed: feed, result: result, feedURL: url, library: library)
            } catch AudiobookshelfClient.APIError.http(404, _) {
                throw Failure(text: "Nie udało się wczytać kanału: serwer nie pobrał go albo to nie jest kanał RSS podcastu.")
            }
        }
    }

    // MARK: OPML

    private var opmlPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plik OPML to lista subskrypcji wyeksportowana z innej aplikacji do podcastów. Po wczytaniu wybierzesz, które kanały dodać.")
                .foregroundStyle(.secondary)
            Button("Wybierz plik OPML…", systemImage: "doc") { chooseOPML() }
                .disabled(busy != nil)
                .accessibilityIdentifier("addPodcast.opml")
        }
    }

    private func chooseOPML() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml, .xml, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Wybierz plik OPML z subskrypcjami"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            error = "Nie udało się odczytać pliku „\(url.lastPathComponent)”."
            return
        }
        guard text.contains("<opml"), text.contains("<outline") else {
            error = "To nie wygląda na plik OPML (brak znaczników <opml> i <outline>)."
            return
        }
        run("Czytanie pliku OPML…", failure: "Nie udało się przeczytać pliku OPML") {
            let feeds = try await browser.manager.run { try await $0.parseOPML(text, token: $1) }
            if feeds.isEmpty { throw Failure(text: "W pliku nie ma żadnego kanału RSS.") }
            opmlFeeds = feeds
        }
    }

    // MARK: Wspólne

    struct Failure: Error { let text: String }

    private func run(_ label: String, failure: String, _ work: @escaping () async throws -> Void) {
        guard busy == nil else { return }
        busy = label
        error = nil
        Task {
            defer { busy = nil }
            do {
                try await work()
            } catch let failure as Failure {
                error = failure.text
            } catch {
                self.error = ItemManager.message(for: error, action: failure)
            }
        }
    }
}

/// Szkic nowego podcastu: pola z iTunes (gdy wybrany z wyszukiwania) albo z kanału — jak `NewModal.init`.
struct NewPodcastDraft {
    var title: String
    var author: String
    var description: String
    var releaseDate: String
    var genres: [String]
    var feedURL: String
    var imageURL: String
    var itunesPageURL: String
    var itunesID: String
    var itunesArtistID: String
    var language: String
    var explicit: Bool
    var type: String
    var autoDownload = false
    var folderID: String
    let folders: [AudiobookshelfClient.Library.Folder]
    let libraryID: String
    let episodes: [AudiobookshelfClient.FeedEpisode]
    let feedExplicit: Bool

    init(feed: AudiobookshelfClient.PodcastFeed, result: AudiobookshelfClient.PodcastSearchResult?, feedURL: String, library: AudiobookshelfClient.Library) {
        let m = feed.metadata
        title = result?.title ?? m.title ?? ""
        author = result?.artistName ?? m.author ?? ""
        description = HTMLText.plain(result?.description) ?? m.descriptionPlain ?? HTMLText.plain(m.description) ?? ""
        releaseDate = result?.releaseDate ?? ""
        genres = result?.genres ?? m.categories ?? []
        self.feedURL = result?.feedUrl ?? m.feedUrl ?? feedURL
        imageURL = result?.cover ?? m.image ?? ""
        itunesPageURL = result?.pageUrl ?? ""
        itunesID = result?.id.map(String.init) ?? ""
        itunesArtistID = result?.artistId.map(String.init) ?? ""
        language = m.language ?? ""
        let type = (m.type ?? "").lowercased()
        self.type = type == "serial" ? "serial" : "episodic"
        explicit = result?.explicit == true || m.isExplicit
        feedExplicit = explicit
        folders = library.folders
        folderID = library.folders.first?.id ?? ""
        libraryID = library.id
        episodes = feed.episodes
    }

    var folderName: String { AudiobookshelfClient.podcastFolderName(title) }

    var fullPath: String? {
        guard let folder = folders.first(where: { $0.id == folderID }), !folderName.isEmpty else { return nil }
        return URL(filePath: folder.fullPath).appending(path: folderName).path(percentEncoded: false)
    }

    var payload: AudiobookshelfClient.NewPodcast? {
        guard let fullPath else { return nil }
        let clean = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return .init(path: fullPath, folderId: folderID, libraryId: libraryID, media: .init(
            metadata: .init(
                title: clean(title), author: clean(author), description: HTMLText.html(fromPlain: clean(description)),
                releaseDate: releaseDate, genres: DetailsDraft.clean(genres), feedUrl: clean(feedURL), imageUrl: imageURL,
                itunesPageUrl: itunesPageURL, itunesId: itunesID, itunesArtistId: itunesArtistID,
                language: clean(language), explicit: explicit, type: type),
            autoDownloadEpisodes: autoDownload))
    }
}

/// Formularz przed dodaniem: dane kanału do poprawienia, folder, „dla dorosłych” z ostrzeżeniem.
private struct NewPodcastForm: View {
    let browser: LibraryBrowser
    @Binding var draft: NewPodcastDraft
    let listenerSeesExplicit: Bool?
    let onBack: () -> Void
    let onDone: (String?) -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                RemoteThumbnail(url: URL(string: draft.imageURL), size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.title.isEmpty ? "Nowy podcast" : draft.title).font(.title3.weight(.semibold)).lineLimit(2)
                    Text("Odcinków w kanale: \(draft.episodes.count)").font(.callout).foregroundStyle(.secondary)
                    if let newest = draft.episodes.compactMap(\.published).max() {
                        Text("Najnowszy: \(Formats.day(newest, long: true))").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(20)
            Form {
                Section {
                    TextField("Tytuł", text: $draft.title).accessibilityIdentifier("newPodcast.title")
                    TextField("Autor", text: $draft.author).accessibilityIdentifier("newPodcast.author")
                    TextField("Adres kanału RSS", text: $draft.feedURL)
                    LabeledContent("Gatunki") {
                        TokenInput(values: $draft.genres, suggestions: browser.filterData?.genres ?? [], placeholder: "Gatunek")
                    }
                    TextField("Język", text: $draft.language)
                    Picker("Typ", selection: $draft.type) {
                        Text("Odcinkowy (najnowsze pierwsze)").tag("episodic")
                        Text("Seryjny (po kolei)").tag("serial")
                    }
                }
                Section {
                    Toggle("Dla dorosłych", isOn: $draft.explicit).accessibilityIdentifier("newPodcast.explicit")
                    if draft.explicit, listenerSeesExplicit == false {
                        Label {
                            Text("Konto słuchacza nie ma dostępu do treści dla dorosłych — ten podcast nie pojawi się w oknie „Biblioteka” ani na telefonie."
                                + (draft.feedExplicit ? " Kanał sam się tak oznacza; odznacz, jeśli chcesz go słuchać na tym koncie." : ""))
                        } icon: { Image(systemName: "eye.slash") }
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("newPodcast.explicitWarning")
                    }
                    Toggle("Automatycznie pobieraj nowe odcinki", isOn: $draft.autoDownload)
                    if draft.autoDownload {
                        Text("Serwer sprawdza kanał co godzinę (harmonogram zmienisz potem w edycji podcastu). Teraz nic się nie pobierze — wybierz odcinki z kanału po dodaniu.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if draft.folders.count > 1 {
                        Picker("Folder biblioteki", selection: $draft.folderID) {
                            ForEach(draft.folders, id: \.id) { Text($0.fullPath).tag($0.id) }
                        }
                    }
                    LabeledContent("Folder podcastu") {
                        Text(draft.fullPath ?? "—").textSelection(.enabled).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                }
                Section("Opis") {
                    TextEditor(text: $draft.description).frame(minHeight: 90)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Wstecz", action: onBack)
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Dodawanie…").foregroundStyle(.secondary)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled).lineLimit(3)
                        .accessibilityIdentifier("newPodcast.error")
                }
                Spacer()
                Button("Dodaj podcast", action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || draft.payload == nil || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("newPodcast.create")
            }
            .font(.callout)
            .padding(16)
        }
        .task { await browser.loadFilterData() }
    }

    private func create() {
        guard let payload = draft.payload else { return }
        let hidden = draft.explicit && listenerSeesExplicit == false
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let id = try await browser.manager.run { try await $0.createPodcast(payload, token: $1) }
                browser.invalidateFilterData()
                // Ukryty przed słuchaczem — strona i tak by się nie otworzyła.
                onDone(hidden ? nil : id)
            } catch AudiobookshelfClient.APIError.http(400, let body) where body.contains("already exists") {
                error = "Podcast w folderze „\(draft.folderName)” już jest w bibliotece."
            } catch {
                self.error = ItemManager.message(for: error, action: "Nie udało się dodać podcastu")
            }
        }
    }
}

/// Import OPML: wybór kanałów, folder i automatyczne pobieranie; serwer dodaje je w tle.
private struct OPMLImportForm: View {
    let browser: LibraryBrowser
    let feeds: [AudiobookshelfClient.OPMLFeed]
    let onBack: () -> Void
    let onDone: () -> Void
    @State private var selected: Set<String> = []
    @State private var folderID = ""
    @State private var autoDownload = false
    @State private var busy = false
    @State private var error: String?

    private var folders: [AudiobookshelfClient.Library.Folder] { browser.library?.folders ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import OPML: \(feeds.count) kanałów").font(.title3.weight(.semibold))
            List(feeds) { feed in
                Toggle(isOn: Binding(get: { selected.contains(feed.id) }, set: { if $0 { selected.insert(feed.id) } else { selected.remove(feed.id) } })) {
                    VStack(alignment: .leading) {
                        Text(feed.title?.isEmpty == false ? feed.title! : feed.feedUrl)
                        Text(feed.feedUrl).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .listStyle(.inset)
            HStack {
                Button("Zaznacz wszystkie") { selected = Set(feeds.map(\.id)) }
                Button("Odznacz") { selected = [] }
                Spacer()
                if folders.count > 1 {
                    Picker("Folder", selection: $folderID) { ForEach(folders, id: \.id) { Text($0.fullPath).tag($0.id) } }.fixedSize()
                }
                Toggle("Automatycznie pobieraj nowe odcinki", isOn: $autoDownload)
            }
            Text("Serwer pobierze każdy kanał i doda podcasty w tle (zadanie „Import OPML”). Kanały, które już są w bibliotece, pominie.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Wstecz", action: onBack)
                if busy { ProgressView().controlSize(.small) }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3) }
                Spacer()
                Button("Dodaj zaznaczone (\(selected.count))", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || folderID.isEmpty || busy)
            }
            .font(.callout)
        }
        .padding(20)
        .onAppear {
            selected = Set(feeds.map(\.id))
            folderID = folders.first?.id ?? ""
        }
    }

    private func submit() {
        guard let libraryID = browser.libraryID else { return }
        let urls = feeds.map(\.feedUrl).filter(selected.contains)
        let folderID = folderID, autoDownload = autoDownload
        busy = true
        Task {
            defer { busy = false }
            do {
                try await browser.manager.run { try await $0.createPodcastsFromOPML(feeds: urls, libraryID: libraryID, folderID: folderID, autoDownload: autoDownload, token: $1) }
                onDone()
            } catch {
                self.error = ItemManager.message(for: error, action: "Nie udało się rozpocząć importu")
            }
        }
    }
}
