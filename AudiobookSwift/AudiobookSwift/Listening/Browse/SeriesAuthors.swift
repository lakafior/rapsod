import SwiftUI

// MARK: - Serie

/// Lista serii (stronami) z okładkami pierwszych tomów i postępem całej serii.
struct SeriesSection: View {
    @Bindable var browser: LibraryBrowser
    let libraryID: String
    @State private var list: PagedList<AudiobookshelfClient.Series>?

    private struct Query: Hashable {
        let libraryID: String
        let sort: LibraryBrowser.Sort
    }

    var body: some View {
        Group {
            if let list, let total = list.total {
                if total == 0 {
                    ContentUnavailableView("Brak serii", systemImage: "square.stack")
                } else {
                    PagedGrid(count: total, cellWidth: 210) { index in
                        SeriesCard(browser: browser, series: list.element(at: index))
                            .onAppear { list.ensureLoaded(index) }
                    }
                }
            } else {
                LoadingState(error: list?.error) { await list?.refresh() }
            }
        }
        .navigationTitle("Serie")
        .toolbar { ToolbarItem { SortMenu(sort: $browser.seriesSort, options: SortMenu.seriesOptions) } }
        .task(id: Query(libraryID: libraryID, sort: browser.seriesSort)) {
            let listening = browser.listening
            let (libraryID, sort) = (libraryID, browser.seriesSort)
            let list = PagedList<AudiobookshelfClient.Series>(pageSize: 40) { page, limit in
                let result = try await listening.api {
                    try await $0.seriesPage(libraryID: libraryID, page: page, limit: limit, sort: sort.key, descending: sort.descending, token: $1)
                }
                return (result.results.elements, result.total)
            }
            self.list = list
            await list.loadFirst()
        }
        .onChange(of: browser.revision) { Task { await list?.refresh() } }
    }
}

/// Karta serii: okładki pierwszych tomów jedna na drugiej, nazwa, liczba książek, postęp.
struct SeriesCard: View {
    let browser: LibraryBrowser
    let series: AudiobookshelfClient.Series?
    /// Inne przejście niż do strony serii (karta kolekcji).
    var open: (() -> Void)?

    var body: some View {
        let books = series?.items ?? []
        let finished = books.filter { browser.listening.progress[$0.id]?.isFinished == true }.count
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5))
                ForEach(Array(books.prefix(4).enumerated().reversed()), id: \.offset) { index, book in
                    AsyncCover(listening: browser.listening, itemID: book.id, path: book.media.coverPath, size: 120)
                        .frame(width: 120, height: 120)
                        .shadow(radius: 2)
                        .offset(x: CGFloat(index) * 26)
                }
                .padding(.leading, 6)
            }
            .frame(width: 210, height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(series?.name ?? " ").font(.callout).lineLimit(2, reservesSpace: true)
            HStack(spacing: 6) {
                Text(series == nil ? " " : "Książki: \(books.count)")
                if !books.isEmpty, finished > 0 {
                    Text(finished == books.count ? "· ukończona" : "· ukończone \(finished)")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 210)
        .contentShape(Rectangle())
        .onTapGesture {
            if let open { open() } else if let series { browser.open(.series(id: series.id, name: series.name)) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if let open { open() } else if let series { browser.open(.series(id: series.id, name: series.name)) } }
        .accessibilityIdentifier(series.map { "series.\($0.id)" } ?? "series.placeholder")
    }
}

/// Strona serii: opis, książki w kolejności tomów, oznaczenie całej serii.
struct SeriesPage: View {
    let browser: LibraryBrowser
    let seriesID: String
    let name: String
    @State private var series: AudiobookshelfClient.Series?
    @State private var feed: FeedTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let description = HTMLText.plain(series?.description) {
                ExpandableText(text: description, lines: 3).padding([.horizontal, .top], 20)
            }
            if let libraryID = browser.libraryID {
                ItemGrid(browser: browser, libraryID: libraryID, filter: .init(group: "series", value: seriesID, title: name),
                         sort: .init(key: "sequence", descending: false), seriesID: seriesID, selectionScope: "series-\(seriesID)")
            }
        }
        .navigationTitle(name)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Oznacz serię jako ukończoną") { Task { await mark(true) } }
                    Button("Oznacz serię jako nieukończoną") { Task { await mark(false) } }
                    if browser.manager.isAvailable {
                        Divider()
                        Button("Kanał RSS serii…") { feed = FeedTarget(kind: .series, id: seriesID, title: name) }
                    }
                } label: { Label("Seria", systemImage: "checkmark.circle") }
                .help("Postęp całej serii i kanał RSS")
            }
        }
        .sheet(item: $feed) { RSSFeedSheet(manager: browser.manager, target: $0) }
        .batchSelection(browser: browser, scope: "series-\(seriesID)")
        .task(id: seriesID) {
            guard let libraryID = browser.libraryID else { return }
            series = try? await browser.listening.api { try await $0.series(libraryID: libraryID, seriesID: seriesID, token: $1) }
        }
    }

    private func mark(_ finished: Bool) async {
        guard let libraryID = browser.libraryID else { return }
        let filter = AudiobookshelfClient.filter("series", seriesID)
        guard let page = try? await browser.listening.api({
            try await $0.itemsPage(libraryID: libraryID, page: 0, limit: 500, sort: "sequence", descending: false, filter: filter, token: $1)
        }) else { return }
        await browser.listening.setFinished(page.results.elements.map { .init(libraryItemId: $0.id, episodeId: nil, isFinished: finished) })
    }
}

// MARK: - Autorzy

struct AuthorsSection: View {
    @Bindable var browser: LibraryBrowser
    let libraryID: String
    @State private var list: PagedList<AudiobookshelfClient.Author>?

    private struct Query: Hashable {
        let libraryID: String
        let sort: LibraryBrowser.Sort
    }

    var body: some View {
        Group {
            if let list, let total = list.total {
                if total == 0 {
                    ContentUnavailableView("Brak autorów", systemImage: "person.2")
                } else {
                    PagedGrid(count: total, cellWidth: 130) { index in
                        AuthorCard(browser: browser, author: list.element(at: index))
                            .onAppear { list.ensureLoaded(index) }
                    }
                }
            } else {
                LoadingState(error: list?.error) { await list?.refresh() }
            }
        }
        .navigationTitle("Autorzy")
        .toolbar { ToolbarItem { SortMenu(sort: $browser.authorSort, options: SortMenu.authorOptions) } }
        .task(id: Query(libraryID: libraryID, sort: browser.authorSort)) {
            let listening = browser.listening
            let (libraryID, sort) = (libraryID, browser.authorSort)
            let list = PagedList<AudiobookshelfClient.Author>(pageSize: 60) { page, limit in
                let result = try await listening.api {
                    try await $0.authorsPage(libraryID: libraryID, page: page, limit: limit, sort: sort.key, descending: sort.descending, token: $1)
                }
                return (result.results.elements, result.total)
            }
            self.list = list
            await list.loadFirst()
        }
        .onChange(of: browser.revision) { Task { await list?.refresh() } }
    }
}

struct AuthorCard: View {
    let browser: LibraryBrowser
    let author: AudiobookshelfClient.Author?

    var body: some View {
        VStack(spacing: 6) {
            AuthorPhoto(listening: browser.listening, author: author, size: 110)
            Text(author?.name ?? " ").font(.callout).lineLimit(2, reservesSpace: true).multilineTextAlignment(.center)
            Text(author?.numBooks.map { "Książki: \($0)" } ?? " ").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 130)
        .contentShape(Rectangle())
        .onTapGesture { if let author { browser.open(.author(id: author.id, name: author.name)) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if let author { browser.open(.author(id: author.id, name: author.name)) } }
        .accessibilityIdentifier(author.map { "author.\($0.id)" } ?? "author.placeholder")
    }
}

struct AuthorPhoto: View {
    let listening: ListeningController
    let author: AudiobookshelfClient.Author?
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Circle().fill(.quaternary).overlay { Image(systemName: "person.fill").font(.system(size: size / 3)).foregroundStyle(.secondary) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: "\(author?.id ?? "")#\(listening.coverRevision["author-" + (author?.id ?? "")] ?? 0)|\(author?.imagePath ?? "")") {
            guard let author else { return }
            image = nil
            image = await listening.authorImage(id: author.id, path: author.imagePath, size: size)
        }
    }
}

/// Strona autora: zdjęcie, opis, książki i serie (`GET /api/authors/:id?include=items,series`).
struct AuthorPage: View {
    let browser: LibraryBrowser
    let authorID: String
    let name: String
    @State private var author: AudiobookshelfClient.AuthorDetail?
    @State private var error: String?
    @State private var editing = false

    var body: some View {
        Group {
            if let author {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top, spacing: 20) {
                            AuthorPhoto(listening: browser.listening, author: .init(id: author.id, name: author.name, description: nil, imagePath: author.imagePath, numBooks: nil, updatedAt: nil), size: 140)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(author.name).font(.largeTitle.weight(.semibold))
                                if let description = HTMLText.plain(author.description) {
                                    ExpandableText(text: description, lines: 6).frame(maxWidth: 700, alignment: .leading)
                                }
                            }
                        }
                        let books = author.libraryItems?.elements ?? []
                        if !books.isEmpty {
                            ShelfRow(title: "Książki (\(books.count))", action: ("Wszystkie", { browser.open(.filtered(.init(group: "authors", value: author.id, title: "Autor: \(author.name)"))) })) {
                                ForEach(books) { ItemCard(browser: browser, item: $0) }
                            }
                        }
                        ForEach(author.series?.elements ?? []) { series in
                            ShelfRow(title: series.name, action: ("Seria", { browser.open(.series(id: series.id, name: series.name)) })) {
                                ForEach(series.items.elements) { ItemCard(browser: browser, item: $0, sequence: $0.sequence(in: series.id)) }
                            }
                        }
                    }
                    .padding(24)
                }
            } else {
                LoadingState(error: error) { await load() }
            }
        }
        .navigationTitle(name)
        .toolbar {
            if browser.manager.isAvailable {
                ToolbarItem {
                    Button("Edytuj autora…", systemImage: "pencil") { editing = true }
                        .disabled(author == nil)
                        .help("Nazwa, opis, zdjęcie i dopasowanie w Audible")
                        .accessibilityIdentifier("author.edit")
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let author {
                AuthorEditSheet(browser: browser, author: author) { result in changed(result) }
            }
        }
        .task(id: authorID) { await load() }
        .onChange(of: browser.revision) { Task { await load() } }
    }

    /// Po edycji: inna nazwa albo połączenie z innym autorem podmienia stronę, usunięcie — zamyka ją.
    private func changed(_ result: (id: String, name: String)?) {
        if let libraryID = browser.libraryID { browser.listening.libraryChanged(libraryID) }
        let route = LibraryBrowser.Route.author(id: authorID, name: name)
        guard let result else {
            browser.path.removeAll { $0 == route }
            return
        }
        if result.id != authorID || result.name != name, let index = browser.path.lastIndex(of: route) {
            browser.path[index] = .author(id: result.id, name: result.name)
        } else {
            Task { await load() }
        }
    }

    private func load() async {
        do {
            author = try await browser.listening.api { try await $0.author(id: authorID, token: $1) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Lektorzy

struct NarratorsSection: View {
    let browser: LibraryBrowser
    let libraryID: String
    @State private var narrators: [AudiobookshelfClient.Narrator]?
    @State private var error: String?
    @State private var selection: String?
    @State private var renaming: AudiobookshelfClient.Narrator?
    @State private var newName = ""
    @State private var deleting: AudiobookshelfClient.Narrator?
    @State private var failure: String?

    var body: some View {
        Group {
            if let narrators {
                if narrators.isEmpty {
                    ContentUnavailableView("Brak lektorów", systemImage: "waveform")
                } else {
                    List(narrators, selection: $selection) { narrator in
                        HStack {
                            Text(narrator.name)
                            Spacer()
                            Text("Książki: \(narrator.numBooks ?? 0)").foregroundStyle(.secondary)
                        }
                        .tag(narrator.id)
                    }
                    .contextMenu(forSelectionType: String.self) { ids in
                        if let narrator = narrators.first(where: { ids.contains($0.id) }) {
                            NarratorManageMenu(browser: browser, libraryID: libraryID, narrator: narrator, renaming: $renaming, deleting: $deleting)
                        }
                    } primaryAction: { ids in
                        if let narrator = narrators.first(where: { ids.contains($0.id) }) { browser.open(.filtered(.narrator(narrator.name))) }
                    }
                    .onChange(of: selection) {
                        // Pojedyncze kliknięcie też otwiera listę książek lektora, jak link w web UI.
                        if let id = selection, let narrator = narrators.first(where: { $0.id == id }) {
                            selection = nil
                            browser.open(.filtered(.narrator(narrator.name)))
                        }
                    }
                }
            } else {
                LoadingState(error: error) { await load() }
            }
        }
        .navigationTitle("Lektorzy")
        .task(id: libraryID) { await load() }
        .onChange(of: browser.revision) { Task { await load() } }
        .onChange(of: renaming) { if let renaming { newName = renaming.name } }
        .alert("Nowa nazwa lektora", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { narrator in
            TextField("Nazwa", text: $newName)
            Button("Zmień") { Task { await rename(narrator) } }
            Button("Anuluj", role: .cancel) {}
        } message: { narrator in
            Text("„\(narrator.name)” zmieni się we wszystkich książkach tej biblioteki. Istniejąca nazwa połączy obu lektorów.")
        }
        .confirmationDialog("Usunąć lektora „\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { narrator in
            Button("Usuń ze wszystkich książek", role: .destructive) { Task { await remove(narrator) } }
            Button("Anuluj", role: .cancel) {}
        } message: { narrator in
            Text("Lektor zniknie z \(narrator.numBooks ?? 0) książek tej biblioteki. Książki zostają.")
        }
        .alert("Nie udało się", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: { Text(failure ?? "") }
    }

    private func rename(_ narrator: AudiobookshelfClient.Narrator) async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != narrator.name else { return }
        do {
            _ = try await browser.manager.run { try await $0.renameNarrator(libraryID: libraryID, narratorID: narrator.id, to: name, token: $1) }
            browser.invalidateFilterData()
            await load()
        } catch {
            failure = ItemManager.message(for: error, action: "Zmiana nazwy lektora")
        }
    }

    private func remove(_ narrator: AudiobookshelfClient.Narrator) async {
        do {
            _ = try await browser.manager.run { try await $0.removeNarrator(libraryID: libraryID, narratorID: narrator.id, token: $1) }
            browser.invalidateFilterData()
            await load()
        } catch {
            failure = ItemManager.message(for: error, action: "Usuwanie lektora")
        }
    }

    private func load() async {
        do {
            narrators = try await browser.listening.api { try await $0.narrators(libraryID: libraryID, token: $1) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Pozioma półka kart z tytułem (strona startowa, autor, wyniki wyszukiwania).
struct ShelfRow<Content: View>: View {
    let title: String
    var action: (label: String, perform: () -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                if let action { Button(action.label, action: action.perform).buttonStyle(.link) }
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 18) { content }
                    .padding(.bottom, 6)
            }
            .scrollIndicators(.automatic)
        }
    }
}
