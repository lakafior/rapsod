import Foundation

/// Punkty API stron konfiguracji serwera (etap 9f): ustawienia serwera, klucze API, sesje
/// słuchania, kanały RSS, powiadomienia (Apprise), e-mail (SMTP i czytniki) i logowanie.
/// Wszystkie wymagają tokenu root (`ServerAccount.withAdminToken`). Kształty z upstreamu v2.38.0:
/// `server/objects/settings/ServerSettings.js`, `MiscController.js`, `ApiKeyController.js`,
/// `SessionController.js`, `RSSFeedController.js`, `NotificationController.js`, `EmailController.js`.
extension AudiobookshelfClient {
    // MARK: Ustawienia serwera

    /// Ustawienia z `serverSettings` (`ServerSettings.toJSONForBrowser`), tylko te, które
    /// aplikacja pokazuje. Brakujące pola dostają wartości domyślne upstreamu.
    struct ServerSettings: Decodable, Sendable, Equatable {
        var scannerParseSubtitle = false
        var scannerFindCovers = false
        var scannerCoverProvider = "google"
        var scannerPreferMatchedMetadata = false
        var scannerDisableWatcher = false
        var storeCoverWithItem = false
        var storeMetadataWithItem = false
        var sortingIgnorePrefix = false
        var sortingPrefixes = ["the", "a"]
        var language = "en-us"
        /// `LogLevel` z `server/utils/constants.js`: 0 trace, 1 debug, 2 info, 3 warn, 4 error.
        var logLevel = 2
        var authActiveAuthMethods = ["local"]

        init() {}

        private enum CodingKeys: String, CodingKey {
            case scannerParseSubtitle, scannerFindCovers, scannerCoverProvider, scannerPreferMatchedMetadata,
                 scannerDisableWatcher, storeCoverWithItem, storeMetadataWithItem, sortingIgnorePrefix,
                 sortingPrefixes, language, logLevel, authActiveAuthMethods
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func flag(_ key: CodingKeys) -> Bool { (try? c.decode(Bool.self, forKey: key)) ?? false }
            scannerParseSubtitle = flag(.scannerParseSubtitle)
            scannerFindCovers = flag(.scannerFindCovers)
            scannerCoverProvider = (try? c.decode(String.self, forKey: .scannerCoverProvider)) ?? "google"
            scannerPreferMatchedMetadata = flag(.scannerPreferMatchedMetadata)
            scannerDisableWatcher = flag(.scannerDisableWatcher)
            storeCoverWithItem = flag(.storeCoverWithItem)
            storeMetadataWithItem = flag(.storeMetadataWithItem)
            sortingIgnorePrefix = flag(.sortingIgnorePrefix)
            sortingPrefixes = (try? c.decode([String].self, forKey: .sortingPrefixes)) ?? ["the", "a"]
            language = (try? c.decode(String.self, forKey: .language)) ?? "en-us"
            logLevel = (try? c.decode(Int.self, forKey: .logLevel)) ?? 2
            authActiveAuthMethods = (try? c.decode([String].self, forKey: .authActiveAuthMethods)) ?? ["local"]
        }
    }

    /// Zmienione pola ustawień (`PATCH /api/settings`); `nil` nie jest wysyłane.
    struct ServerSettingsChanges: Encodable, Sendable {
        var scannerParseSubtitle: Bool?
        var scannerFindCovers: Bool?
        var scannerCoverProvider: String?
        var scannerPreferMatchedMetadata: Bool?
        var scannerDisableWatcher: Bool?
        var storeCoverWithItem: Bool?
        var storeMetadataWithItem: Bool?
        var sortingIgnorePrefix: Bool?
        var language: String?
        var logLevel: Int?

        /// Różnica między stanem serwera a szkicem.
        init(from old: ServerSettings, to new: ServerSettings) {
            func diff<T: Equatable>(_ path: KeyPath<ServerSettings, T>) -> T? { old[keyPath: path] == new[keyPath: path] ? nil : new[keyPath: path] }
            scannerParseSubtitle = diff(\.scannerParseSubtitle)
            scannerFindCovers = diff(\.scannerFindCovers)
            scannerCoverProvider = diff(\.scannerCoverProvider)
            scannerPreferMatchedMetadata = diff(\.scannerPreferMatchedMetadata)
            scannerDisableWatcher = diff(\.scannerDisableWatcher)
            storeCoverWithItem = diff(\.storeCoverWithItem)
            storeMetadataWithItem = diff(\.storeMetadataWithItem)
            sortingIgnorePrefix = diff(\.sortingIgnorePrefix)
            language = diff(\.language)
            logLevel = diff(\.logLevel)
        }

        var isEmpty: Bool {
            [scannerParseSubtitle, scannerFindCovers, scannerPreferMatchedMetadata, scannerDisableWatcher,
             storeCoverWithItem, storeMetadataWithItem, sortingIgnorePrefix].allSatisfy { $0 == nil }
                && scannerCoverProvider == nil && language == nil && logLevel == nil
        }
    }

    /// Ustawienia serwera z `POST /api/authorize` (upstream nie ma `GET /api/settings`).
    func serverSettings(token: String) async throws -> ServerSettings {
        struct Response: Decodable { let serverSettings: ServerSettings }
        return try decode(Response.self, from: await send("POST", "api/authorize", token: token)).serverSettings
    }

    @discardableResult
    func updateServerSettings(_ changes: ServerSettingsChanges, token: String) async throws -> ServerSettings {
        struct Response: Decodable { let serverSettings: ServerSettings }
        return try decode(Response.self, from: await send("PATCH", "api/settings", body: changes, token: token)).serverSettings
    }

    /// Przedrostki pomijane przy sortowaniu; serwer przelicza od razu tytuły książek i podcastów.
    func updateSortingPrefixes(_ prefixes: [String], token: String) async throws {
        struct Body: Encodable { let sortingPrefixes: [String] }
        _ = try await send("PATCH", "api/sorting-prefixes", body: Body(sortingPrefixes: prefixes), token: token, timeout: 300)
    }

    /// Czyści całą pamięć podręczną (`metadata/cache`) albo tylko okładki pozycji (`cache/items`).
    func purgeCache(itemsOnly: Bool, token: String) async throws {
        _ = try await send("POST", itemsOnly ? "api/cache/items/purge" : "api/cache/purge", token: token, timeout: 300)
    }

    // MARK: Klucze API

    struct UserRef: Decodable, Sendable, Hashable {
        let id: String
        let username: String
        let type: String?
    }

    /// Klucz API (`models/ApiKey.js`, `toJSON`). Sam klucz serwer zwraca tylko przy utworzeniu.
    struct ApiKey: Decodable, Sendable, Identifiable, Hashable {
        let id: String
        let name: String
        let description: String?
        let expiresAt: Date?
        let lastUsedAt: Date?
        let isActive: Bool
        let userId: String?
        let user: UserRef?
        let createdByUserId: String?
        let createdAt: Date?

        var isExpired: Bool { expiresAt.map { $0 < .now } ?? false }

        private enum CodingKeys: String, CodingKey {
            case id, name, description, expiresAt, lastUsedAt, isActive, userId, user, createdByUserId, createdAt
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
            description = try? c.decode(String.self, forKey: .description)
            expiresAt = AudiobookshelfClient.isoDate(c, .expiresAt)
            lastUsedAt = AudiobookshelfClient.isoDate(c, .lastUsedAt)
            isActive = (try? c.decode(Bool.self, forKey: .isActive)) ?? false
            userId = try? c.decode(String.self, forKey: .userId)
            user = try? c.decode(UserRef.self, forKey: .user)
            createdByUserId = try? c.decode(String.self, forKey: .createdByUserId)
            createdAt = AudiobookshelfClient.isoDate(c, .createdAt)
        }
    }

    /// Daty Sequelize przychodzą jako ISO 8601 z ułamkiem sekundy.
    fileprivate static func isoDate<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Date? {
        guard let text = try? container.decode(String.self, forKey: key) else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    func apiKeys(token: String) async throws -> [ApiKey] {
        struct Response: Decodable { let apiKeys: [ApiKey] }
        return try decode(Response.self, from: await send("GET", "api-keys".apiPath, token: token)).apiKeys
    }

    /// Nowy klucz i jego treść (pokazywana raz). `expiresIn` w sekundach; `nil` = bez wygasania.
    func createApiKey(name: String, userID: String, expiresIn: Int?, isActive: Bool, token: String) async throws -> (key: ApiKey, secret: String) {
        struct Body: Encodable { let name: String; let userId: String; let expiresIn: Int?; let isActive: Bool }
        struct Created: Decodable { let apiKey: String }
        struct Response: Decodable { let apiKey: ApiKey }
        struct SecretResponse: Decodable { let apiKey: Created }
        let data = try await send("POST", "api-keys".apiPath, body: Body(name: name, userId: userID, expiresIn: expiresIn, isActive: isActive), token: token)
        return (try decode(Response.self, from: data).apiKey, try decode(SecretResponse.self, from: data).apiKey.apiKey)
    }

    func updateApiKey(id: String, isActive: Bool, token: String) async throws -> ApiKey {
        struct Body: Encodable { let isActive: Bool }
        struct Response: Decodable { let apiKey: ApiKey }
        return try decode(Response.self, from: await send("PATCH", "api-keys/\(id)".apiPath, body: Body(isActive: isActive), token: token)).apiKey
    }

    func deleteApiKey(id: String, token: String) async throws {
        _ = try await send("DELETE", "api-keys/\(id)".apiPath, token: token)
    }

    // MARK: Sesje słuchania

    struct SessionDevice: Decodable, Sendable, Hashable {
        let deviceId: String?
        let clientName: String?
        let clientVersion: String?
        let deviceName: String?
        let osName: String?
        let osVersion: String?
        let browserName: String?
        let model: String?
        let manufacturer: String?
        let ipAddress: String?

        var summary: String {
            let device = deviceName ?? [manufacturer, model].compactMap { $0 }.joined(separator: " ")
            let client = [clientName, clientVersion].compactMap { $0 }.joined(separator: " ")
            let system = [osName, osVersion].compactMap { $0 }.joined(separator: " ")
            return [client, device, browserName ?? "", system].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    /// Sesja odtwarzania (`objects/PlaybackSession.js`, `toJSON`), z użytkownikiem dołączonym przez serwer.
    struct ListeningSession: Decodable, Sendable, Identifiable, Hashable {
        let id: String
        let userId: String?
        let libraryItemId: String?
        let episodeId: String?
        let mediaType: String?
        let displayTitle: String?
        let displayAuthor: String?
        let duration: Double?
        /// 0 bezpośrednio, 1 strumień, 2 transkodowanie, 3 lokalnie (`PlayMethod`).
        let playMethod: Int?
        let mediaPlayer: String?
        let deviceInfo: SessionDevice?
        let serverVersion: String?
        let date: String?
        let timeListening: Double?
        let startTime: Double?
        let currentTime: Double?
        /// Milisekundy od 1970.
        let startedAt: Double?
        let updatedAt: Double?
        let user: UserRef?

        var started: Date? { startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
        var updated: Date? { updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

        var playMethodText: String {
            switch playMethod {
            case 0: "bezpośrednio"
            case 1: "strumień"
            case 2: "transkodowanie"
            case 3: "lokalnie (pobrane)"
            default: "—"
            }
        }
    }

    struct SessionPage: Decodable, Sendable {
        let total: Int
        let numPages: Int
        let page: Int
        let itemsPerPage: Int
        let sessions: [ListeningSession]
    }

    /// Historia sesji z bazy, od najnowszych (`GET /api/sessions`).
    func sessions(userID: String?, page: Int, perPage: Int, token: String) async throws -> SessionPage {
        var query = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "itemsPerPage", value: String(perPage)),
            URLQueryItem(name: "sort", value: "updatedAt"),
            URLQueryItem(name: "desc", value: "1"),
        ]
        if let userID { query.append(URLQueryItem(name: "user", value: userID)) }
        return try decode(SessionPage.self, from: await send("GET", "api/sessions", query: query, token: token))
    }

    /// Sesje otwarte teraz w pamięci serwera.
    func openSessions(token: String) async throws -> [ListeningSession] {
        struct Response: Decodable { let sessions: [ListeningSession] }
        return try decode(Response.self, from: await send("GET", "api/sessions/open", token: token)).sessions
    }

    /// Zamyka otwartą sesję (zapisuje ją w historii); administrator może zamknąć cudzą.
    func closeSession(id: String, token: String) async throws {
        _ = try await send("POST", "api/session/\(id)/close", token: token)
    }

    /// Usuwa sesje z historii; otwarte są najpierw zamykane bez zapisu.
    func deleteSessions(ids: [String], token: String) async throws {
        struct Body: Encodable { let sessions: [String] }
        _ = try await send("POST", "api/sessions/batch/delete", body: Body(sessions: ids), token: token)
    }

    // MARK: Kanały RSS

    struct FeedMeta: Decodable, Sendable, Hashable {
        let title: String?
        let author: String?
        let preventIndexing: Bool?
        let ownerName: String?
        let ownerEmail: String?
    }

    /// Otwarty kanał (`models/Feed.js`, `toOldJSON` / `toOldJSONMinified`).
    struct Feed: Decodable, Sendable, Identifiable, Hashable {
        let id: String
        let slug: String?
        let entityType: String?
        let entityId: String?
        let feedUrl: String?
        let serverAddress: String?
        let meta: FeedMeta?
        let createdAt: Double?

        /// Pełny adres kanału (`feedUrl` jest względny: `/feed/<slug>`).
        var url: URL? {
            guard let feedUrl else { return nil }
            if feedUrl.hasPrefix("http") { return URL(string: feedUrl) }
            return URL(string: (serverAddress ?? "") + feedUrl)
        }

        var entityText: String {
            switch entityType {
            case "libraryItem": "pozycja"
            case "collection": "kolekcja"
            case "series": "seria"
            default: entityType ?? "—"
            }
        }
    }

    func feeds(token: String) async throws -> [Feed] {
        struct Response: Decodable { let feeds: [Feed] }
        return try decode(Response.self, from: await send("GET", "api/feeds", token: token)).feeds
    }

    struct FeedOptions: Encodable, Sendable {
        struct Details: Encodable, Sendable {
            var preventIndexing = true
            var ownerName: String?
            var ownerEmail: String?
        }
        let serverAddress: String
        let slug: String
        var metadataDetails = Details()
    }

    /// Otwiera kanał dla pozycji z audio. Zajęty `slug`: HTTP 400 „Slug already in use”.
    func openFeed(itemID: String, options: FeedOptions, token: String) async throws -> Feed {
        struct Response: Decodable { let feed: Feed }
        return try decode(Response.self, from: await send("POST", "api/feeds/item/\(itemID)/open", body: options, token: token)).feed
    }

    func closeFeed(id: String, token: String) async throws {
        _ = try await send("POST", "api/feeds/\(id)/close", token: token)
    }

    // MARK: Powiadomienia (Apprise)

    struct NotificationEvent: Decodable, Sendable, Hashable, Identifiable {
        struct Defaults: Decodable, Sendable, Hashable {
            let title: String?
            let body: String?
        }
        let name: String
        let requiresLibrary: Bool?
        let libraryMediaType: String?
        let description: String?
        let variables: [String]?
        let defaults: Defaults?
        var id: String { name }
    }

    struct NotificationData: Decodable, Sendable {
        let events: [NotificationEvent]
    }

    /// Powiadomienie (`objects/Notification.js`).
    struct AppNotification: Codable, Sendable, Identifiable, Hashable {
        var id: String
        var libraryId: String?
        var eventName: String
        var urls: [String]
        var titleTemplate: String
        var bodyTemplate: String
        var enabled: Bool
        var type: String?
        var lastFiredAt: Double?
        var lastAttemptFailed: Bool?
        var numConsecutiveFailedAttempts: Int?
        var numTimesFired: Int?
        var createdAt: Double?
    }

    struct NotificationSettings: Decodable, Sendable, Equatable {
        var appriseApiUrl: String?
        var notifications: [AppNotification]
        var maxFailedAttempts: Int
        var maxNotificationQueue: Int
    }

    func notifications(token: String) async throws -> (data: NotificationData, settings: NotificationSettings) {
        struct Response: Decodable { let data: NotificationData; let settings: NotificationSettings }
        let response = try decode(Response.self, from: await send("GET", "api/notifications", token: token))
        return (response.data, response.settings)
    }

    func updateNotificationSettings(appriseApiUrl: String?, maxFailedAttempts: Int, maxNotificationQueue: Int, token: String) async throws {
        struct Body: Encodable { let appriseApiUrl: String?; let maxFailedAttempts: Int; let maxNotificationQueue: Int }
        _ = try await send("PATCH", "api/notifications", body: Body(appriseApiUrl: appriseApiUrl, maxFailedAttempts: maxFailedAttempts, maxNotificationQueue: maxNotificationQueue), token: token)
    }

    /// Pola wysyłane przy tworzeniu i zmianie powiadomienia (jak `NotificationEditModal.vue`).
    struct NotificationChanges: Encodable, Sendable {
        var libraryId: String?
        var eventName: String
        var urls: [String]
        var titleTemplate: String
        var bodyTemplate: String
        var enabled: Bool
        var type: String?
    }

    func createNotification(_ changes: NotificationChanges, token: String) async throws -> NotificationSettings {
        try decode(NotificationSettings.self, from: await send("POST", "api/notifications", body: changes, token: token))
    }

    func updateNotification(id: String, _ changes: NotificationChanges, token: String) async throws -> NotificationSettings {
        try decode(NotificationSettings.self, from: await send("PATCH", "api/notifications/\(id)", body: changes, token: token))
    }

    func deleteNotification(id: String, token: String) async throws -> NotificationSettings {
        try decode(NotificationSettings.self, from: await send("DELETE", "api/notifications/\(id)", token: token))
    }

    /// Wysyła próbne powiadomienie na adresy tego powiadomienia (przez serwer Apprise).
    func testNotification(id: String, token: String) async throws {
        _ = try await send("GET", "api/notifications/\(id)/test", token: token, timeout: 60)
    }

    // MARK: E-mail (SMTP) i czytniki

    struct EreaderDevice: Codable, Sendable, Hashable, Identifiable {
        var name: String
        var email: String
        /// `adminOrUp`, `userOrUp`, `guestOrUp` albo `specificUsers`.
        var availabilityOption: String
        var users: [String]
        var id: String { name }

        init(name: String = "", email: String = "", availabilityOption: String = "adminOrUp", users: [String] = []) {
            self.name = name
            self.email = email
            self.availabilityOption = availabilityOption
            self.users = users
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
            email = (try? c.decode(String.self, forKey: .email)) ?? ""
            availabilityOption = (try? c.decode(String.self, forKey: .availabilityOption)) ?? "adminOrUp"
            users = (try? c.decode([String].self, forKey: .users)) ?? []
        }
    }

    /// Ustawienia poczty (`objects/settings/EmailSettings.js`). Hasło serwer trzyma u siebie;
    /// aplikacja pokazuje je tylko w zamaskowanym polu i nigdy nie loguje.
    struct EmailSettings: Codable, Sendable, Equatable {
        var host: String?
        var port: Int
        var secure: Bool
        var rejectUnauthorized: Bool
        var user: String?
        var pass: String?
        var testAddress: String?
        var fromAddress: String?
        var ereaderDevices: [EreaderDevice]

        private enum CodingKeys: String, CodingKey {
            case host, port, secure, rejectUnauthorized, user, pass, testAddress, fromAddress, ereaderDevices
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            host = try? c.decode(String.self, forKey: .host)
            port = (try? c.decode(Int.self, forKey: .port)) ?? 465
            secure = (try? c.decode(Bool.self, forKey: .secure)) ?? true
            rejectUnauthorized = (try? c.decode(Bool.self, forKey: .rejectUnauthorized)) ?? true
            user = try? c.decode(String.self, forKey: .user)
            pass = try? c.decode(String.self, forKey: .pass)
            testAddress = try? c.decode(String.self, forKey: .testAddress)
            fromAddress = try? c.decode(String.self, forKey: .fromAddress)
            ereaderDevices = (try? c.decode([EreaderDevice].self, forKey: .ereaderDevices)) ?? []
        }

        /// Bez czytników — te zapisuje osobny punkt API.
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(host, forKey: .host)
            try c.encode(port, forKey: .port)
            try c.encode(secure, forKey: .secure)
            try c.encode(rejectUnauthorized, forKey: .rejectUnauthorized)
            try c.encode(user, forKey: .user)
            try c.encode(pass, forKey: .pass)
            try c.encode(testAddress, forKey: .testAddress)
            try c.encode(fromAddress, forKey: .fromAddress)
        }
    }

    func emailSettings(token: String) async throws -> EmailSettings {
        struct Response: Decodable { let settings: EmailSettings }
        return try decode(Response.self, from: await send("GET", "api/emails/settings", token: token)).settings
    }

    func updateEmailSettings(_ settings: EmailSettings, token: String) async throws -> EmailSettings {
        struct Response: Decodable { let settings: EmailSettings }
        return try decode(Response.self, from: await send("PATCH", "api/emails/settings", body: settings, token: token)).settings
    }

    /// Próbny e-mail na `testAddress` (zapisany na serwerze).
    func sendTestEmail(token: String) async throws {
        _ = try await send("POST", "api/emails/test", token: token, timeout: 90)
    }

    func updateEreaderDevices(_ devices: [EreaderDevice], token: String) async throws -> [EreaderDevice] {
        struct Body: Encodable { let ereaderDevices: [EreaderDevice] }
        struct Response: Decodable { let ereaderDevices: [EreaderDevice] }
        return try decode(Response.self, from: await send("POST", "api/emails/ereader-devices", body: Body(ereaderDevices: devices), token: token)).ereaderDevices
    }

    /// Wysyła e-book pozycji e-mailem na czytnik (`POST /api/emails/send-ebook-to-device`).
    func sendEbook(itemID: String, deviceName: String, token: String) async throws {
        struct Body: Encodable { let libraryItemId: String; let deviceName: String }
        _ = try await send("POST", "api/emails/send-ebook-to-device", body: Body(libraryItemId: itemID, deviceName: deviceName), token: token, timeout: 120)
    }

    // MARK: Logowanie (hasło lokalne / OpenID Connect)

    /// `ServerSettings.authenticationSettings`. Sekret klienta przychodzi z serwera i wraca
    /// do niego bez zmian; aplikacja pokazuje go tylko w zamaskowanym polu.
    struct AuthSettings: Codable, Sendable, Equatable {
        var authLoginCustomMessage: String?
        var authActiveAuthMethods: [String]
        var authOpenIDIssuerURL: String?
        var authOpenIDAuthorizationURL: String?
        var authOpenIDTokenURL: String?
        var authOpenIDUserInfoURL: String?
        var authOpenIDJwksURL: String?
        var authOpenIDLogoutURL: String?
        var authOpenIDClientID: String?
        var authOpenIDClientSecret: String?
        var authOpenIDTokenSigningAlgorithm: String?
        var authOpenIDButtonText: String?
        var authOpenIDAutoLaunch: Bool
        var authOpenIDAutoRegister: Bool
        /// `nil`, `email` albo `username`.
        var authOpenIDMatchExistingBy: String?
        var authOpenIDMobileRedirectURIs: [String]
        var authOpenIDGroupClaim: String?
        var authOpenIDAdvancedPermsClaim: String?
        var authOpenIDSubfolderForRedirectURLs: String?

        private enum CodingKeys: String, CodingKey {
            case authLoginCustomMessage, authActiveAuthMethods, authOpenIDIssuerURL, authOpenIDAuthorizationURL,
                 authOpenIDTokenURL, authOpenIDUserInfoURL, authOpenIDJwksURL, authOpenIDLogoutURL, authOpenIDClientID,
                 authOpenIDClientSecret, authOpenIDTokenSigningAlgorithm, authOpenIDButtonText, authOpenIDAutoLaunch,
                 authOpenIDAutoRegister, authOpenIDMatchExistingBy, authOpenIDMobileRedirectURIs, authOpenIDGroupClaim,
                 authOpenIDAdvancedPermsClaim, authOpenIDSubfolderForRedirectURLs
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? { try? c.decode(String.self, forKey: key) }
            authLoginCustomMessage = text(.authLoginCustomMessage)
            authActiveAuthMethods = (try? c.decode([String].self, forKey: .authActiveAuthMethods)) ?? ["local"]
            authOpenIDIssuerURL = text(.authOpenIDIssuerURL)
            authOpenIDAuthorizationURL = text(.authOpenIDAuthorizationURL)
            authOpenIDTokenURL = text(.authOpenIDTokenURL)
            authOpenIDUserInfoURL = text(.authOpenIDUserInfoURL)
            authOpenIDJwksURL = text(.authOpenIDJwksURL)
            authOpenIDLogoutURL = text(.authOpenIDLogoutURL)
            authOpenIDClientID = text(.authOpenIDClientID)
            authOpenIDClientSecret = text(.authOpenIDClientSecret)
            authOpenIDTokenSigningAlgorithm = text(.authOpenIDTokenSigningAlgorithm)
            authOpenIDButtonText = text(.authOpenIDButtonText)
            authOpenIDAutoLaunch = (try? c.decode(Bool.self, forKey: .authOpenIDAutoLaunch)) ?? false
            authOpenIDAutoRegister = (try? c.decode(Bool.self, forKey: .authOpenIDAutoRegister)) ?? false
            authOpenIDMatchExistingBy = text(.authOpenIDMatchExistingBy)
            authOpenIDMobileRedirectURIs = (try? c.decode([String].self, forKey: .authOpenIDMobileRedirectURIs)) ?? ["audiobookshelf://oauth"]
            authOpenIDGroupClaim = text(.authOpenIDGroupClaim)
            authOpenIDAdvancedPermsClaim = text(.authOpenIDAdvancedPermsClaim)
            authOpenIDSubfolderForRedirectURLs = text(.authOpenIDSubfolderForRedirectURLs)
        }

        /// Wysyła `null` dla pustych pól (serwer zamienia `""` na `null`), a metody zawsze
        /// z hasłem lokalnym — aplikacja loguje się nim na konto root i słuchacza.
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(authLoginCustomMessage, forKey: .authLoginCustomMessage)
            try c.encode(Self.withLocal(authActiveAuthMethods), forKey: .authActiveAuthMethods)
            try c.encode(authOpenIDIssuerURL, forKey: .authOpenIDIssuerURL)
            try c.encode(authOpenIDAuthorizationURL, forKey: .authOpenIDAuthorizationURL)
            try c.encode(authOpenIDTokenURL, forKey: .authOpenIDTokenURL)
            try c.encode(authOpenIDUserInfoURL, forKey: .authOpenIDUserInfoURL)
            try c.encode(authOpenIDJwksURL, forKey: .authOpenIDJwksURL)
            try c.encode(authOpenIDLogoutURL, forKey: .authOpenIDLogoutURL)
            try c.encode(authOpenIDClientID, forKey: .authOpenIDClientID)
            try c.encode(authOpenIDClientSecret, forKey: .authOpenIDClientSecret)
            try c.encode(authOpenIDTokenSigningAlgorithm, forKey: .authOpenIDTokenSigningAlgorithm)
            try c.encode(authOpenIDButtonText, forKey: .authOpenIDButtonText)
            try c.encode(authOpenIDAutoLaunch, forKey: .authOpenIDAutoLaunch)
            try c.encode(authOpenIDAutoRegister, forKey: .authOpenIDAutoRegister)
            try c.encode(authOpenIDMatchExistingBy, forKey: .authOpenIDMatchExistingBy)
            try c.encode(authOpenIDMobileRedirectURIs, forKey: .authOpenIDMobileRedirectURIs)
            try c.encode(authOpenIDGroupClaim, forKey: .authOpenIDGroupClaim)
            try c.encode(authOpenIDAdvancedPermsClaim, forKey: .authOpenIDAdvancedPermsClaim)
            try c.encode(authOpenIDSubfolderForRedirectURLs ?? "", forKey: .authOpenIDSubfolderForRedirectURLs)
        }

        /// Blokada przed odcięciem aplikacji: hasło lokalne jest zawsze na liście metod.
        static func withLocal(_ methods: [String]) -> [String] {
            methods.contains("local") ? methods : ["local"] + methods
        }
    }

    func authSettings(token: String) async throws -> AuthSettings {
        try decode(AuthSettings.self, from: await send("GET", "api/auth-settings", token: token))
    }

    /// Zapisuje ustawienia logowania. Zwraca, czy serwer coś zmienił.
    func updateAuthSettings(_ settings: AuthSettings, token: String) async throws -> Bool {
        struct Response: Decodable { let updated: Bool }
        return try decode(Response.self, from: await send("PATCH", "api/auth-settings", body: settings, token: token)).updated
    }

    /// Dane wystawcy OpenID (`/.well-known/openid-configuration`) pobrane przez serwer.
    struct OpenIDConfiguration: Decodable, Sendable {
        let issuer: String?
        let authorization_endpoint: String?
        let token_endpoint: String?
        let userinfo_endpoint: String?
        let end_session_endpoint: String?
        let jwks_uri: String?
        let id_token_signing_alg_values_supported: [String]?
    }

    func openIDConfiguration(issuer: String, token: String) async throws -> OpenIDConfiguration {
        try decode(OpenIDConfiguration.self, from: await send("GET", "auth/openid/config", query: [URLQueryItem(name: "issuer", value: issuer)], token: token))
    }
}

private extension String {
    var apiPath: String { "api/" + self }
}
