// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AudiobookshelfKit
import AudiobookshelfPlayback

/// Po sparowaniu: „Słuchaj dalej”, biblioteki z kilkoma ostatnio dodanymi pozycjami i serwer.
/// Pozycja otwiera prostą stronę z „Odtwarzaj”; pełne przeglądanie to następny etap.
struct HomeView: View {
    let model: AppModel
    let session: ServerSession

    @State private var libraries: [AudiobookshelfClient.Library] = []
    @State private var items: [String: [AudiobookshelfClient.LibraryItem]] = [:]
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var confirmsDisconnect = false
    @State private var inProgress: [AudiobookshelfClient.LibraryItem] = []
    @State private var showsPlayer = false
    @State private var showsScanner = false
    @State private var scanned: String?

    var body: some View {
        NavigationStack {
            List {
                if model.isOffline {
                    Section {
                        Label("Brak połączenia z serwerem. Telefon spróbuje ponownie po zmianie sieci.", systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                    }
                }

                if !inProgress.isEmpty {
                    Section("Słuchaj dalej") {
                        ForEach(inProgress) { item in
                            NavigationLink(value: item.id) {
                                ItemRow(item: item, session: session)
                            }
                        }
                    }
                }

                Section("Serwer") {
                    LabeledContent("Nazwa", value: session.server.serverName)
                    LabeledContent("Konto", value: session.server.username)
                    LabeledContent("Adres", value: model.isOffline ? "brak połączenia" : session.baseURL.absoluteString)
                    DisclosureGroup("Diagnostyka połączenia") {
                        ForEach(session.server.addresses, id: \.url) { address in
                            let attempt = model.connectionAttempts.first { $0.url == address.url }
                            VStack(alignment: .leading, spacing: 2) {
                                Label(address.url.absoluteString, systemImage: attempt?.succeeded == true ? "checkmark.circle.fill" : (attempt == nil ? "circle" : "xmark.circle"))
                                    .font(.callout)
                                Text(attempt?.detail ?? "nie próbowano (wcześniejszy adres odpowiedział albo próba została przerwana)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        if let date = model.connectionAttemptDate {
                            Text("Ostatnia próba: \(date.formatted(date: .omitted, time: .standard))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Połącz ponownie") { Task { await model.reconnect() } }
                    }
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
                            NavigationLink(value: item.id) {
                                ItemRow(item: item, session: session)
                            }
                        }
                    }
                }

                Section {
                    Button("Zeskanuj kod z adresami", systemImage: "qrcode.viewfinder") { showsScanner = true }
                } footer: {
                    Text("Gdy na Macu włączysz dostęp spoza domu albo zmienią się jego adresy: Ustawienia aplikacji → Udostępnianie → „Kod z adresami…”. Telefon nie musi być parowany od nowa.")
                }

                Section {
                    Button("Rozłącz", role: .destructive) { confirmsDisconnect = true }
                } footer: {
                    Text("Rozłączenie usuwa klucz tylko z tego telefonu. Żeby unieważnić go na serwerze, usuń telefon z listy sparowanych na Macu.")
                }
            }
            .navigationTitle(session.server.serverName)
            .navigationDestination(for: String.self) { itemID in
                ItemDetailView(itemID: itemID, model: model, session: session)
            }
            .task(id: model.playback.progressRevision) { await loadInProgress() }
            .refreshable {
                await model.reconnect()
                await load()
            }
            .task(id: session.id) {
                await load()
                await loadInProgress()
            }
            .confirmationDialog("Rozłączyć ten telefon?", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
                Button("Rozłącz", role: .destructive) { model.disconnect() }
            } message: {
                Text("Klucz dostępu zostanie usunięty z telefonu.")
            }
        }
        // Na stosie nawigacji, nie na liście: pasek zostaje też na stronie pozycji.
        .safeAreaInset(edge: .bottom) {
            MiniPlayerBar(model: model, showsPlayer: $showsPlayer)
        }
        .sheet(isPresented: $showsPlayer) {
            PlayerScreen(model: model)
        }
        // Kod obsługujemy po zamknięciu arkusza (alert w trakcie zamykania mógłby przepaść).
        .sheet(isPresented: $showsScanner, onDismiss: {
            if let scanned {
                self.scanned = nil
                model.handle(scanned: scanned)
            }
        }) {
            ScannerSheet { text in
                scanned = text
                showsScanner = false
            }
        }
    }

    /// „Słuchaj dalej” ze wszystkich bibliotek (bez podcastów — odcinki pokazuje strona podcastu).
    private func loadInProgress() async {
        guard let items = try? await session.auth.perform({ try await $0.itemsInProgress(token: $1) }) else { return }
        inProgress = items.filter { !$0.isPodcast }.prefix(10).map(\.self)
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
            if AddressSelection.isConnectionError(error) { model.connectionTroubled() }
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
