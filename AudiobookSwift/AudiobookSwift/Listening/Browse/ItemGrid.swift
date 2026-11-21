import SwiftUI

/// Siatka okładek pozycji biblioteki, wczytywana stronami (`PagedList`). Komórki istnieją
/// tylko na ekranie (`LazyVGrid`), a okładki czyta pamięć podręczna z limitem.
struct ItemGrid: View {
    let browser: LibraryBrowser
    let libraryID: String
    let filter: LibraryBrowser.ItemFilter?
    let sort: LibraryBrowser.Sort
    /// Seria, której numery tomów pokazują karty.
    var seriesID: String?
    var emptyTitle = "Brak pozycji"

    @State private var list: PagedList<AudiobookshelfClient.LibraryItem>?

    private struct Query: Hashable {
        let libraryID: String
        let filter: String?
        let sort: LibraryBrowser.Sort
    }

    var body: some View {
        Group {
            if let list, let total = list.total {
                if total == 0 {
                    ContentUnavailableView(emptyTitle, systemImage: "books.vertical")
                } else {
                    PagedGrid(count: total, cellWidth: ItemCard.width) { index in
                        let item = list.element(at: index)
                        ItemCard(browser: browser, item: item, sequence: seriesID.flatMap { item?.sequence(in: $0) })
                            .onAppear { list.ensureLoaded(index) }
                    }
                    .accessibilityIdentifier("itemGrid")
                }
            } else {
                LoadingState(error: list?.error) { await list?.refresh() }
            }
        }
        .task(id: Query(libraryID: libraryID, filter: filter?.query, sort: sort)) {
            let api = browser.listening
            let (libraryID, filter, sort) = (libraryID, filter?.query, sort)
            let list = PagedList<AudiobookshelfClient.LibraryItem> { page, limit in
                let result = try await api.api {
                    try await $0.itemsPage(libraryID: libraryID, page: page, limit: limit, sort: sort.key, descending: sort.descending, filter: filter, token: $1)
                }
                return (result.results.elements, result.total)
            }
            self.list = list
            await list.loadFirst()
        }
        .onChange(of: browser.revision) {
            Task { await list?.refresh() }
        }
    }

    /// Kolumny siatek niestronicowanych (kolekcja).
    static let columns = [GridItem(.adaptive(minimum: ItemCard.width, maximum: ItemCard.width + 30), spacing: 18, alignment: .top)]
}

/// Sekcja „Książki” (albo „Podcasty”): siatka z sortowaniem i filtrem w pasku narzędzi.
struct ItemsSection: View {
    @Bindable var browser: LibraryBrowser
    let libraryID: String

    @State private var addsPodcast = false

    var body: some View {
        let podcast = browser.isPodcastLibrary
        ItemGrid(browser: browser, libraryID: libraryID, filter: browser.filter, sort: podcast ? browser.podcastSort : browser.itemSort,
                 emptyTitle: browser.filter == nil ? "Pusta biblioteka" : "Nic nie pasuje do filtra")
            .navigationTitle(browser.filter?.title ?? (podcast ? "Podcasty" : "Książki"))
            .sheet(isPresented: $addsPodcast) { AddPodcastSheet(browser: browser) }
            .toolbar {
                ToolbarItemGroup {
                    if podcast {
                        Button("Dodaj podcast", systemImage: "plus") { addsPodcast = true }
                            .disabled(!browser.manager.isAvailable)
                            .help(browser.manager.isAvailable ? "Dodaj podcast z iTunes, adresu RSS albo pliku OPML" : browser.manager.unavailableReason)
                            .accessibilityIdentifier("podcast.add")
                        SortMenu(sort: $browser.podcastSort, options: SortMenu.podcastOptions)
                    } else {
                        SortMenu(sort: $browser.itemSort, options: SortMenu.bookOptions)
                    }
                    FilterMenu(browser: browser)
                }
            }
    }
}

struct SortMenu: View {
    @Binding var sort: LibraryBrowser.Sort
    let options: [(label: String, key: String)]

    var body: some View {
        Menu {
            Picker("Sortuj według", selection: Binding(get: { sort.key }, set: { key in
                // Jak w web UI: tytuł i autor rosnąco, reszta (daty, rozmiar, postęp) malejąco.
                sort = .init(key: key, descending: !Self.ascendingKeys.contains(key))
            })) {
                ForEach(options, id: \.key) { Text($0.label).tag($0.key) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Malejąco", isOn: $sort.descending)
        } label: {
            Label("Sortowanie", systemImage: "arrow.up.arrow.down")
        }
        .help("Sortowanie")
        .accessibilityIdentifier("sortMenu")
    }

    static let ascendingKeys: Set = ["media.metadata.title", "media.metadata.authorName", "media.metadata.authorNameLF", "media.metadata.author", "sequence", "name", "lastFirst"]

    static let bookOptions: [(label: String, key: String)] = [
        ("Tytuł", "media.metadata.title"),
        ("Autor (imię i nazwisko)", "media.metadata.authorName"),
        ("Autor (nazwisko, imię)", "media.metadata.authorNameLF"),
        ("Rok wydania", "media.metadata.publishedYear"),
        ("Data dodania", "addedAt"),
        ("Rozmiar", "size"),
        ("Czas trwania", "media.duration"),
        ("Data utworzenia pliku", "birthtimeMs"),
        ("Data modyfikacji pliku", "mtimeMs"),
        ("Ostatnio słuchane", "progress"),
        ("Data rozpoczęcia", "progress.createdAt"),
        ("Data ukończenia", "progress.finishedAt"),
        ("Losowo", "random"),
    ]

    static let podcastOptions: [(label: String, key: String)] = [
        ("Tytuł", "media.metadata.title"),
        ("Autor", "media.metadata.author"),
        ("Data dodania", "addedAt"),
        ("Rozmiar", "size"),
        ("Liczba odcinków", "media.numTracks"),
        ("Data utworzenia pliku", "birthtimeMs"),
        ("Data modyfikacji pliku", "mtimeMs"),
        ("Losowo", "random"),
    ]

    static let seriesOptions: [(label: String, key: String)] = [
        ("Nazwa", "name"),
        ("Liczba książek", "numBooks"),
        ("Data dodania", "addedAt"),
        ("Ostatnio dodana książka", "lastBookAdded"),
        ("Ostatnio zmieniona książka", "lastBookUpdated"),
        ("Łączny czas", "totalDuration"),
        ("Losowo", "random"),
    ]

    static let authorOptions: [(label: String, key: String)] = [
        ("Imię i nazwisko", "name"),
        ("Nazwisko, imię", "lastFirst"),
        ("Liczba książek", "numBooks"),
        ("Data dodania", "addedAt"),
        ("Data zmiany", "updatedAt"),
    ]
}

/// Filtry siatki z wartościami z `filterdata` (jak menu filtra w web UI). Długie listy
/// (autorzy, serie, lektorzy…) otwierają się w okienku z wyszukiwaniem dopiero po wyborze
/// kategorii — menu z tysiącami pozycji budowane z góry kosztowało dziesiątki MB.
struct FilterMenu: View {
    let browser: LibraryBrowser
    @State private var picking: Category?

    typealias Filter = LibraryBrowser.ItemFilter

    enum Category: String, Identifiable, CaseIterable {
        case genres = "Gatunek", tags = "Tag", series = "Seria", authors = "Autor", narrators = "Lektor",
             publishers = "Wydawca", languages = "Język", decades = "Dekada wydania"
        var id: String { rawValue }
        var forPodcasts: Bool { [.genres, .tags, .languages].contains(self) }
    }

    var body: some View {
        Menu {
            if browser.filter != nil {
                Button("Wszystkie pozycje") { browser.filter = nil }
                Divider()
            }
            if !browser.isPodcastLibrary {
                Menu("Postęp") {
                    choice(.init(group: "progress", value: "finished", title: "Ukończone"))
                    choice(.init(group: "progress", value: "in-progress", title: "W trakcie"))
                    choice(.init(group: "progress", value: "not-started", title: "Nierozpoczęte"))
                    choice(.init(group: "progress", value: "not-finished", title: "Nieukończone"))
                }
            }
            ForEach(Category.allCases.filter { !browser.isPodcastLibrary || $0.forPodcasts }) { category in
                Button(category.rawValue + "…") { picking = category }
            }
            if !browser.isPodcastLibrary {
                Divider()
                Menu("Pliki audio") {
                    choice(.init(group: "tracks", value: "single", title: "Jeden plik"))
                    choice(.init(group: "tracks", value: "multi", title: "Wiele plików"))
                }
                choice(.init(group: "abridged", value: "", title: "Skrócone"))
            }
        } label: {
            Label("Filtr", systemImage: browser.filter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help(browser.filter?.title ?? "Filtr")
        .accessibilityIdentifier("filterMenu")
        .popover(item: $picking, arrowEdge: .bottom) { category in
            FilterValuePicker(browser: browser, category: category) { picking = nil }
        }
    }

    private func choice(_ filter: Filter) -> some View {
        Toggle(filter.title, isOn: Binding(get: { browser.filter == filter }, set: { browser.filter = $0 ? filter : nil }))
    }
}

/// Wartości jednej kategorii filtra z wyszukiwaniem (lista z ponownym użyciem komórek).
private struct FilterValuePicker: View {
    let browser: LibraryBrowser
    let category: FilterMenu.Category
    let done: () -> Void
    @State private var query = ""

    private struct Value: Identifiable {
        let filter: LibraryBrowser.ItemFilter
        let label: String
        var id: String { filter.group + "." + filter.value }
    }

    var body: some View {
        let values = self.values.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) }
        VStack(spacing: 8) {
            TextField("Szukaj: \(category.rawValue.lowercased())", text: $query)
                .textFieldStyle(.roundedBorder)
            List(values) { value in
                Button {
                    browser.filter = value.filter
                    done()
                } label: {
                    HStack {
                        Text(value.label).lineLimit(1)
                        Spacer()
                        if browser.filter == value.filter { Image(systemName: "checkmark") }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .overlay { if browser.filterData == nil { ProgressView() } else if values.isEmpty { Text("Brak").foregroundStyle(.secondary) } }
        }
        .padding(10)
        .frame(width: 300, height: 380)
        .task { await browser.loadFilterData() }
    }

    private var values: [Value] {
        let data = browser.filterData
        typealias F = LibraryBrowser.ItemFilter
        func strings(_ list: [String]?, _ make: (String) -> F) -> [Value] { (list ?? []).map { Value(filter: make($0), label: $0) } }
        switch category {
        case .genres: return strings(data?.genres, F.genre)
        case .tags: return strings(data?.tags, F.tag)
        case .narrators: return strings(data?.narrators, F.narrator)
        case .publishers: return strings(data?.publishers, F.publisher)
        case .languages: return strings(data?.languages, F.language)
        case .decades: return strings(data?.publishedDecades) { F(group: "publishedDecades", value: $0, title: "Lata \($0)") }
        case .authors: return (data?.authors ?? []).map { Value(filter: F(group: "authors", value: $0.id, title: "Autor: \($0.name)"), label: $0.name) }
        case .series:
            let none = Value(filter: F(group: "series", value: "no-series", title: "Bez serii"), label: "Bez serii")
            return [none] + (data?.series ?? []).map { Value(filter: F(group: "series", value: $0.id, title: "Seria: \($0.name)"), label: $0.name) }
        }
    }
}

/// Siatka dla długich list: wiersze kart w `List`, która na macOS używa ponownie komórek
/// (NSTableView). `LazyVGrid` zachowuje stan każdej komórki, przez którą się przewinęło,
/// więc przy kilku tysiącach pozycji pamięć rosła z przewijaniem; tu rośnie tylko z liczbą
/// widocznych wierszy.
struct PagedGrid<Cell: View>: View {
    let count: Int
    let cellWidth: CGFloat
    var spacing: CGFloat = 18
    @ViewBuilder let cell: (Int) -> Cell

    var body: some View {
        GeometryReader { proxy in
            let columns = max(1, Int((proxy.size.width - 40 + spacing) / (cellWidth + spacing)))
            let rows = (count + columns - 1) / columns
            List(0..<rows, id: \.self) { row in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(row * columns ..< min(count, (row + 1) * columns), id: \.self) { index in
                        cell(index)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}
