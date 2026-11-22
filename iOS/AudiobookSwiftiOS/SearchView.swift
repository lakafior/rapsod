// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AudiobookshelfKit
import AudiobookshelfPlayback

/// Zakładka „Szukaj”: wszystkie biblioteki książek i podcastów naraz, wyniki w grupach.
struct SearchView: View {
    let model: AppModel
    let session: ServerSession

    @State private var text = ""
    @State private var results: CombinedLibraries.SearchResults?
    @State private var podcastResults: CombinedLibraries.PodcastSearchResults?
    @State private var error: String?
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            List {
                if let results {
                    FailureNotice(failures: results.failures)
                    if !results.books.isEmpty {
                        Section("Książki") {
                            ForEach(results.books) { book in
                                NavigationLink(value: Route.item(book.id)) {
                                    BookRow(book: book, session: session)
                                }
                            }
                        }
                    }
                    if !results.series.isEmpty {
                        Section("Serie") {
                            ForEach(results.series) { series in
                                NavigationLink(value: Route.series(series)) {
                                    Label(series.first.name, systemImage: "square.stack")
                                }
                            }
                        }
                    }
                    if !results.authors.isEmpty {
                        Section("Autorzy") {
                            ForEach(results.authors) { author in
                                NavigationLink(value: Route.author(author)) {
                                    Label(author.first.name, systemImage: "person")
                                }
                            }
                        }
                    }
                    if let podcastResults {
                        if !podcastResults.podcasts.isEmpty {
                            Section("Podcasty") {
                                ForEach(podcastResults.podcasts) { podcast in
                                    NavigationLink(value: Route.item(podcast.id)) {
                                        BookRow(book: podcast, session: session)
                                    }
                                }
                            }
                        }
                        if !podcastResults.episodes.isEmpty {
                            Section("Odcinki na serwerze") {
                                ForEach(podcastResults.episodes, id: \.recentEpisode?.id) { item in
                                    if let episode = item.recentEpisode {
                                        CompactEpisodeRow(itemID: item.id, title: episode.title ?? "Odcinek", podcastTitle: item.title,
                                                          keys: [PlaybackTimeline.key(item.id, episode.id)], localOnly: false, session: session, playback: model.playback) {
                                            Task { await model.playback.play(itemID: item.id, episodeID: episode.id) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !results.narrators.isEmpty {
                        Section("Lektorzy") {
                            ForEach(results.narrators, id: \.name) { narrator in
                                NavigationLink(value: Route.narrator(narrator.name)) {
                                    LabeledContent {
                                        Text(PolishCount.books(narrator.count))
                                    } label: {
                                        Label(narrator.name, systemImage: "mic")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("Szukaj we wszystkich bibliotekach", systemImage: "magnifyingglass",
                                           description: Text("Tytuł, autor, seria, lektor albo podcast."))
                } else if let error, results == nil {
                    LoadFailureView(message: error) { Task { await search(text, debounce: false) } }
                } else if let results, results.isEmpty, podcastResults?.isEmpty ?? true {
                    ContentUnavailableView.search(text: text)
                } else if results == nil, isSearching {
                    ProgressView()
                }
            }
            .navigationTitle("Szukaj")
            .searchable(text: $text, prompt: "Książki, autorzy, podcasty")
            .autocorrectionDisabled()
            // Nowe litery anulują poprzednie zapytania do wszystkich bibliotek.
            .task(id: text) { await search(text, debounce: true) }
            .browseDestinations(model: model, session: session)
        }
    }

    private func search(_ query: String, debounce: Bool) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let combined = session.library.combined else {
            results = nil
            podcastResults = nil
            error = nil
            return
        }
        if debounce {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
        }
        isSearching = true
        defer { isSearching = false }
        async let podcasts = try? combined.searchPodcasts(query)
        do {
            results = try await combined.search(query)
            podcastResults = await podcasts
            error = nil
        } catch is CancellationError {
        } catch {
            results = nil
            podcastResults = nil
            self.error = LibraryStore.message(error)
        }
    }
}

/// Wiersz książki na liście (wyniki wyszukiwania).
struct BookRow: View {
    let book: Client.LibraryItem
    let session: ServerSession

    var body: some View {
        let combined = session.library.combined
        let library = combined?.hasSeveralLibraries == true ? combined?.libraryName(book.libraryId) : nil
        HStack(spacing: 12) {
            ItemCover(itemID: book.id, session: session, points: 60)
                .frame(width: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).lineLimit(2)
                if let author = book.author, !author.isEmpty {
                    Text(author).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                if let library { LibraryBadge(name: library) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BookAccessibility.label(item: book, libraryName: library))
    }
}
