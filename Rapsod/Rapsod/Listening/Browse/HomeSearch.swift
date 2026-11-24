import AudiobookshelfKit
import SwiftUI

/// Strona startowa: półki serwera (`/personalized`) — słuchaj dalej, kolejne w serii, ostatnio
/// dodane, ostatnie serie, odkrywaj, posłuchaj ponownie, nowi autorzy (w podcastach: odcinki).
struct HomeView: View {
    let browser: LibraryBrowser
    let libraryID: String
    @State private var shelves: [AudiobookshelfClient.Shelf]?
    @State private var error: String?

    private struct Trigger: Hashable {
        let libraryID: String
        let revision: Int
        /// Zmiana zbioru rozpoczętych/ukończonych pozycji zmienia półki „Słuchaj dalej” i „Posłuchaj ponownie”.
        let progress: Int
    }

    var body: some View {
        Group {
            if let shelves {
                if shelves.isEmpty {
                    ContentUnavailableView("Pusta biblioteka", systemImage: "books.vertical")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            ForEach(shelves) { shelf in shelfView(shelf) }
                        }
                        .padding(20)
                    }
                }
            } else {
                LoadingState(error: error) { await load() }
            }
        }
        .navigationTitle("Start")
        .task(id: Trigger(libraryID: libraryID, revision: browser.revision, progress: browser.listening.shelfRevision)) { await load() }
    }

    @ViewBuilder private func shelfView(_ shelf: AudiobookshelfClient.Shelf) -> some View {
        let title = Self.titles[shelf.id] ?? shelf.label
        switch shelf.entities {
        case .items(let items):
            ShelfRow(title: title) {
                ForEach(items) { item in
                    ItemCard(browser: browser, item: item, sequence: shelf.id == "continue-series" ? item.sequence() : nil)
                }
            }
        case .series(let series):
            ShelfRow(title: title) {
                ForEach(series) { SeriesCard(browser: browser, series: $0) }
            }
        case .authors(let authors):
            ShelfRow(title: title) {
                ForEach(authors) { AuthorCard(browser: browser, author: $0) }
            }
        }
    }

    private func load() async {
        do {
            shelves = try await browser.listening.api { try await $0.personalized(libraryID: libraryID, token: $1) }
            error = nil
        } catch {
            // Wczytanie zastąpione nowszym (zmiana biblioteki albo postępu) — bez komunikatu.
            if Task.isCancelled { return }
            if shelves == nil { self.error = error.localizedDescription }
        }
    }

    static let titles = [
        "continue-listening": "Słuchaj dalej",
        "continue-reading": "Czytaj dalej",
        "continue-series": "Kolejne w serii",
        "recently-added": "Ostatnio dodane",
        "recent-series": "Ostatnie serie",
        "discover": "Odkrywaj",
        "listen-again": "Posłuchaj ponownie",
        "read-again": "Przeczytaj ponownie",
        "newest-authors": "Nowi autorzy",
        "newest-episodes": "Najnowsze odcinki",
    ]
}

/// Wyniki wyszukiwania w bibliotece (`/search`): książki, serie, autorzy, lektorzy, gatunki, tagi;
/// w podcastach podcasty i odcinki.
struct SearchView: View {
    let browser: LibraryBrowser
    let libraryID: String
    let text: String
    @State private var results: AudiobookshelfClient.SearchResults?
    @State private var error: String?

    var body: some View {
        Group {
            if let results {
                if results.isEmpty {
                    ContentUnavailableView.search(text: text)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) { sections(results) }.padding(20)
                    }
                }
            } else {
                LoadingState(error: error) { await search() }
            }
        }
        .navigationTitle("Wyniki: \(text)")
        .task(id: text) {
            // Krótka pauza: zapytanie po skończeniu pisania, nie po każdej literze.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    @ViewBuilder private func sections(_ results: AudiobookshelfClient.SearchResults) -> some View {
        let books = (results.book?.elements ?? []) + (results.podcast?.elements ?? [])
        if !books.isEmpty {
            ShelfRow(title: browser.isPodcastLibrary ? "Podcasty" : "Książki") {
                ForEach(books, id: \.libraryItem.id) { ItemCard(browser: browser, item: $0.libraryItem) }
            }
        }
        if let episodes = results.episodes?.elements, !episodes.isEmpty {
            ShelfRow(title: "Odcinki") {
                ForEach(episodes, id: \.libraryItem.recentEpisode?.id) { ItemCard(browser: browser, item: $0.libraryItem) }
            }
        }
        if let series = results.series?.elements, !series.isEmpty {
            ShelfRow(title: "Serie") {
                ForEach(series, id: \.series.id) { hit in
                    SeriesCard(browser: browser, series: .init(id: hit.series.id, name: hit.series.name, description: nil, books: hit.books))
                }
            }
        }
        if let authors = results.authors?.elements, !authors.isEmpty {
            ShelfRow(title: "Autorzy") {
                ForEach(authors) { AuthorCard(browser: browser, author: $0) }
            }
        }
        chips("Lektorzy", results.narrators?.elements) { .narrator($0) }
        chips("Gatunki", results.genres?.elements) { .genre($0) }
        chips("Tagi", results.tags?.elements) { .tag($0) }
    }

    @ViewBuilder
    private func chips(_ title: String, _ values: [AudiobookshelfClient.SearchResults.Count]?, _ filter: @escaping (String) -> LibraryBrowser.ItemFilter) -> some View {
        if let values, !values.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title2.weight(.semibold))
                FlowLayout(spacing: 8) {
                    ForEach(values, id: \.name) { value in
                        Button("\(value.name) (\(value.count))") { browser.open(.filtered(filter(value.name))) }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func search() async {
        do {
            results = try await browser.listening.api { try await $0.search(libraryID: libraryID, query: text, token: $1) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Najnowsze nieukończone odcinki wszystkich podcastów biblioteki.
struct LatestEpisodesView: View {
    let browser: LibraryBrowser
    let libraryID: String
    @State private var episodes: [AudiobookshelfClient.PodcastEpisode]?
    @State private var error: String?
    @State private var shown: AudiobookshelfClient.PodcastEpisode?

    var body: some View {
        Group {
            if let episodes {
                if episodes.isEmpty {
                    ContentUnavailableView("Brak nowych odcinków", systemImage: "clock", description: Text("Wszystkie odcinki są przesłuchane."))
                } else {
                    List(episodes) { episode in
                        if let itemID = episode.libraryItemId {
                            EpisodeRow(browser: browser, itemID: itemID, libraryID: libraryID, episode: episode, podcastTitle: episode.podcast?.metadata?.title) {
                                browser.open(.item(itemID))
                            }
                        }
                    }
                }
            } else {
                LoadingState(error: error) { await load() }
            }
        }
        .navigationTitle("Najnowsze odcinki")
        // Zmiana biblioteki albo zdarzenie serwera: nowe wczytanie przerywa poprzednie.
        .task(id: ReloadKey(id: libraryID, revision: browser.revision)) { await load() }
    }

    private func load() async {
        do {
            episodes = try await browser.listening.api { try await $0.recentEpisodes(libraryID: libraryID, page: 0, limit: 100, token: $1) }
            error = nil
        } catch {
            if Task.isCancelled { return }
            self.error = error.localizedDescription
        }
    }
}
