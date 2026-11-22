// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AudiobookshelfKit

/// Po sparowaniu: serwer, konto, biblioteki i kilka ostatnio dodanych pozycji z okładkami.
/// Na razie dowód, że pakiet działa na iOS; pełne zakładki i odtwarzacz to kolejne etapy.
struct HomeView: View {
    let model: AppModel
    let session: ServerSession

    @State private var libraries: [AudiobookshelfClient.Library] = []
    @State private var items: [String: [AudiobookshelfClient.LibraryItem]] = [:]
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var confirmsDisconnect = false

    var body: some View {
        NavigationStack {
            List {
                Section("Serwer") {
                    LabeledContent("Nazwa", value: session.server.serverName)
                    LabeledContent("Konto", value: session.server.username)
                    LabeledContent("Adres", value: session.baseURL.absoluteString)
                    if let device = session.server.deviceName {
                        LabeledContent("Ten telefon", value: device)
                    }
                }

                if let loadError {
                    Section {
                        Text(loadError).foregroundStyle(.red)
                    }
                } else if isLoading {
                    Section { ProgressView() }
                } else if libraries.isEmpty {
                    Section { Text("Na serwerze nie ma jeszcze bibliotek dostępnych dla tego konta.") }
                }

                ForEach(libraries) { library in
                    Section(library.name) {
                        let entries = items[library.id] ?? []
                        if entries.isEmpty {
                            Text(library.mediaType == "podcast" ? "Brak podcastów" : "Brak pozycji")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(entries) { item in
                            ItemRow(item: item, session: session)
                        }
                    }
                }

                Section {
                    Button("Rozłącz", role: .destructive) { confirmsDisconnect = true }
                } footer: {
                    Text("Rozłączenie usuwa klucz tylko z tego telefonu. Żeby unieważnić go na serwerze, usuń telefon z listy sparowanych na Macu.")
                }
            }
            .navigationTitle(session.server.serverName)
            .refreshable {
                await model.reconnect()
                await load()
            }
            .task(id: session.id) { await load() }
            .confirmationDialog("Rozłączyć ten telefon?", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
                Button("Rozłącz", role: .destructive) { model.disconnect() }
            } message: {
                Text("Klucz dostępu zostanie usunięty z telefonu.")
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let libraries = try await session.auth.perform { try await $0.libraries(token: $1) }
            var items: [String: [AudiobookshelfClient.LibraryItem]] = [:]
            for library in libraries {
                let page = try await session.auth.perform {
                    try await $0.itemsPage(libraryID: library.id, page: 0, limit: 6, sort: "addedAt", descending: true, filter: nil, token: $1)
                }
                items[library.id] = page.results.elements
            }
            self.libraries = libraries
            self.items = items
            loadError = nil
        } catch AudiobookshelfClient.APIError.unauthorized {
            loadError = Connector.ConnectError.keyRejected.localizedDescription
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct ItemRow: View {
    let item: AudiobookshelfClient.LibraryItem
    let session: ServerSession
    @Environment(\.displayScale) private var displayScale
    @State private var cover: UIImage?

    private static let size: CGFloat = 56

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let cover {
                    Image(uiImage: cover).resizable().scaledToFill()
                } else {
                    Image(systemName: item.isPodcast ? "dot.radiowaves.left.and.right" : "book.closed")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.size, height: Self.size)
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: 6))
            .accessibilityHidden(true)

            VStack(alignment: .leading) {
                Text(item.title).lineLimit(2)
                if let author = item.author {
                    Text(author).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .task(id: item.id) {
            cover = await session.cover(itemID: item.id, path: nil, size: Self.size, scale: displayScale)
        }
    }
}
