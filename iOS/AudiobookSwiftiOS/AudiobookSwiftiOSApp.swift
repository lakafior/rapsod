// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

@main
struct AudiobookSwiftiOSApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                // Adres `abswift://pair?d=…` z aparatu systemowego albo z innej aplikacji.
                .onOpenURL { model.handle(url: $0) }
                .task { await model.start() }
        }
    }
}

/// Ekran powitalny (parowanie) albo ekran sparowanego serwera.
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView()
            case .unpaired:
                WelcomeView(model: model)
            case .paired(let session):
                HomeView(model: model, session: session)
            }
        }
        .overlay {
            if model.isConnecting {
                ConnectingOverlay()
            }
        }
        .alert(
            "Zastąpić połączenie?",
            isPresented: Binding(get: { model.pendingReplacement != nil }, set: { if !$0 { model.pendingReplacement = nil } }),
            presenting: model.pendingReplacement
        ) { payload in
            Button("Zastąp", role: .destructive) { model.confirmReplacement(payload) }
            Button("Anuluj", role: .cancel) { model.pendingReplacement = nil }
        } message: { payload in
            Text("Telefon jest już sparowany z „\(model.pairedServerName ?? "")”. Nowy kod łączy go z „\(payload.server.name)” (konto „\(payload.account.username)”). Stary klucz zostanie usunięty z telefonu — unieważnisz go na Macu.")
        }
        .alert(
            "Nie udało się połączyć",
            isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
        ) {
            if model.canRetry {
                Button("Spróbuj ponownie") { model.retry() }
            }
            if model.offersDisconnect {
                Button("Rozłącz", role: .destructive) { model.disconnect() }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.error ?? "")
        }
    }
}

private struct ConnectingOverlay: View {
    var body: some View {
        ProgressView("Łączenie z serwerem…")
            .padding(24)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
    }
}
