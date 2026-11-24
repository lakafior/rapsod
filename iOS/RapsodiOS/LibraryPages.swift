// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AudiobookshelfKit
import AudiobookshelfPlayback

/// Pełna lista półki Startu („Zobacz wszystko”).
struct ShelfPage: View {
    let shelf: HomeShelf
    let model: AppModel
    let session: ServerSession
    @State private var episodes: [Client.PodcastEpisode] = []
    @State private var playError: String?
    @ScaledMetric(relativeTo: .body) private var authorWidth: CGFloat = 110

    private var feed: HomeFeed { session.home }

    var body: some View {
        ScrollView {
            Group {
                switch shelf {
                case .continueListening:
                    let result = feed.continueListening(session: session, limit: 100)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                        ForEach(result.entries) { entry in
                            ContinueCard(entry: entry, model: model, session: session) { playError = $0 }
                        }
                    }
                case .continueBooks:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                        ForEach(feed.continueBooks(session: session, limit: 100).entries) { entry in
                            ContinueCard(entry: entry, model: model, session: session) { playError = $0 }
                        }
                    }
                case .newEpisodes:
                    LazyVStack(spacing: 0) {
                        ForEach(episodes.isEmpty ? feed.recentEpisodes : episodes) { episode in
                            if let itemID = episode.libraryItemId {
                                EpisodeListRow(itemID: itemID, episode: episode, podcastTitle: episode.podcast?.metadata?.title, model: model, session: session)
                                Divider().padding(.leading, 68)
                            }
                        }
                    }
                case .recentSeries:
                    LazyVGrid(columns: coverColumns(minimum: 130), spacing: 20) {
                        ForEach(feed.shelves?.recentSeries ?? []) { SeriesCard(series: $0, session: session) }
                    }
                case .newestAuthors:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: min(authorWidth, 160)), spacing: 16)], spacing: 20) {
                        ForEach(feed.shelves?.newestAuthors ?? []) { AuthorCard(author: $0, session: session) }
                    }
                default:
                    BookGrid(books: books, session: session)
                }
            }
            .padding(.horizontal, Design.margin)
            .padding(.vertical)
        }
        .navigationTitle(shelf.title)
        .task {
            guard shelf == .newEpisodes, let combined = session.library.combined else { return }
            episodes = (try? await combined.recentEpisodes(limit: 50))?.value ?? []
        }
        .alert("Nie udało się odtworzyć", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playError ?? "")
        }
    }

    private var books: [Client.LibraryItem] {
        guard let shelves = feed.shelves else { return [] }
        return switch shelf {
        case .continueSeries: shelves.continueSeries
        case .recentlyAdded: shelves.recentlyAdded
        case .discover: shelves.discover
        case .listenAgain: shelves.listenAgain
        default: []
        }
    }
}

// MARK: - Lektorzy

/// Lektorzy ze wszystkich bibliotek książek, połączeni po nazwie, z liczbą książek.
struct NarratorsPage: View {
    let session: ServerSession
    @State private var narrators: [(name: String, count: Int)]?
    @State private var error: String?
    @State private var query = ""

    var body: some View {
        List {
            ForEach(filtered, id: \.name) { narrator in
                NavigationLink(value: Route.narrator(narrator.name)) {
                    HStack(spacing: 12) {
                        Text(AuthorCard.initials(narrator.name))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                            .background(.quaternary, in: .circle)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(narrator.name)
                            Text(PolishCount.books(narrator.count)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .overlay {
            if let error, narrators == nil {
                LoadFailureView(message: error) { Task { await load() } }
            } else if narrators == nil {
                ProgressView()
            } else if narrators?.isEmpty == true {
                EmptyState(title: "Brak lektorów", systemImage: "waveform", message: "Żadna książka nie ma wpisanego lektora.")
            }
        }
        .searchable(text: $query, prompt: "Szukaj lektora")
        .navigationTitle("Lektorzy")
        .task { await load() }
        .refreshable { await load() }
    }

    private var filtered: [(name: String, count: Int)] {
        let all = narrators ?? []
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedStandardContains(query) }
    }

    private func load() async {
        guard let combined = session.library.combined else { return }
        var counts: [String: (name: String, count: Int)] = [:]
        var failed: String?
        for library in combined.libraries {
            do {
                let list = try await session.auth.perform { try await $0.narrators(libraryID: library.id, token: $1) }
                for narrator in list {
                    let key = ServerCollation.key(narrator.name)
                    counts[key, default: (narrator.name, 0)].count += narrator.numBooks ?? 0
                }
            } catch is CancellationError {
                return
            } catch {
                failed = LibraryStore.message(error)
            }
        }
        narrators = counts.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        error = counts.isEmpty ? failed : nil
        if counts.isEmpty, failed != nil { narrators = nil }
    }
}

// MARK: - Kolekcje

/// Kolekcje ze wszystkich bibliotek książek.
struct CollectionsPage: View {
    let session: ServerSession
    @State private var collections: [Tagged<Client.Collection>]?
    @State private var error: String?

    var body: some View {
        List {
            ForEach(collections ?? [], id: \.value.id) { tagged in
                let collection = tagged.value
                NavigationLink(value: Route.collection(libraryID: tagged.libraryID, id: collection.id, name: collection.name)) {
                    HStack(spacing: 12) {
                        if let first = collection.books.elements.first {
                            ItemCover(itemID: first.id, session: session, points: 60).frame(width: 52)
                        } else {
                            CoverPlaceholder().frame(width: 52, height: 52).coverStyle(shadow: false)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(collection.name)
                            Text(PolishCount.books(collection.books.elements.count)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .overlay {
            if let error, collections == nil {
                LoadFailureView(message: error) { Task { await load() } }
            } else if collections == nil {
                ProgressView()
            } else if collections?.isEmpty == true {
                EmptyState(title: "Brak kolekcji", systemImage: "rectangle.stack", message: "Kolekcje tworzy się w audiobookshelf na Macu.")
            }
        }
        .navigationTitle("Kolekcje")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let combined = session.library.combined else { return }
        do {
            collections = try await Self.all(combined: combined, session: session)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = LibraryStore.message(error)
        }
    }

    static func all(combined: CombinedLibraries, session: ServerSession) async throws -> [Tagged<Client.Collection>] {
        var result: [Tagged<Client.Collection>] = []
        for library in combined.libraries {
            let list = try await session.auth.perform { try await $0.collections(libraryID: library.id, token: $1) }
            result += list.map { Tagged(libraryID: library.id, value: $0) }
        }
        return result.sorted { $0.value.name.localizedStandardCompare($1.value.name) == .orderedAscending }
    }
}

/// Książki jednej kolekcji.
struct CollectionPage: View {
    let libraryID: String
    let id: String
    let name: String
    let session: ServerSession
    @State private var collection: Client.Collection?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let description = collection?.description, !description.isEmpty {
                    ExpandableText(text: description, lineLimit: 3)
                }
                BookGrid(books: collection?.books.elements ?? [], session: session)
            }
            .padding(Design.margin)
        }
        .overlay {
            if let error, collection == nil {
                LoadFailureView(message: error) { Task { await load() } }
            } else if collection == nil {
                ProgressView()
            }
        }
        .navigationTitle(name)
        .task { await load() }
    }

    private func load() async {
        do {
            let list = try await session.auth.perform { try await $0.collections(libraryID: libraryID, token: $1) }
            collection = list.first { $0.id == id }
            error = collection == nil ? "Kolekcji nie ma już na serwerze." : nil
        } catch is CancellationError {
        } catch {
            self.error = LibraryStore.message(error)
        }
    }
}

// MARK: - Playlisty

/// Playlisty tego konta ze wszystkich bibliotek (książki i odcinki).
struct PlaylistsPage: View {
    let session: ServerSession
    @State private var playlists: [Client.Playlist]?
    @State private var error: String?

    var body: some View {
        List {
            ForEach(playlists ?? []) { playlist in
                NavigationLink(value: Route.playlist(libraryID: playlist.libraryId, id: playlist.id, name: playlist.name)) {
                    HStack(spacing: 12) {
                        if let first = playlist.items.elements.first {
                            ItemCover(itemID: first.libraryItemId, session: session, points: 60).frame(width: 52)
                        } else {
                            CoverPlaceholder().frame(width: 52, height: 52).coverStyle(shadow: false)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name)
                            Text(PolishCount.positions(playlist.items.elements.count)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .overlay {
            if let error, playlists == nil {
                LoadFailureView(message: error) { Task { await load() } }
            } else if playlists == nil {
                ProgressView()
            } else if playlists?.isEmpty == true {
                EmptyState(title: "Brak playlist", systemImage: "music.note.list", message: "Playlisty tworzy się w audiobookshelf na Macu albo w przeglądarce.")
            }
        }
        .navigationTitle("Playlisty")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let combined = session.library.combined else { return }
        do {
            var all: [Client.Playlist] = []
            for library in combined.libraries + combined.podcastLibraries {
                all += try await session.auth.perform { try await $0.playlists(libraryID: library.id, token: $1) }
            }
            playlists = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = LibraryStore.message(error)
        }
    }
}

/// Pozycje jednej playlisty: książki otwierają stronę, odcinki grają.
struct PlaylistPage: View {
    let libraryID: String
    let id: String
    let name: String
    let model: AppModel
    let session: ServerSession
    @State private var playlist: Client.Playlist?
    @State private var error: String?

    var body: some View {
        List {
            ForEach(Array((playlist?.items.elements ?? []).enumerated()), id: \.offset) { _, item in
                if let episode = item.episode {
                    EpisodeListRow(itemID: item.libraryItemId, episode: episode, podcastTitle: item.libraryItem?.title, model: model, session: session)
                } else if let book = item.libraryItem {
                    NavigationLink(value: Route.item(book.id)) { BookRow(book: book, session: session) }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if let error, playlist == nil {
                LoadFailureView(message: error) { Task { await load() } }
            } else if playlist == nil {
                ProgressView()
            } else if playlist?.items.elements.isEmpty == true {
                EmptyState(title: "Pusta playlista", systemImage: "music.note.list")
            }
        }
        .navigationTitle(name)
        .task { await load() }
    }

    private func load() async {
        do {
            let list = try await session.auth.perform { try await $0.playlists(libraryID: libraryID, token: $1) }
            playlist = list.first { $0.id == id }
            error = playlist == nil ? "Playlisty nie ma już na serwerze." : nil
        } catch is CancellationError {
        } catch {
            self.error = LibraryStore.message(error)
        }
    }
}
