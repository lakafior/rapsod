import AppKit
import AudiobookshelfKit
import SwiftUI

// Zawartość „Zaawansowane” na stronie „Dostęp zdalny” (etap 3 planu): klucze API
// (`client/pages/config/api-keys`) i logowanie (`client/pages/config/authentication.vue`).
// Dawniej strona „Dostęp” z dwiema kartami.

// MARK: - Klucze API

/// Klucze API wszystkich kont. Klucze telefonów (przedrostek `PhonePairing.keyPrefix`) są
/// oznaczone, prowadzą do profilu osoby, a wyłączenie i usunięcie pytają z ostrzeżeniem.
struct ApiKeysContent: View {
    let model: ApiKeysModel
    let pairing: PhonePairing
    @Environment(SettingsNavigation.self) private var navigation
    @State private var creating = false
    /// Jedno okno potwierdzenia na sekcję: dwa `confirmationDialog` na tym samym widoku
    /// SwiftUI nie pokazuje (drugi milczał).
    @State private var pending: PendingAction?

    private enum PendingAction: Identifiable {
        case delete(AudiobookshelfClient.ApiKey)
        case disablePhone(AudiobookshelfClient.ApiKey)
        var key: AudiobookshelfClient.ApiKey {
            switch self { case .delete(let key), .disablePhone(let key): key }
        }
        var id: String {
            switch self { case .delete(let key): "d" + key.id; case .disablePhone(let key): "w" + key.id }
        }
    }

    var body: some View {
        Section {
            AdminStatusRows(status: model.status)
            if model.keys.isEmpty, model.isLoaded {
                Text("Nie ma żadnego klucza API.").foregroundStyle(.secondary)
            }
            ForEach(model.keys) { key in
                ApiKeyRow(
                    key: key,
                    model: model,
                    toggle: {
                        if Self.isPhone(key), key.isActive {
                            pending = .disablePhone(key)
                        } else {
                            Task { await model.setActive(key, !key.isActive); await pairing.refresh() }
                        }
                    },
                    delete: { pending = .delete(key) },
                    openProfile: { navigation.show(.user(id: $0)) }
                )
            }
            HStack {
                Spacer()
                Button("Nowy klucz…") { creating = true }
                    .disabled(model.status.isBusy || !model.isLoaded)
            }
        } header: {
            Text("Klucze API")
        } footer: {
            Text("Klucz API to stałe hasło dla skryptów i innych programów: działa jak zalogowanie na wybrane konto, z jego uprawnieniami, i nie wygasa, chyba że ustawisz termin. Wysyła się go w nagłówku „Authorization: Bearer <klucz>”. Wyłączony albo usunięty klucz przestaje działać od razu. Klucze telefonów powstają przy „Podłącz telefon…” w profilu osoby.")
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
        .confirmationDialog(dialogTitle, item: $pending) { action in
            switch action {
            case .delete(let key):
                Button(Self.isPhone(key) ? "Odłącz telefon (usuń klucz)" : "Usuń", role: .destructive) {
                    Task { await model.delete(key); await pairing.refresh() }
                }
            case .disablePhone(let key):
                Button("Wyłącz klucz", role: .destructive) {
                    Task { await model.setActive(key, false); await pairing.refresh() }
                }
            }
            Button("Anuluj", role: .cancel) {}
        } message: { action in
            switch action {
            case .delete(let key) where Self.isPhone(key):
                Text("To klucz telefonu „\(Self.phoneName(key))” konta „\(key.user?.username ?? "—")”. Telefon straci dostęp do serwera przy następnym połączeniu; żeby znów go użyć, trzeba go podłączyć ponownie w profilu osoby.")
            case .delete:
                Text("Programy, które go używają, stracą dostęp do serwera.")
            case .disablePhone(let key):
                Text("Telefon konta „\(key.user?.username ?? "—")” przestanie łączyć się z serwerem, dopóki nie włączysz klucza z powrotem.")
            }
        }
    }

    private var dialogTitle: String {
        switch pending {
        case .delete(let key): Self.isPhone(key) ? "Odłączyć telefon „\(Self.phoneName(key))”?" : "Usunąć klucz „\(key.name)”?"
        case .disablePhone(let key): "Wyłączyć klucz telefonu „\(Self.phoneName(key))”?"
        case nil: ""
        }
    }

    static func isPhone(_ key: AudiobookshelfClient.ApiKey) -> Bool {
        key.name.hasPrefix(PhonePairing.keyPrefix)
    }

    static func phoneName(_ key: AudiobookshelfClient.ApiKey) -> String {
        String(key.name.dropFirst(PhonePairing.keyPrefix.count))
    }
}

private struct ApiKeyRow: View {
    let key: AudiobookshelfClient.ApiKey
    let model: ApiKeysModel
    let toggle: () -> Void
    let delete: () -> Void
    let openProfile: (String) -> Void

    private var isPhone: Bool { ApiKeysContent.isPhone(key) }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if isPhone {
                        Image(systemName: "iphone").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                    }
                    Text(isPhone ? ApiKeysContent.phoneName(key) : key.name).font(.body.weight(.medium))
                    if isPhone {
                        Text("telefon").font(.caption).padding(.horizontal, 5).background(.quaternary, in: Capsule())
                    }
                    if key.isExpired {
                        Text("wygasł").font(.caption).foregroundStyle(.red)
                    } else if !key.isActive {
                        Text("wyłączony").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isPhone, let userID = key.userId {
                Button("Profil…") { openProfile(userID) }
                    .help("Telefony tej osoby: lista, odłączanie, podłączanie")
            }
            // Przycisk, nie przełącznik: mały przełącznik w wierszu nie reagował na akcję dostępności (AXPress).
            Button(key.isActive ? "Wyłącz" : "Włącz", action: toggle)
                .disabled(model.status.isBusy)
                .help(key.isActive ? "Wyłącz klucz — przestanie działać od razu" : "Włącz klucz")
            Button(isPhone ? "Odłącz telefon" : "Usuń klucz", systemImage: "trash", role: .destructive, action: delete)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(model.status.isBusy)
                .help(isPhone ? "Odłącz telefon (usuń jego klucz)" : "Usuń klucz")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isPhone ? "Klucz telefonu \(ApiKeysContent.phoneName(key))" : "Klucz \(key.name)")
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
        if let created = key.createdAt { parts.append((isPhone ? "podłączony " : "utworzony ") + Formats.dateTime(created)) }
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
                TextField("Nazwa", text: $name, prompt: Text(verbatim: "np. Skrypt kopii"))
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
                    NSPasteboard.copy(secret)
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

/// Wiersze „Logowanie” pod „Zaawansowane”: stan SSO i wiadomości na stronie logowania oraz
/// przycisk do arkusza ze wszystkimi ustawieniami logowania (D4–D8).
struct LoginSummaryRows: View {
    let model: AuthSettingsModel
    @State private var editing = false

    var body: some View {
        Section {
            if let settings = model.settings {
                LabeledContent("Logowanie przez OpenID (SSO)", value: settings.authActiveAuthMethods.contains("openid") ? "włączone" : "wyłączone")
                LabeledContent("Wiadomość na stronie logowania", value: (settings.authLoginCustomMessage ?? "").isEmpty ? "brak" : "ustawiona")
            }
            AdminStatusRows(status: model.status)
            HStack {
                Spacer()
                Button("Ustawienia logowania…") { editing = true }
                    .disabled(model.settings == nil || model.status.isBusy)
            }
        } header: {
            Text("Logowanie")
        } footer: {
            Text("Logowanie hasłem jest zawsze włączone. OpenID przydaje się, gdy serwer ma stały adres spoza domu.")
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $editing) {
            if let settings = model.settings {
                LoginSettingsSheet(model: model, settings: settings)
            }
        }
    }
}

/// Arkusz ustawień logowania: sposoby logowania, OpenID i wiadomość na stronie logowania.
/// Jeden wzorzec zapisu długiego formularza: „Anuluj” odrzuca zmiany, „Zapisz” zapisuje całość.
private struct LoginSettingsSheet: View {
    let model: AuthSettingsModel
    @State private var draft: AudiobookshelfClient.AuthSettings?
    @State private var redirectURIs: String
    @Environment(\.dismiss) private var dismiss

    init(model: AuthSettingsModel, settings: AudiobookshelfClient.AuthSettings) {
        self.model = model
        _draft = State(initialValue: settings)
        _redirectURIs = State(initialValue: (settings.authOpenIDMobileRedirectURIs ?? []).joined(separator: "\n"))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let draft = Binding($draft) {
                    methodsSection(draft)
                    if draft.wrappedValue.authActiveAuthMethods.contains("openid") {
                        openIDSections(draft)
                    }
                    Section {
                        TextField("Wiadomość na stronie logowania", text: optional(draft.authLoginCustomMessage), prompt: Text(verbatim: "brak"), axis: .vertical)
                            .lineLimit(2...5)
                    } header: {
                        Text("Strona logowania web UI")
                    } footer: {
                        Text("Tekst (może zawierać prosty HTML) pokazywany nad formularzem logowania w przeglądarce.").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                AdminStatusRows(status: model.status)
                Spacer()
                Button("Anuluj", role: .cancel) {
                    model.status.error = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Zapisz") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges || model.status.isBusy)
            }
            .padding()
        }
        .frame(width: 620, height: 640)
    }

    private var hasChanges: Bool {
        guard var draft, let settings = model.settings else { return false }
        draft.authOpenIDMobileRedirectURIs = parsedURIs
        return draft != settings
    }

    private var parsedURIs: [String] {
        redirectURIs.split(whereSeparator: { $0 == "," || $0.isNewline || $0 == " " }).map(String.init)
    }

    private func save() async {
        guard var draft else { return }
        draft.authOpenIDMobileRedirectURIs = parsedURIs
        await model.save(draft)
        if model.status.error == nil { dismiss() }
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
                Text("Logowanie przez zewnętrznego dostawcę tożsamości (np. Authentik, Keycloak). Ma sens, gdy serwer jest dostępny pod stałym adresem, np. przez tunel z „Dostępu zdalnego”.")
            }
        } header: {
            Text("Sposoby logowania")
        }
    }

    @ViewBuilder
    private func openIDSections(_ draft: Binding<AudiobookshelfClient.AuthSettings>) -> some View {
        Section {
            HStack {
                TextField("Wystawca (Issuer URL)", text: optional(draft.authOpenIDIssuerURL), prompt: Text(verbatim: "https://auth.example.com/application/o/abs/"))
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
                TextField("Algorytm podpisu tokenu", text: optional(draft.authOpenIDTokenSigningAlgorithm), prompt: Text(verbatim: "RS256"))
            } else {
                Picker("Algorytm podpisu tokenu", selection: optional(draft.authOpenIDTokenSigningAlgorithm)) {
                    ForEach(model.signingAlgorithms, id: \.self) { Text($0).tag($0) }
                }
            }
        } header: {
            Text("Dostawca OpenID")
        } footer: {
            Text("Adresy przekierowania do wpisania u dostawcy: https://<adres serwera>\(draft.wrappedValue.authOpenIDSubfolderForRedirectURLs ?? ServerEnvironment.routerBasePath)/auth/openid/callback oraz …/auth/openid/mobile-redirect.")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        Section {
            Picker("Podfolder w adresach przekierowania", selection: Binding(
                get: { draft.wrappedValue.authOpenIDSubfolderForRedirectURLs ?? ServerEnvironment.routerBasePath },
                set: { draft.wrappedValue.authOpenIDSubfolderForRedirectURLs = $0 }
            )) {
                Text("Brak").tag("")
                Text(ServerEnvironment.routerBasePath).tag(ServerEnvironment.routerBasePath)
            }
            TextField("Przekierowania aplikacji mobilnych", text: $redirectURIs, prompt: Text(verbatim: "audiobookshelf://oauth"), axis: .vertical)
                .lineLimit(1...4)
            TextField("Tekst przycisku", text: optional(draft.authOpenIDButtonText), prompt: Text(verbatim: "Login with OpenId"))
            Picker("Dopasuj istniejące konta", selection: draft.authOpenIDMatchExistingBy) {
                Text("Nie dopasowuj").tag(String?.none)
                Text("Po adresie e-mail").tag(String?.some("email"))
                Text("Po nazwie użytkownika").tag(String?.some("username"))
            }
            Toggle("Od razu przekierowuj do dostawcy (web UI)", isOn: draft.authOpenIDAutoLaunch)
            Toggle("Zakładaj konta nowym użytkownikom", isOn: draft.authOpenIDAutoRegister)
            TextField("Claim z grupą (typ konta)", text: optional(draft.authOpenIDGroupClaim), prompt: Text(verbatim: "np. groups"))
            TextField("Claim z uprawnieniami", text: optional(draft.authOpenIDAdvancedPermsClaim), prompt: Text(verbatim: "np. abspermissions"))
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

// MARK: - Kanały RSS

struct FeedsContent: View {
    let model: FeedsModel
    @State private var feedToClose: AudiobookshelfClient.Feed?

    var body: some View {
        Section {
            AdminStatusRows(status: model.status)
            if model.feeds.isEmpty, model.isLoaded {
                Text("Żaden kanał nie jest otwarty.").foregroundStyle(.secondary)
            }
            ForEach(model.feeds) { feed in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feed.meta?.title ?? feed.slug ?? feed.id).font(.body.weight(.medium))
                        if let url = feed.url {
                            Text(url.absoluteString).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        }
                        Text(details(feed)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = feed.url {
                        Button("Kopiuj adres kanału", systemImage: "doc.on.doc") {
                            NSPasteboard.copy(url.absoluteString)
                        }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Kopiuj adres kanału")
                    }
                    Button("Zamknij…") { feedToClose = feed }
                        .disabled(model.status.isBusy)
                }
            }
        } header: {
            HStack {
                Text("Publiczne kanały RSS")
                Spacer()
                Button("Odśwież") { Task { await model.load() } }
                    .buttonStyle(.borderless)
                    .disabled(model.status.isBusy)
            }
        } footer: {
            Text("Kanał RSS udostępnia książkę albo podcast jako podcast pod publicznym adresem — bez logowania, dla każdego, kto zna adres. Kanał dla książki otwierasz z menu „Więcej” na jej stronie w oknie „Biblioteka”.")
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Zamknąć kanał „\(feedToClose?.meta?.title ?? "")”?", item: $feedToClose) { feed in
            Button("Zamknij kanał", role: .destructive) { Task { await model.close(feed) } }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in
            Text("Adres kanału przestanie działać we wszystkich aplikacjach do podcastów, które go subskrybują.")
        }
    }

    private func details(_ feed: AudiobookshelfClient.Feed) -> String {
        var parts = [feed.entityText]
        if let created = feed.createdAt { parts.append("otwarty " + Formats.dateTime(Date(timeIntervalSince1970: created / 1000))) }
        if feed.meta?.preventIndexing == false { parts.append("widoczny dla wyszukiwarek") }
        return parts.joined(separator: " · ")
    }
}
