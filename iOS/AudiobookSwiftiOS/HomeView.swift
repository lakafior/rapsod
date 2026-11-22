// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AudiobookshelfKit
import AudiobookshelfPlayback

/// Zakładka „Start”: półki ze wszystkich bibliotek książek naraz — „Słuchaj dalej”,
/// „Kolejne w serii”, „Ostatnio dodane”, „Odkrywaj”.
struct HomeView: View {
    let model: AppModel
    let session: ServerSession

    @State private var shelves: CombinedLibraries.Shelves?
    @State private var error: String?

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
                    Shelf(title: "Kolejne w serii", items: shelves.continueSeries, combined: combined, session: session)
                    Shelf(title: "Ostatnio dodane", items: shelves.recentlyAdded, combined: combined, session: session)
                    Shelf(title: "Odkrywaj", items: shelves.discover, combined: combined, session: session)
                }
            }
            .padding(.vertical)
        }
        .overlay {
            if let shelves, shelves.isEmpty {
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
        do {
            shelves = try await combined.shelves(lastUpdate: session.library.progress.lastUpdate)
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
