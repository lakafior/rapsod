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
                        Text(session.baseURL.absoluteString).textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Rodzaj", value: kindTitle)
                    if model.isOffline {
                        Label("Brak połączenia", systemImage: "wifi.slash").foregroundStyle(.secondary)
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
                    Text("Gdy na Macu włączysz dostęp spoza domu albo zmienią się jego adresy: Ustawienia aplikacji → Udostępnianie → „Kod z adresami…”, a tu zeskanuj kod. Telefon nie musi być parowany od nowa.")
                }

                Section {
                    Button("Rozłącz", role: .destructive) { confirmsDisconnect = true }
                } footer: {
                    Text("Rozłączenie usuwa klucz tylko z tego telefonu. Żeby unieważnić go na serwerze, usuń telefon z listy sparowanych na Macu.")
                }
            }
            .navigationTitle("Ustawienia")
            .confirmationDialog("Rozłączyć ten telefon?", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
                Button("Rozłącz", role: .destructive) { model.disconnect() }
            } message: {
                Text("Klucz dostępu zostanie usunięty z telefonu.")
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
