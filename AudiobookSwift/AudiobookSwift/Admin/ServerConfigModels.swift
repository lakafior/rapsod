import AudiobookshelfKit
import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Admin")

/// Wspólny stan operacji podstrony administracyjnej: zajętość, błąd i komunikat po sukcesie.
/// Błędy trafiają do logu systemowego tylko jako opis akcji i komunikat — nigdy z treścią
/// żądania (hasła, sekrety, klucze).
@MainActor
@Observable
final class AdminStatus {
    private(set) var busy: String?
    var error: String?
    var notice: String?

    var isBusy: Bool { busy != nil }

    /// Wykonuje `work`, jeśli nic innego nie trwa. Zwraca, czy się udało.
    @discardableResult
    func run(_ label: String, failure: String, _ work: () async throws -> Void) async -> Bool {
        guard busy == nil else { return false }
        busy = label
        error = nil
        notice = nil
        defer { busy = nil }
        do {
            try await work()
            return true
        } catch {
            logger.error("\(failure, privacy: .public): \(error.localizedDescription, privacy: .public)")
            self.error = ItemManager.message(for: error, action: failure)
            return false
        }
    }
}

/// Język interfejsu serwera (`client/plugins/i18n.js`, `languageCodeMap`).
enum ServerLanguage {
    static let options: [(code: String, label: String)] = [
        ("ar", "عربي"), ("be", "Беларуская"), ("bg", "Български"), ("bn", "বাংলা"), ("ca", "Català"),
        ("cs", "Čeština"), ("da", "Dansk"), ("de", "Deutsch"), ("en-us", "English"), ("es", "Español"),
        ("et", "Eesti"), ("fi", "Suomi"), ("fr", "Français"), ("he", "עברית"), ("hr", "Hrvatski"),
        ("it", "Italiano"), ("ja", "日本語"), ("lt", "Lietuvių"), ("hu", "Magyar"), ("ko", "한국어"),
        ("nl", "Nederlands"), ("no", "Norsk"), ("pl", "Polski"), ("pt-br", "Português (Brasil)"),
        ("ro", "Română"), ("ru", "Русский"), ("sk", "Slovenčina"), ("sl", "Slovenščina"), ("sv", "Svenska"),
        ("tr", "Türkçe"), ("uk", "Українська"), ("vi-vn", "Tiếng Việt"), ("zh-cn", "简体中文"), ("zh-tw", "正體中文"),
    ]
}

// MARK: - Ustawienia serwera

/// Ustawienia serwera (Biblioteki › Zaawansowane i Ogólne › Zaawansowane; wzorzec: `client/pages/config/index.vue`). Każda zmiana idzie
/// od razu na serwer jako `PATCH /api/settings` z samym zmienionym polem, jak w web UI.
@MainActor
@Observable
final class ServerSettingsModel {
    private let account: ServerAccount
    let status = AdminStatus()

    private(set) var settings: AudiobookshelfClient.ServerSettings?
    private(set) var coverProviders: [AudiobookshelfClient.SearchProvider] = []
    /// Obserwator folderów czyta ustawienie tylko przy starcie serwera (`Server.js`).
    private(set) var watcherChangedSinceStart = false

    init(account: ServerAccount) {
        self.account = account
    }

    func load() async {
        await status.run("Wczytywanie…", failure: "Nie udało się wczytać ustawień serwera") {
            settings = try await account.withAdminToken { try await $0.serverSettings(token: $1) }
            if coverProviders.isEmpty {
                // Bez `best`/`all` — skaner używa jednego dostawcy.
                coverProviders = (try? await account.withAdminToken { try await $0.searchProviders(token: $1) })?
                    .booksCovers.filter { !["best", "all"].contains($0.value) } ?? []
            }
        }
    }

    func update(_ change: (inout AudiobookshelfClient.ServerSettings) -> Void) async {
        guard let old = settings else { return }
        var new = old
        change(&new)
        let changes = AudiobookshelfClient.ServerSettingsChanges(from: old, to: new)
        guard !changes.isEmpty else { return }
        settings = new
        let ok = await status.run("Zapisywanie…", failure: "Nie udało się zapisać ustawienia") {
            settings = try await account.withAdminToken { try await $0.updateServerSettings(changes, token: $1) }
        }
        if !ok { settings = old }
        if ok, changes.scannerDisableWatcher != nil { watcherChangedSinceStart.toggle() }
    }

    func saveSortingPrefixes(_ text: String) async {
        let prefixes = text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { $0.lowercased() }
        await status.run("Przeliczanie tytułów…", failure: "Nie udało się zapisać przedrostków") {
            guard !prefixes.isEmpty else { throw ItemManager.ManageError.invalid("Podaj co najmniej jeden przedrostek.") }
            try await account.withAdminToken { try await $0.updateSortingPrefixes(prefixes, token: $1) }
            settings = try await account.withAdminToken { try await $0.serverSettings(token: $1) }
            status.notice = "Przedrostki zapisane; tytuły przeliczone."
        }
    }

    func purgeCache(itemsOnly: Bool) async {
        await status.run("Czyszczenie…", failure: "Nie udało się wyczyścić pamięci podręcznej") {
            try await account.withAdminToken { try await $0.purgeCache(itemsOnly: itemsOnly, token: $1) }
            status.notice = itemsOnly ? "Wyczyszczono pamięć podręczną pozycji." : "Wyczyszczono całą pamięć podręczną."
        }
    }

    func serverRestarted() { watcherChangedSinceStart = false }
}

// MARK: - Klucze API

@MainActor
@Observable
final class ApiKeysModel {
    private let account: ServerAccount
    let status = AdminStatus()

    private(set) var keys: [AudiobookshelfClient.ApiKey] = []
    private(set) var users: [AudiobookshelfClient.ManagedUser] = []
    private(set) var isLoaded = false
    /// Treść nowego klucza — tylko w pamięci, do pierwszego zamknięcia okna z nim.
    var createdSecret: (name: String, secret: String)?

    init(account: ServerAccount) {
        self.account = account
    }

    func load() async {
        await status.run("Wczytywanie…", failure: "Nie udało się wczytać kluczy API") {
            keys = try await account.withAdminToken { try await $0.apiKeys(token: $1) }.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            users = try await account.withAdminToken { try await $0.users(token: $1) }
            isLoaded = true
        }
    }

    func create(name: String, userID: String, expiresIn: Int?, isActive: Bool) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return await status.run("Tworzenie klucza…", failure: "Nie udało się utworzyć klucza") {
            guard !name.isEmpty else { throw ItemManager.ManageError.invalid("Podaj nazwę klucza.") }
            let created = try await account.withAdminToken {
                try await $0.createApiKey(name: name, userID: userID, expiresIn: expiresIn, isActive: isActive, token: $1)
            }
            keys.insert(created.key, at: 0)
            createdSecret = (name, created.secret)
        }
    }

    func setActive(_ key: AudiobookshelfClient.ApiKey, _ active: Bool) async {
        await status.run("Zapisywanie…", failure: "Nie udało się zmienić klucza") {
            let updated = try await account.withAdminToken { try await $0.updateApiKey(id: key.id, isActive: active, token: $1) }
            if let index = keys.firstIndex(where: { $0.id == key.id }) { keys[index] = updated }
        }
    }

    func delete(_ key: AudiobookshelfClient.ApiKey) async {
        await status.run("Usuwanie…", failure: "Nie udało się usunąć klucza") {
            try await account.withAdminToken { try await $0.deleteApiKey(id: key.id, token: $1) }
            keys.removeAll { $0.id == key.id }
        }
    }
}

// MARK: - Logowanie

/// Ustawienia logowania (wzorzec: `client/pages/config/authentication.vue`). Hasło lokalne
/// jest zawsze włączone: aplikacja loguje się nim na konto root i konto słuchacza, a serwer
/// przyjąłby samo `openid` i odciął ją od obu (`MiscController.updateAuthSettings`).
@MainActor
@Observable
final class AuthSettingsModel {
    private let account: ServerAccount
    let status = AdminStatus()

    private(set) var settings: AudiobookshelfClient.AuthSettings?
    private(set) var signingAlgorithms: [String] = []

    init(account: ServerAccount) {
        self.account = account
    }

    func load() async {
        await status.run("Wczytywanie…", failure: "Nie udało się wczytać ustawień logowania") {
            settings = try await account.withAdminToken { try await $0.authSettings(token: $1) }
        }
    }

    /// Uzupełnia adresy z dokumentu wystawcy (`/.well-known/openid-configuration`).
    func discover(into draft: AudiobookshelfClient.AuthSettings) async -> AudiobookshelfClient.AuthSettings {
        var draft = draft
        let issuer = (draft.authOpenIDIssuerURL ?? "").trimmingCharacters(in: .whitespaces)
        await status.run("Pobieranie danych wystawcy…", failure: "Nie udało się pobrać danych wystawcy") {
            guard !issuer.isEmpty else { throw ItemManager.ManageError.invalid("Podaj adres wystawcy (Issuer URL).") }
            let config = try await account.withAdminToken { try await $0.openIDConfiguration(issuer: issuer, token: $1) }
            draft.authOpenIDIssuerURL = config.issuer ?? draft.authOpenIDIssuerURL
            draft.authOpenIDAuthorizationURL = config.authorization_endpoint ?? draft.authOpenIDAuthorizationURL
            draft.authOpenIDTokenURL = config.token_endpoint ?? draft.authOpenIDTokenURL
            draft.authOpenIDUserInfoURL = config.userinfo_endpoint ?? draft.authOpenIDUserInfoURL
            draft.authOpenIDLogoutURL = config.end_session_endpoint ?? draft.authOpenIDLogoutURL
            draft.authOpenIDJwksURL = config.jwks_uri ?? draft.authOpenIDJwksURL
            if let algorithms = config.id_token_signing_alg_values_supported, !algorithms.isEmpty {
                signingAlgorithms = algorithms
                if !algorithms.contains(draft.authOpenIDTokenSigningAlgorithm ?? "") { draft.authOpenIDTokenSigningAlgorithm = algorithms[0] }
            }
            status.notice = "Adresy uzupełnione z danych wystawcy. Zapisz, żeby je zastosować."
        }
        return draft
    }

    func save(_ draft: AudiobookshelfClient.AuthSettings) async {
        var draft = draft
        // Blokada w modelu, nie tylko w widoku.
        draft.authActiveAuthMethods = AudiobookshelfClient.AuthSettings.withLocal(draft.authActiveAuthMethods)
        await status.run("Zapisywanie…", failure: "Nie udało się zapisać ustawień logowania") {
            if draft.authActiveAuthMethods.contains("openid") {
                let required: [(String?, String)] = [
                    (draft.authOpenIDIssuerURL, "adres wystawcy"), (draft.authOpenIDAuthorizationURL, "adres autoryzacji"),
                    (draft.authOpenIDTokenURL, "adres tokenu"), (draft.authOpenIDUserInfoURL, "adres userinfo"),
                    (draft.authOpenIDJwksURL, "adres JWKS"), (draft.authOpenIDClientID, "identyfikator klienta"),
                    (draft.authOpenIDClientSecret, "sekret klienta"), (draft.authOpenIDTokenSigningAlgorithm, "algorytm podpisu"),
                ]
                let missing = required.filter { ($0.0 ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.map(\.1)
                if !missing.isEmpty {
                    throw ItemManager.ManageError.invalid("Do włączenia OpenID brakuje: \(missing.joined(separator: ", ")).")
                }
            }
            let updated = try await account.withAdminToken { try await $0.updateAuthSettings(draft, token: $1) }
            settings = try await account.withAdminToken { try await $0.authSettings(token: $1) }
            status.notice = updated ? "Ustawienia logowania zapisane." : "Bez zmian."
        }
    }
}

// MARK: - Sesje słuchania

@MainActor
@Observable
final class SessionsModel {
    static let perPage = 25

    private let account: ServerAccount
    let status = AdminStatus()

    private(set) var page: AudiobookshelfClient.SessionPage?
    private(set) var open: [AudiobookshelfClient.ListeningSession] = []
    private(set) var users: [AudiobookshelfClient.ManagedUser] = []
    var userFilter: String?
    var pageIndex = 0
    var selection: Set<String> = []

    init(account: ServerAccount, userFilter: String? = nil) {
        self.account = account
        self.userFilter = userFilter
    }

    /// Identyfikator urządzenia odtwarzacza na tym Macu (`ListeningController.deviceInfo`).
    static var thisDeviceID: String? { UserDefaults.standard.string(forKey: "listeningDeviceID") }

    func isThisMac(_ session: AudiobookshelfClient.ListeningSession) -> Bool {
        guard let id = Self.thisDeviceID else { return false }
        return session.deviceInfo?.deviceId == id
    }

    func load() async {
        await status.run("Wczytywanie…", failure: "Nie udało się wczytać sesji") {
            if users.isEmpty { users = try await account.withAdminToken { try await $0.users(token: $1) } }
            try await reload()
        }
    }

    private func reload() async throws {
        open = try await account.withAdminToken { try await $0.openSessions(token: $1) }
        var result = try await account.withAdminToken { [userFilter, pageIndex] in
            try await $0.sessions(userID: userFilter, page: pageIndex, perPage: Self.perPage, token: $1)
        }
        if result.sessions.isEmpty, pageIndex > 0, result.numPages > 0 {
            pageIndex = result.numPages - 1
            result = try await account.withAdminToken { [userFilter, pageIndex] in
                try await $0.sessions(userID: userFilter, page: pageIndex, perPage: Self.perPage, token: $1)
            }
        }
        page = result
        selection.formIntersection(result.sessions.map(\.id))
    }

    func close(_ session: AudiobookshelfClient.ListeningSession) async {
        await status.run("Zamykanie…", failure: "Nie udało się zamknąć sesji") {
            try await account.withAdminToken { try await $0.closeSession(id: session.id, token: $1) }
            try await reload()
        }
    }

    func delete(ids: [String]) async {
        guard !ids.isEmpty else { return }
        await status.run("Usuwanie…", failure: "Nie udało się usunąć sesji") {
            try await account.withAdminToken { try await $0.deleteSessions(ids: ids, token: $1) }
            selection.subtract(ids)
            try await reload()
            status.notice = ids.count == 1 ? "Sesja usunięta." : "Usunięto sesje: \(ids.count)."
        }
    }
}

// MARK: - Kanały RSS

@MainActor
@Observable
final class FeedsModel {
    private let account: ServerAccount
    let status = AdminStatus()
    private(set) var feeds: [AudiobookshelfClient.Feed] = []
    private(set) var isLoaded = false

    init(account: ServerAccount) {
        self.account = account
    }

    func load() async {
        await status.run("Wczytywanie…", failure: "Nie udało się wczytać kanałów RSS") {
            feeds = try await account.withAdminToken { try await $0.feeds(token: $1) }
            isLoaded = true
        }
    }

    func close(_ feed: AudiobookshelfClient.Feed) async {
        await status.run("Zamykanie…", failure: "Nie udało się zamknąć kanału") {
            try await account.withAdminToken { try await $0.closeFeed(id: feed.id, token: $1) }
            feeds.removeAll { $0.id == feed.id }
        }
    }
}

// MARK: - Powiadomienia

@MainActor
@Observable
final class NotificationsModel {
    private let account: ServerAccount
    let status = AdminStatus()
    private(set) var events: [AudiobookshelfClient.NotificationEvent] = []
    private(set) var settings: AudiobookshelfClient.NotificationSettings?
    private(set) var libraries: [(id: String, name: String, mediaType: String)] = []

    init(account: ServerAccount) {
        self.account = account
    }

    func load() async {
        await status.run("Wczytywanie…", failure: "Nie udało się wczytać powiadomień") {
            let result = try await account.withAdminToken { try await $0.notifications(token: $1) }
            events = result.data.events
            settings = result.settings
            libraries = account.libraries.map { ($0.id, $0.name, $0.mediaType) }
        }
    }

    func event(named name: String) -> AudiobookshelfClient.NotificationEvent? {
        events.first { $0.name == name }
    }

    func saveServer(url: String, maxFailedAttempts: Int, maxQueue: Int) async {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        await status.run("Zapisywanie…", failure: "Nie udało się zapisać ustawień Apprise") {
            if !url.isEmpty {
                guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else {
                    throw ItemManager.ManageError.invalid("Adres serwera Apprise musi zaczynać się od http:// albo https://.")
                }
            }
            guard maxFailedAttempts > 0, maxQueue > 0 else { throw ItemManager.ManageError.invalid("Limity muszą być większe od zera.") }
            try await account.withAdminToken {
                try await $0.updateNotificationSettings(appriseApiUrl: url.isEmpty ? nil : url, maxFailedAttempts: maxFailedAttempts, maxNotificationQueue: maxQueue, token: $1)
            }
            settings = try await account.withAdminToken { try await $0.notifications(token: $1) }.settings
            status.notice = "Ustawienia Apprise zapisane."
        }
    }

    func save(id: String?, _ changes: AudiobookshelfClient.NotificationChanges) async -> Bool {
        await status.run("Zapisywanie…", failure: "Nie udało się zapisać powiadomienia") {
            guard !changes.urls.isEmpty else { throw ItemManager.ManageError.invalid("Podaj co najmniej jeden adres Apprise.") }
            guard !changes.titleTemplate.isEmpty, !changes.bodyTemplate.isEmpty else {
                throw ItemManager.ManageError.invalid("Tytuł i treść nie mogą być puste.")
            }
            settings = try await account.withAdminToken {
                if let id { try await $0.updateNotification(id: id, changes, token: $1) } else { try await $0.createNotification(changes, token: $1) }
            }
        }
    }

    func setEnabled(_ notification: AudiobookshelfClient.AppNotification, _ enabled: Bool) async {
        _ = await save(id: notification.id, .init(id: notification.id, libraryId: notification.libraryId, eventName: notification.eventName, urls: notification.urls,
                                                   titleTemplate: notification.titleTemplate, bodyTemplate: notification.bodyTemplate,
                                                   enabled: enabled, type: notification.type))
    }

    func delete(_ notification: AudiobookshelfClient.AppNotification) async {
        await status.run("Usuwanie…", failure: "Nie udało się usunąć powiadomienia") {
            settings = try await account.withAdminToken { try await $0.deleteNotification(id: notification.id, token: $1) }
        }
    }

    func test(_ notification: AudiobookshelfClient.AppNotification) async {
        await status.run("Wysyłanie próby…", failure: "Próbne powiadomienie nie doszło") {
            try await account.withAdminToken { try await $0.testNotification(id: notification.id, token: $1) }
            status.notice = "Serwer Apprise przyjął próbne powiadomienie."
        }
    }
}

// MARK: - E-mail

@MainActor
@Observable
final class EmailModel {
    private let account: ServerAccount
    let status = AdminStatus()
    private(set) var settings: AudiobookshelfClient.EmailSettings?
    private(set) var users: [AudiobookshelfClient.ManagedUser] = []

    init(account: ServerAccount) {
        self.account = account
    }

    var isConfigured: Bool { !(settings?.host ?? "").isEmpty }

    func load() async {
        await status.run("Wczytywanie…", failure: "Nie udało się wczytać ustawień e-mail") {
            settings = try await account.withAdminToken { try await $0.emailSettings(token: $1) }
            users = try await account.withAdminToken { try await $0.users(token: $1) }
        }
    }

    func save(_ draft: AudiobookshelfClient.EmailSettings) async {
        var draft = draft
        func clean(_ value: String?) -> String? {
            let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        draft.host = clean(draft.host)
        draft.user = clean(draft.user)
        draft.testAddress = clean(draft.testAddress)
        draft.fromAddress = clean(draft.fromAddress)
        if draft.pass?.isEmpty == true { draft.pass = nil }
        await status.run("Zapisywanie…", failure: "Nie udało się zapisać ustawień e-mail") {
            guard (1...65535).contains(draft.port) else { throw ItemManager.ManageError.invalid("Port musi być od 1 do 65535.") }
            settings = try await account.withAdminToken { try await $0.updateEmailSettings(draft, token: $1) }
            status.notice = "Ustawienia e-mail zapisane."
        }
    }

    func sendTest() async {
        await status.run("Wysyłanie próbnego e-maila…", failure: "Próbny e-mail nie został wysłany") {
            guard let address = settings?.testAddress, !address.isEmpty else {
                throw ItemManager.ManageError.invalid("Najpierw zapisz adres do próbnej wiadomości.")
            }
            try await account.withAdminToken { try await $0.sendTestEmail(token: $1) }
            status.notice = "Serwer wysłał próbną wiadomość na \(address)."
        }
    }

    /// Zapisuje całą listę czytników (upstream nie ma zmiany pojedynczego).
    func saveDevices(_ devices: [AudiobookshelfClient.EreaderDevice]) async -> Bool {
        await status.run("Zapisywanie czytników…", failure: "Nie udało się zapisać czytników") {
            for device in devices {
                guard !device.name.trimmingCharacters(in: .whitespaces).isEmpty, device.email.contains("@") else {
                    throw ItemManager.ManageError.invalid("Każdy czytnik musi mieć nazwę i adres e-mail.")
                }
            }
            guard Set(devices.map(\.name)).count == devices.count else {
                throw ItemManager.ManageError.invalid("Nazwy czytników muszą być różne — po nazwie serwer wybiera adres.")
            }
            let saved = try await account.withAdminToken { try await $0.updateEreaderDevices(devices, token: $1) }
            settings?.ereaderDevices = saved
        }
    }
}
