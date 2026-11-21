import AppKit
import SwiftUI

/// Dostęp: klucze API (`client/pages/config/api-keys`) i sposób logowania
/// (`client/pages/config/authentication.vue`), przełączane u góry strony.
struct AccessSettingsPage: View {
    enum Tab: String, CaseIterable, Identifiable {
        case apiKeys = "Klucze API"
        case login = "Logowanie"
        var id: Self { self }
    }

    let models: AppModels
    @State private var tab: Tab = .apiKeys

    var body: some View {
        VStack(spacing: 0) {
            Picker("Widok", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 12)
            switch tab {
            case .apiKeys:
                AdminPage(account: models.account, title: "Klucze API", make: { ApiKeysModel(account: models.account) }, load: { await $0.load() }) { model in
                    ApiKeysContent(model: model, account: models.account)
                }
            case .login:
                AdminPage(account: models.account, title: "Logowanie", make: { AuthSettingsModel(account: models.account) }, load: { await $0.load() }) { model in
                    AuthContent(model: model)
                }
            }
        }
    }
}

// MARK: - Klucze API

private struct ApiKeysContent: View {
    let model: ApiKeysModel
    let account: ServerAccount
    @State private var creating = false
    @State private var keyToDelete: AudiobookshelfClient.ApiKey?

    var body: some View {
        Section {
            AdminStatusRows(status: model.status)
            if model.keys.isEmpty, model.isLoaded {
                Text("Nie ma żadnego klucza API.").foregroundStyle(.secondary)
            }
            ForEach(model.keys) { key in
                ApiKeyRow(key: key, model: model, delete: { keyToDelete = key })
            }
            HStack {
                Spacer()
                Button("Nowy klucz…") { creating = true }
                    .disabled(model.status.isBusy || !model.isLoaded)
            }
        } header: {
            Text("Klucze API")
        } footer: {
            Text("Klucz API to stałe hasło dla skryptów i innych programów: działa jak zalogowanie na wybrane konto, z jego uprawnieniami, i nie wygasa, chyba że ustawisz termin. Wysyła się go w nagłówku „Authorization: Bearer <klucz>”. Wyłączony albo usunięty klucz przestaje działać od razu.")
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $creating) {
            NewApiKeySheet(model: model)
        }
        .sheet(isPresented: Binding(get: { model.createdSecret != nil }, set: { if !$0 { model.createdSecret = nil } })) {
            if let created = model.createdSecret {
                ApiKeySecretSheet(name: created.name, secret: created.secret) { model.createdSecret = nil }
            }
        }
        .confirmationDialog("Usunąć klucz „\(keyToDelete?.name ?? "")”?", isPresented: Binding(get: { keyToDelete != nil }, set: { if !$0 { keyToDelete = nil } }), presenting: keyToDelete) { key in
            Button("Usuń", role: .destructive) { Task { await model.delete(key) } }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in
            Text("Programy, które go używają, stracą dostęp do serwera.")
        }
    }
}

private struct ApiKeyRow: View {
    let key: AudiobookshelfClient.ApiKey
    let model: ApiKeysModel
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(key.name).font(.body.weight(.medium))
                    if key.isExpired {
                        Text("wygasł").font(.caption).foregroundStyle(.red)
                    } else if !key.isActive {
                        Text("wyłączony").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Aktywny", isOn: Binding(get: { key.isActive }, set: { value in Task { await model.setActive(key, value) } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(model.status.isBusy)
                .help(key.isActive ? "Wyłącz klucz" : "Włącz klucz")
            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(model.status.isBusy)
            .help("Usuń klucz")
        }
    }

    private var details: String {
        var parts = ["konto: \(key.user?.username ?? "—")"]
        if key.user?.type == "root" { parts[0] += " (root)" }
        if let expires = key.expiresAt {
            parts.append((key.isExpired ? "wygasł " : "wygasa ") + Formats.dateTime(expires))
        } else {
            parts.append("bez wygasania")
        }
        if let used = key.lastUsedAt { parts.append("ostatnio użyty: " + Formats.dateTime(used)) }
        if let created = key.createdAt { parts.append("utworzony " + Formats.dateTime(created)) }
        return parts.joined(separator: " · ")
    }
}

private struct NewApiKeySheet: View {
    let model: ApiKeysModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var userID = ""
    @State private var expires = Expiry.never
    @State private var customDays = 30
    @State private var isActive = true

    enum Expiry: Hashable {
        case never, days30, days90, year, custom
        var label: String {
            switch self {
            case .never: "Nigdy"
            case .days30: "Za 30 dni"
            case .days90: "Za 90 dni"
            case .year: "Za rok"
            case .custom: "Za podaną liczbę dni"
            }
        }
    }

    private var selectedUser: AudiobookshelfClient.ManagedUser? { model.users.first { $0.id == userID } }

    private var expiresIn: Int? {
        let day = 86_400
        switch expires {
        case .never: return nil
        case .days30: return 30 * day
        case .days90: return 90 * day
        case .year: return 365 * day
        case .custom: return max(1, customDays) * day
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Nazwa", text: $name, prompt: Text("np. Skrypt kopii"))
                Picker("Konto", selection: $userID) {
                    ForEach(model.users) { user in
                        Text(user.username + (user.isRoot ? " (root)" : user.type == "admin" ? " (administrator)" : "")).tag(user.id)
                    }
                }
                Picker("Wygasa", selection: $expires) {
                    ForEach([Expiry.never, .days30, .days90, .year, .custom], id: \.self) { Text($0.label).tag($0) }
                }
                if expires == .custom {
                    Stepper("Dni: \(customDays)", value: $customDays, in: 1...3650)
                }
                Toggle("Aktywny od razu", isOn: $isActive)
                if selectedUser?.isRoot == true || selectedUser?.type == "admin" {
                    Label("Klucz dla konta \(selectedUser?.isRoot == true ? "root" : "administratora") daje pełną kontrolę nad serwerem: użytkownikami, plikami i ustawieniami. Lepiej utwórz osobne konto z mniejszymi uprawnieniami.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                AdminStatusRows(status: model.status)
            } header: {
                Text("Nowy klucz API")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Utwórz") {
                    Task {
                        if await model.create(name: name, userID: userID, expiresIn: expiresIn, isActive: isActive) { dismiss() }
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || userID.isEmpty || model.status.isBusy)
            }
        }
        .onAppear {
            // Domyślnie pierwsze konto, które nie jest rootem.
            userID = model.users.first { !$0.isRoot }?.id ?? model.users.first?.id ?? ""
        }
    }
}

/// Klucz pokazywany raz — serwer nie zwróci go ponownie.
private struct ApiKeySecretSheet: View {
    let name: String
    let secret: String
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Klucz „\(name)” utworzony").font(.headline)
            Text("Skopiuj go teraz: serwer pokazuje klucz tylko raz. Jeśli go zgubisz, usuń ten klucz i utwórz nowy.")
                .fixedSize(horizontal: false, vertical: true)
            Text(secret)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(4)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("apikey.secret")
            HStack {
                if copied { Label("Skopiowano", systemImage: "checkmark").foregroundStyle(.green) }
                Spacer()
                Button("Kopiuj") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(secret, forType: .string)
                    copied = true
                }
                Button("Gotowe", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - Logowanie

private struct AuthContent: View {
    let model: AuthSettingsModel
    @State private var draft: AudiobookshelfClient.AuthSettings?
    @State private var redirectURIs = ""

    var body: some View {
        if let draft = Binding($draft) {
            methodsSection(draft)
            if draft.wrappedValue.authActiveAuthMethods.contains("openid") {
                openIDSections(draft)
            }
            Section {
                TextField("Wiadomość na stronie logowania", text: optional(draft.authLoginCustomMessage), prompt: Text("brak"), axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                Text("Strona logowania web UI")
            } footer: {
                Text("Tekst (może zawierać prosty HTML) pokazywany nad formularzem logowania w przeglądarce.").foregroundStyle(.secondary)
            }
            Section {
                AdminStatusRows(status: model.status)
                HStack {
                    Spacer()
                    Button("Przywróć") { reset() }
                        .disabled(!hasChanges || model.status.isBusy)
                    Button("Zapisz") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!hasChanges || model.status.isBusy)
                }
            }
        } else {
            Section("Logowanie") { AdminStatusRows(status: model.status) }
                .onChange(of: model.settings) { reset() }
                .onAppear { if model.settings != nil { reset() } }
        }
    }

    private var hasChanges: Bool {
        guard var draft, let settings = model.settings else { return false }
        draft.authOpenIDMobileRedirectURIs = parsedURIs
        return draft != settings
    }

    private var parsedURIs: [String] {
        redirectURIs.split(whereSeparator: { $0 == "," || $0.isNewline || $0 == " " }).map(String.init)
    }

    private func reset() {
        draft = model.settings
        redirectURIs = (model.settings?.authOpenIDMobileRedirectURIs ?? []).joined(separator: "\n")
    }

    private func save() async {
        guard var draft else { return }
        draft.authOpenIDMobileRedirectURIs = parsedURIs
        await model.save(draft)
        if model.status.error == nil { reset() }
    }

    private func methodsSection(_ draft: Binding<AudiobookshelfClient.AuthSettings>) -> some View {
        Section {
            Toggle(isOn: .constant(true)) {
                Text("Nazwa użytkownika i hasło")
                Text("Zawsze włączone: tym sposobem aplikacja loguje się na konto root (zarządzanie serwerem) i na konto do słuchania. Wyłączenie odcięłoby ją od serwera, więc aplikacja na to nie pozwala.")
            }
            .disabled(true)
            Toggle(isOn: Binding(
                get: { draft.wrappedValue.authActiveAuthMethods.contains("openid") },
                set: { on in
                    var methods = draft.wrappedValue.authActiveAuthMethods.filter { $0 != "openid" }
                    if on { methods.append("openid") }
                    draft.wrappedValue.authActiveAuthMethods = AudiobookshelfClient.AuthSettings.withLocal(methods)
                }
            )) {
                Text("OpenID Connect (SSO)")
                Text("Logowanie przez zewnętrznego dostawcę tożsamości (np. Authentik, Keycloak). Ma sens, gdy serwer jest dostępny pod stałym adresem, np. przez tunel z „Udostępniania”.")
            }
        } header: {
            Text("Sposoby logowania")
        }
    }

    @ViewBuilder
    private func openIDSections(_ draft: Binding<AudiobookshelfClient.AuthSettings>) -> some View {
        Section {
            HStack {
                TextField("Wystawca (Issuer URL)", text: optional(draft.authOpenIDIssuerURL), prompt: Text("https://auth.example.com/application/o/abs/"))
                Button("Uzupełnij adresy") {
                    Task { self.draft = await model.discover(into: draft.wrappedValue) }
                }
                .disabled(model.status.isBusy)
            }
            TextField("Adres autoryzacji", text: optional(draft.authOpenIDAuthorizationURL))
            TextField("Adres tokenu", text: optional(draft.authOpenIDTokenURL))
            TextField("Adres userinfo", text: optional(draft.authOpenIDUserInfoURL))
            TextField("Adres JWKS", text: optional(draft.authOpenIDJwksURL))
            TextField("Adres wylogowania (opcjonalny)", text: optional(draft.authOpenIDLogoutURL))
            TextField("Identyfikator klienta", text: optional(draft.authOpenIDClientID))
            SecureField("Sekret klienta", text: optional(draft.authOpenIDClientSecret))
            if model.signingAlgorithms.isEmpty {
                TextField("Algorytm podpisu tokenu", text: optional(draft.authOpenIDTokenSigningAlgorithm), prompt: Text("RS256"))
            } else {
                Picker("Algorytm podpisu tokenu", selection: optional(draft.authOpenIDTokenSigningAlgorithm)) {
                    ForEach(model.signingAlgorithms, id: \.self) { Text($0).tag($0) }
                }
            }
        } header: {
            Text("Dostawca OpenID")
        } footer: {
            Text("Adresy przekierowania do wpisania u dostawcy: https://<adres serwera>\(draft.wrappedValue.authOpenIDSubfolderForRedirectURLs ?? "")/auth/openid/callback oraz …/auth/openid/mobile-redirect.")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        Section {
            Picker("Podfolder w adresach przekierowania", selection: Binding(
                get: { draft.wrappedValue.authOpenIDSubfolderForRedirectURLs ?? "" },
                set: { draft.wrappedValue.authOpenIDSubfolderForRedirectURLs = $0 }
            )) {
                Text("Brak").tag("")
                Text(ServerEnvironment.routerBasePath).tag(ServerEnvironment.routerBasePath)
            }
            TextField("Przekierowania aplikacji mobilnych", text: $redirectURIs, prompt: Text("audiobookshelf://oauth"), axis: .vertical)
                .lineLimit(1...4)
            TextField("Tekst przycisku", text: optional(draft.authOpenIDButtonText), prompt: Text("Login with OpenId"))
            Picker("Dopasuj istniejące konta", selection: draft.authOpenIDMatchExistingBy) {
                Text("Nie dopasowuj").tag(String?.none)
                Text("Po adresie e-mail").tag(String?.some("email"))
                Text("Po nazwie użytkownika").tag(String?.some("username"))
            }
            Toggle("Od razu przekierowuj do dostawcy (web UI)", isOn: draft.authOpenIDAutoLaunch)
            Toggle("Zakładaj konta nowym użytkownikom", isOn: draft.authOpenIDAutoRegister)
            TextField("Claim z grupą (typ konta)", text: optional(draft.authOpenIDGroupClaim), prompt: Text("np. groups"))
            TextField("Claim z uprawnieniami", text: optional(draft.authOpenIDAdvancedPermsClaim), prompt: Text("np. abspermissions"))
        } header: {
            Text("Zachowanie OpenID")
        } footer: {
            Text("Przekierowania mobilne: adresy, na które serwer może odesłać aplikację na telefonie po zalogowaniu (oddziel przecinkami albo nowymi wierszami; „*” = dowolny). Claim z grupą przypisuje typ konta (admin, user, guest) z grupy u dostawcy.")
                .foregroundStyle(.secondary)
        }
    }

    /// Pole tekstowe dla wartości, której brak serwer zapisuje jako `null`.
    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}
