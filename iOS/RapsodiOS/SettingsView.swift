// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AudiobookshelfKit

/// Zakładka „Ustawienia”: serwer, konto, adres i jego rodzaj, kod z adresami, rozłączenie.
struct SettingsView: View {
    let model: AppModel
    let session: ServerSession

    @State private var confirmsDisconnect = false
    @State private var showsScanner = false
    @State private var scanned: String?
    @AppStorage("orderDownloadWhenStreaming") private var orderWhenStreaming = true
    @AppStorage(DownloadsController.wifiOnlyKey) private var wifiOnly = true
    @AppStorage(DownloadsController.tunnelKey) private var allowsTunnel = false
    @AppStorage(DownloadsController.removeFinishedKey) private var removesFinished = false
    @State private var confirmsRemoveAll = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Serwer") {
                    LabeledContent("Nazwa", value: session.server.serverName)
                    LabeledContent("Konto", value: session.server.username)
                    if let device = session.server.deviceName {
                        LabeledContent("Ten telefon", value: device)
                    }
                }

                Section {
                    LabeledContent("Adres") {
                        Text(model.isOffline ? "brak połączenia" : session.baseURL.absoluteString)
                            .textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                    if !model.isOffline {
                        LabeledContent("Rodzaj", value: kindTitle)
                    }
                    // Wynik ostatniej próby dla każdego zapisanego adresu (z `main`, diagnostyka połączenia).
                    DisclosureGroup("Diagnostyka połączenia") {
                        ForEach(session.server.addresses, id: \.url) { address in
                            let attempt = model.connectionAttempts.first { $0.url == address.url }
                            VStack(alignment: .leading, spacing: 2) {
                                Label(address.url.absoluteString, systemImage: attempt?.succeeded == true ? "checkmark.circle.fill" : (attempt == nil ? "circle" : "xmark.circle"))
                                    .font(.callout)
                                Text(attempt?.detail ?? "nie próbowano (bez Wi-Fi adresy lokalne są pomijane)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        if let date = model.connectionAttemptDate {
                            Text("Ostatnia próba: \(date.formatted(date: .omitted, time: .standard))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Połącz ponownie", systemImage: "arrow.clockwise") {
                        Task { await model.reconnect() }
                    }
                    .disabled(model.isConnecting)
                } header: {
                    Text("Połączenie")
                } footer: {
                    Text("Telefon zawsze najpierw próbuje adresu w sieci lokalnej, potem dostępu spoza domu.")
                }

                downloadsSection

                if let combined = session.library.combined, !combined.podcastLibraries.isEmpty {
                    Section {
                        LabeledContent("Pobieranie odcinków na serwer", value: podcastPermission)
                        Toggle("Pobieraj na serwer odcinki słuchane ze strumienia", isOn: $orderWhenStreaming)
                            .disabled(!session.library.podcasts.permission.canOrder)
                        // Dodawać podcasty może tylko administrator — słuchaczowi wyszukiwanie się nie przyda.
                        if session.library.podcasts.permission != .listener {
                            NavigationLink("Wyszukiwanie podcastów") { PodcastSearchSettingsView() }
                        }
                    } header: {
                        Text("Podcasty")
                    } footer: {
                        Text(!session.library.podcasts.permission.canOrder
                             ? PodcastStore.permissionHelp(session.library.podcasts.permission)
                             : "Odcinek spoza serwera gra od razu ze strumienia wydawcy, a serwer pobiera go w tle. Postęp przechodzi na serwer, gdy odcinek się pobierze.")
                    }
                }

                if let combined = session.library.combined {
                    Section("Biblioteki") {
                        ForEach(combined.libraries) { library in
                            Label(library.name, systemImage: "books.vertical")
                        }
                        ForEach(combined.podcastLibraries) { library in
                            Label(library.name, systemImage: "dot.radiowaves.left.and.right")
                        }
                    }
                }

                Section {
                    Button("Odśwież adresy", systemImage: "qrcode.viewfinder") { showsScanner = true }
                } footer: {
                    Text("Gdy na Macu włączysz dostęp spoza domu albo zmienią się jego adresy: ustawienia Rapsod → Dostęp zdalny (albo swój profil w „Użytkownikach”) → „Kod z adresami…”, a tu zeskanuj kod. Telefonu nie trzeba podłączać od nowa.")
                }

                Section {
                    Button("Rozłącz", role: .destructive) { confirmsDisconnect = true }
                } footer: {
                    Text("Rozłączenie usuwa klucz tylko z tego telefonu. Żeby cofnąć go na serwerze, odłącz telefon na Macu, w swoim profilu (Użytkownicy).")
                }
            }
            .navigationTitle("Ustawienia")
            .confirmationDialog("Rozłączyć ten telefon?", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
                Button("Rozłącz", role: .destructive) { model.disconnect() }
                if !session.downloads.manager.items(scope: session.scope).isEmpty {
                    Button("Rozłącz i usuń pobrane", role: .destructive) { model.disconnect(removingDownloads: true) }
                }
            } message: {
                Text("Klucz dostępu zostanie usunięty z telefonu. Pobrane pliki zostają, chyba że wybierzesz ich usunięcie — po ponownym podłączeniu do tego serwera będą znowu dostępne.")
            }
            .onChange(of: wifiOnly) { model.updateDownloadGate() }
            .onChange(of: allowsTunnel) { model.updateDownloadGate() }
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
    }

    private var downloadsSection: some View {
        let manager = session.downloads.manager
        let items = manager.items(scope: session.scope)
        let otherServers = manager.usedBytes() - manager.usedBytes(scope: session.scope)
        return Section {
            NavigationLink {
                DownloadsScreen(model: model, session: session)
            } label: {
                LabeledContent("Pobrane i kolejka", value: items.isEmpty ? "brak" : PolishCount.positions(items.count))
            }
            LabeledContent("Zajęte miejsce", value: manager.usedBytes(scope: session.scope).formatted(.byteCount(style: .file)))
            if otherServers > 0 {
                LabeledContent("Z innych serwerów", value: otherServers.formatted(.byteCount(style: .file)))
            }
            if case .closed(let wait) = manager.gate, items.contains(where: { !$0.isComplete }) {
                Label(wait.text, systemImage: "pause.circle").foregroundStyle(.secondary)
            }
            Toggle("Pobieraj tylko przez Wi-Fi", isOn: $wifiOnly)
            Toggle("Pobieraj przez dostęp spoza domu (tunel)", isOn: $allowsTunnel)
            Toggle("Usuwaj pobrane po wysłuchaniu", isOn: $removesFinished)
            if !items.isEmpty || otherServers > 0 {
                Button("Usuń wszystkie pobrane", role: .destructive) { confirmsRemoveAll = true }
                    // Na samym przycisku: dwa okna potwierdzenia na jednym widoku się wykluczają.
                    .confirmationDialog("Usunąć wszystkie pobrane?", isPresented: $confirmsRemoveAll, titleVisibility: .visible) {
                        Button("Usuń wszystkie pobrane", role: .destructive) { session.downloads.manager.removeAll() }
                    } message: {
                        Text("Pliki znikną z telefonu, a trwające pobierania zostaną przerwane. Postęp słuchania zostaje.")
                    }
            }
        } header: {
            Text("Pobieranie na telefon")
        } footer: {
            Text("Pobrane książki i odcinki grają z telefonu, także bez sieci; postęp trafia na serwer, gdy połączenie wróci. Domyślnie pliki pobierają się tylko w sieci domowej: darmowy plan Cloudflare zastrzega ograniczenia dla dużych plików przesyłanych przez tunel, więc pobieranie spoza domu włączaj świadomie.")
        }
    }

    private var podcastPermission: String {
        switch session.library.podcasts.permission {
        case .admin: "Dozwolone"
        case .listener, .needsEditPermission: "Wymaga uprawnień"
        case .unknown: "Sprawdzanie…"
        }
    }

    private var kindTitle: String {
        let kind = session.server.addresses.first { $0.url == session.baseURL }?.kind
        switch kind {
        case .local: return "Sieć lokalna"
        case .remote: return "Spoza domu"
        default: return "Inny"
        }
    }
}
