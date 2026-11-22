// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AudiobookshelfKit
import AudiobookshelfPlayback

/// Zakładka „Start”: półki ze wszystkich bibliotek książek naraz — „Słuchaj dalej”,
/// „Kolejne w serii”, „Ostatnio dodane”, „Odkrywaj” — i nowe odcinki ze wszystkich bibliotek podcastów.
struct HomeView: View {
    let model: AppModel
    let session: ServerSession

    @State private var shelves: CombinedLibraries.Shelves?
    @State private var recentEpisodes: [Client.PodcastEpisode] = []
    /// Zaczęte odcinki podcastów z serwera; te słuchane ze strumienia półka bierze z telefonu.
    @State private var episodesInProgress: [Client.LibraryItem] = []
    @State private var error: String?
    @State private var playError: String?

    var body: some View {
        NavigationStack {
            Group {
                switch session.library.state {
                case .loading:
                    ProgressView()
                case .failed(let message):
                    LoadFailureView(message: message) { Task { await session.library.load() } }
                case .ready(let combined):
                    content(combined)
                }
            }
            .navigationTitle("Start")
            .browseDestinations(model: model, session: session)
        }
    }

    private func content(_ combined: CombinedLibraries) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if model.isOffline {
                    Label("Brak połączenia z serwerem. Telefon spróbuje ponownie po zmianie sieci.", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                if let shelves {
                    FailureNotice(failures: shelves.failures).padding(.horizontal)
                    Shelf(title: "Słuchaj dalej", items: shelves.continueListening, combined: combined, session: session)
                    ContinueEpisodes(title: "Słuchaj dalej: podcasty", serverItems: episodesInProgress, model: model, session: session) { playError = $0 }
                    if !recentEpisodes.isEmpty {
                        EpisodeShelf(title: "Nowe odcinki podcastów", episodes: recentEpisodes, combined: combined, model: model, session: session)
                    }
                    Shelf(title: "Kolejne w serii", items: shelves.continueSeries, combined: combined, session: session)
                    Shelf(title: "Ostatnio dodane", items: shelves.recentlyAdded, combined: combined, session: session)
                    Shelf(title: "Odkrywaj", items: shelves.discover, combined: combined, session: session)
                }
            }
            .padding(.vertical)
        }
        .overlay {
            if let shelves, shelves.isEmpty, recentEpisodes.isEmpty, episodesInProgress.isEmpty, session.library.podcasts.localEpisodes.inProgress.isEmpty {
                ContentUnavailableView("Pusto", systemImage: "books.vertical",
                                       description: Text(combined.libraries.isEmpty ? "Na serwerze nie ma bibliotek książek dostępnych dla tego konta." : "W bibliotekach nie ma jeszcze książek."))
            } else if shelves == nil {
                if let error {
                    LoadFailureView(message: error) { Task { await load(combined) } }
                } else {
                    ProgressView()
                }
            }
        }
        .alert("Nie udało się odtworzyć", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text((playError ?? "") + " Na stronie podcastu możesz zlecić pobranie na serwer.")
        }
        .refreshable {
            await model.reconnect()
            await session.library.refreshProgress()
            await load(combined)
        }
        // Po zdarzeniach serwera (nowe pozycje, wczytany od nowa postęp) i po włączeniu innej książki.
        // Nie po każdej synchronizacji postępu (co 15 s) — paski postępu odświeżają się same.
        .task(id: Trigger(items: session.library.itemsRevision, progress: session.library.progressRevision, playing: model.playback.nowPlayingKey)) {
            await load(combined)
        }
    }

    private struct Trigger: Hashable {
        let items: Int
        let progress: Int
        let playing: String?
    }

    private func load(_ combined: CombinedLibraries) async {
        async let episodes = try? combined.recentEpisodes(limit: 5)
        async let progress: [Client.LibraryItem]? = try? session.auth.perform { try await $0.itemsInProgress(token: $1) }
        do {
            shelves = try await combined.shelves(lastUpdate: session.library.progress.lastUpdate)
            recentEpisodes = await episodes?.value ?? []
            if let items = await progress {
                episodesInProgress = items.filter { $0.isPodcast && $0.recentEpisode != nil }
            }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = LibraryStore.message(error)
            if AddressSelection.isConnectionError(error) { model.connectionTroubled() }
        }
    }
}

/// Pozioma półka okładek.
private struct Shelf: View {
    let title: String
    let items: [Client.LibraryItem]
    let combined: CombinedLibraries
    let session: ServerSession
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 120

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.title3.bold())
                    .padding(.horizontal)
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items) { item in
                            BookCard(item: item, session: session, libraryName: combined.hasSeveralLibraries ? combined.libraryName(item.libraryId) : nil)
                                .frame(width: cardWidth)
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}
