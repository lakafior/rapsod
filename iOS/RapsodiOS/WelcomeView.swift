// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Pierwsze uruchomienie: skaner kodu z Maca, a jako droga zapasowa — ręczne wpisanie.
struct WelcomeView: View {
    let model: AppModel
    @State private var showsScanner = false
    @State private var showsManualEntry = false
    @State private var scanned: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Rapsod")
                    .font(.largeTitle.bold())
                Text("Na Macu otwórz ustawienia Rapsod → Użytkownicy → swój profil → „Podłącz telefon…”, a potem zeskanuj pokazany kod.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(spacing: 12) {
                    Button {
                        showsScanner = true
                    } label: {
                        Label("Zeskanuj kod z Maca", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Wpisz adres i klucz ręcznie") { showsManualEntry = true }
                }
                Text("Kod możesz też zeskanować systemowym aparatem — otworzy tę aplikację.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            // Kod obsługujemy dopiero po zamknięciu arkusza: alert pokazany w trakcie
            // zamykania mógłby przepaść.
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
            .sheet(isPresented: $showsManualEntry) {
                ManualEntryView(model: model)
            }
        }
    }
}

/// Ręczne połączenie: adres serwera i klucz API (np. utworzony na Macu w ustawieniach „Dostęp zdalny” → Zaawansowane → Klucze API).
struct ManualEntryView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var key = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Adres serwera", text: $address, prompt: Text("http://mac-mini.local:13378"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Klucz API", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Adres Maca w sieci domowej znajdziesz na Macu w ustawieniach aplikacji Rapsod → Dostęp zdalny. Poza siecią domową potrzebny jest adres https. Klucz API swojego konta (nie konta root) utworzysz na Macu: Dostęp zdalny → Zaawansowane → Klucze API — prościej jednak podłączyć telefon kodem w swoim profilu.")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                }
            }
            .navigationTitle("Połącz ręcznie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isConnecting {
                        ProgressView()
                    } else {
                        Button("Połącz") { connect() }
                            .disabled(address.isEmpty || key.isEmpty)
                    }
                }
            }
        }
    }

    /// Formularz zostaje otwarty do końca próby, żeby błąd był widoczny przy polach.
    private func connect() {
        isConnecting = true
        error = nil
        Task {
            let failure = await model.pairManually(address: address, key: key)
            isConnecting = false
            if let failure {
                error = failure
            } else {
                dismiss()
            }
        }
    }
}
