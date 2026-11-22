import SwiftUI

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
                        let author = list.element(at: index)
                        AuthorCard(browser: browser, author: author)
                            .onAppear { list.ensureLoaded(index) }
                            .onChange(of: author == nil) { if author == nil { list.ensureLoaded(index) } }
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
        Button {
            if let author { browser.open(.author(id: author.id, name: author.name)) }
        } label: {
            VStack(spacing: 6) {
                AuthorPhoto(listening: browser.listening, author: author, size: 110)
                Text(author?.name ?? " ").font(.callout).lineLimit(2, reservesSpace: true).multilineTextAlignment(.center)
                Text(author?.numBooks.map { "Książki: \($0)" } ?? " ").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 130)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(author == nil)
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
        .task(id: ReloadKey(id: authorID, revision: browser.revision)) { await load() }
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
            if Task.isCancelled { return }
            self.error = error.localizedDescription
        }
    }
}
