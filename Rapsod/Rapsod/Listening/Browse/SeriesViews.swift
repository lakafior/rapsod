import AudiobookshelfKit
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
                        let series = list.element(at: index)
                        SeriesCard(browser: browser, series: series)
                            .onAppear { list.ensureLoaded(index) }
                            .onChange(of: series == nil) { if series == nil { list.ensureLoaded(index) } }
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
        // Przycisk, nie gest: karta dostaje fokus klawiatury i działa z VoiceOver jak przycisk.
        Button(action: activate) {
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
                SeriesCardProgress(listening: browser.listening, series: series)
            }
            .frame(width: 210)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(series == nil)
        .accessibilityIdentifier(series.map { "series.\($0.id)" } ?? "series.placeholder")
    }

    private func activate() {
        if let open { open() } else if let series { browser.open(.series(id: series.id, name: series.name)) }
    }
}

/// Liczba książek i ukończonych w karcie serii. Osobny widok: tylko on czyta słownik postępu,
/// więc synchronizacja postępu nie przebudowuje okładek wszystkich kart.
private struct SeriesCardProgress: View {
    let listening: ListeningController
    let series: AudiobookshelfClient.Series?

    var body: some View {
        let books = series?.items ?? []
        let finished = books.filter { listening.progress[$0.id]?.isFinished == true }.count
        HStack(spacing: 6) {
            Text(series == nil ? " " : "Książki: \(books.count)")
            if !books.isEmpty, finished > 0 {
                Text(finished == books.count ? "· ukończona" : "· ukończone \(finished)")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
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

    /// Wszystkie tomy serii (stronami po 500), potem jedno oznaczenie. Błąd trafia do alertu okna.
    private func mark(_ finished: Bool) async {
        guard let libraryID = browser.libraryID else { return }
        let listening = browser.listening
        let filter = AudiobookshelfClient.filter("series", seriesID)
        let limit = 500
        var ids: [String] = []
        do {
            var page = 0
            while true {
                let current = page
                let result = try await listening.api {
                    try await $0.itemsPage(libraryID: libraryID, page: current, limit: limit, sort: "sequence", descending: false, filter: filter, token: $1)
                }
                let elements = result.results.elements
                ids += elements.map(\.id)
                if elements.count < limit || ids.count >= (result.total ?? ids.count) { break }
                page += 1
            }
        } catch {
            listening.loadError = error.localizedDescription
            return
        }
        await listening.setFinished(ids.map { .init(libraryItemId: $0, episodeId: nil, isFinished: finished) })
    }
}
