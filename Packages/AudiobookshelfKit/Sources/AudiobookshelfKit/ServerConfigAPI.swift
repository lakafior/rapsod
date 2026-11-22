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
    public struct ServerSettings: Decodable, Sendable, Equatable {
        public var scannerParseSubtitle = false
        public var scannerFindCovers = false
        public var scannerCoverProvider = "google"
        public var scannerPreferMatchedMetadata = false
        public var scannerDisableWatcher = false
        public var storeCoverWithItem = false
        public var storeMetadataWithItem = false
        public var sortingIgnorePrefix = false
        public var sortingPrefixes = ["the", "a"]
        public var language = "en-us"
        /// `LogLevel` z `server/utils/constants.js`: 0 trace, 1 debug, 2 info, 3 warn, 4 error.
        public var logLevel = 2
        public var authActiveAuthMethods = ["local"]

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case scannerParseSubtitle, scannerFindCovers, scannerCoverProvider, scannerPreferMatchedMetadata,
                 scannerDisableWatcher, storeCoverWithItem, storeMetadataWithItem, sortingIgnorePrefix,
                 sortingPrefixes, language, logLevel, authActiveAuthMethods
        }

        public init(from decoder: any Decoder) throws {
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
    public struct ServerSettingsChanges: Encodable, Sendable {
        public var scannerParseSubtitle: Bool?
        public var scannerFindCovers: Bool?
        public var scannerCoverProvider: String?
        public var scannerPreferMatchedMetadata: Bool?
        public var scannerDisableWatcher: Bool?
        public var storeCoverWithItem: Bool?
        public var storeMetadataWithItem: Bool?
        public var sortingIgnorePrefix: Bool?
        public var language: String?
        public var logLevel: Int?

        /// Różnica między stanem serwera a szkicem.
        public init(from old: ServerSettings, to new: ServerSettings) {
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

        public var isEmpty: Bool {
            [scannerParseSubtitle, scannerFindCovers, scannerPreferMatchedMetadata, scannerDisableWatcher,
             storeCoverWithItem, storeMetadataWithItem, sortingIgnorePrefix].allSatisfy { $0 == nil }
                && scannerCoverProvider == nil && language == nil && logLevel == nil
        }
    }

    /// Ustawienia serwera z `POST /api/authorize` (upstream nie ma `GET /api/settings`).
    public func serverSettings(token: String) async throws -> ServerSettings {
        struct Response: Decodable { let serverSettings: ServerSettings }
        return try decode(Response.self, from: await send("POST", "api/authorize", token: token)).serverSettings
    }

    @discardableResult
    public func updateServerSettings(_ changes: ServerSettingsChanges, token: String) async throws -> ServerSettings {
        struct Response: Decodable { let serverSettings: ServerSettings }
        return try decode(Response.self, from: await send("PATCH", "api/settings", body: changes, token: token)).serverSettings
    }

    /// Przedrostki pomijane przy sortowaniu; serwer przelicza od razu tytuły książek i podcastów.
    public func updateSortingPrefixes(_ prefixes: [String], token: String) async throws {
        struct Body: Encodable { let sortingPrefixes: [String] }
        _ = try await send("PATCH", "api/sorting-prefixes", body: Body(sortingPrefixes: prefixes), token: token, timeout: 300)
    }

    /// Czyści całą pamięć podręczną (`metadata/cache`) albo tylko okładki pozycji (`cache/items`).
    public func purgeCache(itemsOnly: Bool, token: String) async throws {
        _ = try await send("POST", itemsOnly ? "api/cache/items/purge" : "api/cache/purge", token: token, timeout: 300)
    }

    // MARK: Klucze API

    public struct UserRef: Decodable, Sendable, Hashable {
        public let id: String
        public let username: String
        public let type: String?
    }

    /// Klucz API (`models/ApiKey.js`, `toJSON`). Sam klucz serwer zwraca tylko przy utworzeniu.
    public struct ApiKey: Decodable, Sendable, Identifiable, Hashable {
        public let id: String
        public let name: String
        public let description: String?
        public let expiresAt: Date?
        /// Upstream v2.38.0 ma kolumnę, ale jej nie uzupełnia — zwykle `nil`.
        public let lastUsedAt: Date?
        public let isActive: Bool
        public let userId: String?
        public let user: UserRef?
        public let createdByUserId: String?
        public let createdAt: Date?

        public var isExpired: Bool { expiresAt.map { $0 < .now } ?? false }

        private enum CodingKeys: String, CodingKey {
            case id, name, description, expiresAt, lastUsedAt, isActive, userId, user, createdByUserId, createdAt
        }

        public init(from decoder: any Decoder) throws {
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

    public func apiKeys(token: String) async throws -> [ApiKey] {
        struct Response: Decodable { let apiKeys: [ApiKey] }
        return try decode(Response.self, from: await send("GET", "api-keys".apiPath, token: token)).apiKeys
    }

    /// Nowy klucz i jego treść (pokazywana raz). `expiresIn` w sekundach; `nil` = bez wygasania.
    public func createApiKey(name: String, userID: String, expiresIn: Int?, isActive: Bool, token: String) async throws -> (key: ApiKey, secret: String) {
        struct Body: Encodable { let name: String; let userId: String; let expiresIn: Int?; let isActive: Bool }
        struct Created: Decodable { let apiKey: String }
        struct Response: Decodable { let apiKey: ApiKey }
        struct SecretResponse: Decodable { let apiKey: Created }
        let data = try await send("POST", "api-keys".apiPath, body: Body(name: name, userId: userID, expiresIn: expiresIn, isActive: isActive), token: token)
        return (try decode(Response.self, from: data).apiKey, try decode(SecretResponse.self, from: data).apiKey.apiKey)
    }

    public func updateApiKey(id: String, isActive: Bool, token: String) async throws -> ApiKey {
        struct Body: Encodable { let isActive: Bool }
        struct Response: Decodable { let apiKey: ApiKey }
        return try decode(Response.self, from: await send("PATCH", "api-keys/\(id)".apiPath, body: Body(isActive: isActive), token: token)).apiKey
    }

    public func deleteApiKey(id: String, token: String) async throws {
        _ = try await send("DELETE", "api-keys/\(id)".apiPath, token: token)
    }

    // MARK: Sesje słuchania

    public struct SessionDevice: Decodable, Sendable, Hashable {
        public let deviceId: String?
        public let clientName: String?
        public let clientVersion: String?
        public let deviceName: String?
        public let osName: String?
        public let osVersion: String?
        public let browserName: String?
        public let model: String?
        public let manufacturer: String?
        public let ipAddress: String?

        public var summary: String {
            let device = deviceName ?? [manufacturer, model].compactMap { $0 }.joined(separator: " ")
            let client = [clientName, clientVersion].compactMap { $0 }.joined(separator: " ")
            let system = [osName, osVersion].compactMap { $0 }.joined(separator: " ")
            return [client, device, browserName ?? "", system].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    /// Sesja odtwarzania (`objects/PlaybackSession.js`, `toJSON`), z użytkownikiem dołączonym przez serwer.
    public struct ListeningSession: Decodable, Sendable, Identifiable, Hashable {
        public let id: String
        public let userId: String?
        public let libraryItemId: String?
        public let episodeId: String?
        public let mediaType: String?
        public let displayTitle: String?
        public let displayAuthor: String?
        public let duration: Double?
        /// 0 bezpośrednio, 1 strumień, 2 transkodowanie, 3 lokalnie (`PlayMethod`).
        public let playMethod: Int?
        public let mediaPlayer: String?
        public let deviceInfo: SessionDevice?
        public let serverVersion: String?
        public let date: String?
        public let timeListening: Double?
        public let startTime: Double?
        public let currentTime: Double?
        /// Milisekundy od 1970.
        public let startedAt: Double?
        public let updatedAt: Double?
        public let user: UserRef?

        public var started: Date? { startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
        public var updated: Date? { updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

        public var playMethodText: String {
            switch playMethod {
            case 0: "bezpośrednio"
            case 1: "strumień"
            case 2: "transkodowanie"
            case 3: "lokalnie (pobrane)"
            default: "—"
            }
        }
    }

    public struct SessionPage: Decodable, Sendable {
        public let total: Int
        public let numPages: Int
        public let page: Int
        public let itemsPerPage: Int
        public let sessions: [ListeningSession]
    }

    /// Historia sesji z bazy, od najnowszych (`GET /api/sessions`).
    public func sessions(userID: String?, page: Int, perPage: Int, token: String) async throws -> SessionPage {
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
    public func openSessions(token: String) async throws -> [ListeningSession] {
        struct Response: Decodable { let sessions: [ListeningSession] }
        return try decode(Response.self, from: await send("GET", "api/sessions/open", token: token)).sessions
    }

    /// Zamyka otwartą sesję (zapisuje ją w historii); administrator może zamknąć cudzą.
    public func closeSession(id: String, token: String) async throws {
        _ = try await send("POST", "api/session/\(id)/close", token: token)
    }

    /// Usuwa sesje z historii; otwarte są najpierw zamykane bez zapisu.
    public func deleteSessions(ids: [String], token: String) async throws {
        struct Body: Encodable { let sessions: [String] }
        _ = try await send("POST", "api/sessions/batch/delete", body: Body(sessions: ids), token: token)
    }

    // MARK: Kanały RSS

    public struct FeedMeta: Decodable, Sendable, Hashable {
        public let title: String?
        public let author: String?
        public let preventIndexing: Bool?
        public let ownerName: String?
        public let ownerEmail: String?
    }

    /// Otwarty kanał (`models/Feed.js`, `toOldJSON` / `toOldJSONMinified`).
    public struct Feed: Decodable, Sendable, Identifiable, Hashable {
        public let id: String
        public let slug: String?
        public let entityType: String?
        public let entityId: String?
        public let feedUrl: String?
        public let serverAddress: String?
        public let meta: FeedMeta?
        public let createdAt: Double?

        /// Pełny adres kanału (`feedUrl` jest względny: `/feed/<slug>`).
        public var url: URL? {
            guard let feedUrl else { return nil }
            if feedUrl.hasPrefix("http") { return URL(string: feedUrl) }
            return URL(string: (serverAddress ?? "") + feedUrl)
        }

        public var entityText: String {
            switch entityType {
            case "libraryItem": "pozycja"
            case "collection": "kolekcja"
            case "series": "seria"
            default: entityType ?? "—"
            }
        }
    }

    public func feeds(token: String) async throws -> [Feed] {
        struct Response: Decodable { let feeds: [Feed] }
        return try decode(Response.self, from: await send("GET", "api/feeds", token: token)).feeds
    }

    public struct FeedOptions: Encodable, Sendable {
        public struct Details: Encodable, Sendable {
            public var preventIndexing = true
            public var ownerName: String?
            public var ownerEmail: String?

            public init(preventIndexing: Bool = true, ownerName: String? = nil, ownerEmail: String? = nil) {
                self.preventIndexing = preventIndexing
                self.ownerName = ownerName
                self.ownerEmail = ownerEmail
            }
        }
        public let serverAddress: String
        public let slug: String
        public var metadataDetails = Details()

        public init(serverAddress: String, slug: String, metadataDetails: Details = Details()) {
            self.serverAddress = serverAddress
            self.slug = slug
            self.metadataDetails = metadataDetails
        }
    }

    /// Otwiera kanał dla pozycji z audio. Zajęty `slug`: HTTP 400 „Slug already in use”.
    public func openFeed(itemID: String, options: FeedOptions, token: String) async throws -> Feed {
        try await openFeed(path: "api/feeds/item/\(itemID)/open", options: options, token: token)
    }

    /// Kanał dla serii albo kolekcji (etap 9g): `POST /api/feeds/series|collection/:id/open`.
    public func openFeed(path: String, options: FeedOptions, token: String) async throws -> Feed {
        struct Response: Decodable { let feed: Feed }
        return try decode(Response.self, from: await send("POST", path, body: options, token: token)).feed
    }

    public func closeFeed(id: String, token: String) async throws {
        _ = try await send("POST", "api/feeds/\(id)/close", token: token)
    }

    // MARK: Powiadomienia (Apprise)

    public struct NotificationEvent: Decodable, Sendable, Hashable, Identifiable {
        public struct Defaults: Decodable, Sendable, Hashable {
            public let title: String?
            public let body: String?
        }
        public let name: String
        public let requiresLibrary: Bool?
        public let libraryMediaType: String?
        public let description: String?
        public let variables: [String]?
        public let defaults: Defaults?
        public var id: String { name }
    }

    public struct NotificationData: Decodable, Sendable {
        public let events: [NotificationEvent]
    }

    /// Powiadomienie (`objects/Notification.js`).
    public struct AppNotification: Codable, Sendable, Identifiable, Hashable {
        public var id: String
        public var libraryId: String?
        public var eventName: String
        public var urls: [String]
        public var titleTemplate: String
        public var bodyTemplate: String
        public var enabled: Bool
        public var type: String?
        public var lastFiredAt: Double?
        public var lastAttemptFailed: Bool?
        public var numConsecutiveFailedAttempts: Int?
        public var numTimesFired: Int?
        public var createdAt: Double?
    }

    public struct NotificationSettings: Decodable, Sendable, Equatable {
        public var appriseApiUrl: String?
        public var notifications: [AppNotification]
        public var maxFailedAttempts: Int
        public var maxNotificationQueue: Int
    }

    public func notifications(token: String) async throws -> (data: NotificationData, settings: NotificationSettings) {
        struct Response: Decodable { let data: NotificationData; let settings: NotificationSettings }
        let response = try decode(Response.self, from: await send("GET", "api/notifications", token: token))
        return (response.data, response.settings)
    }

    public func updateNotificationSettings(appriseApiUrl: String?, maxFailedAttempts: Int, maxNotificationQueue: Int, token: String) async throws {
        struct Body: Encodable { let appriseApiUrl: String?; let maxFailedAttempts: Int; let maxNotificationQueue: Int }
        _ = try await send("PATCH", "api/notifications", body: Body(appriseApiUrl: appriseApiUrl, maxFailedAttempts: maxFailedAttempts, maxNotificationQueue: maxNotificationQueue), token: token)
    }

    /// Pola wysyłane przy tworzeniu i zmianie powiadomienia (jak `NotificationEditModal.vue`).
    public struct NotificationChanges: Encodable, Sendable {
        /// Przy zmianie: `NotificationSettings.updateNotification` szuka powiadomienia po `id`
        /// z treści żądania, nie z adresu.
        public var id: String?
        public var libraryId: String?
        public var eventName: String
        public var urls: [String]
        public var titleTemplate: String
        public var bodyTemplate: String
        public var enabled: Bool
        public var type: String?

        public init(id: String? = nil, libraryId: String? = nil, eventName: String, urls: [String], titleTemplate: String, bodyTemplate: String, enabled: Bool, type: String? = nil) {
            self.id = id
            self.libraryId = libraryId
            self.eventName = eventName
            self.urls = urls
            self.titleTemplate = titleTemplate
            self.bodyTemplate = bodyTemplate
            self.enabled = enabled
            self.type = type
        }
    }

    public func createNotification(_ changes: NotificationChanges, token: String) async throws -> NotificationSettings {
        try decode(NotificationSettings.self, from: await send("POST", "api/notifications", body: changes, token: token))
    }

    public func updateNotification(id: String, _ changes: NotificationChanges, token: String) async throws -> NotificationSettings {
        var changes = changes
        changes.id = id
        return try decode(NotificationSettings.self, from: await send("PATCH", "api/notifications/\(id)", body: changes, token: token))
    }

    public func deleteNotification(id: String, token: String) async throws -> NotificationSettings {
        try decode(NotificationSettings.self, from: await send("DELETE", "api/notifications/\(id)", token: token))
    }

    /// Wysyła próbne powiadomienie na adresy tego powiadomienia (przez serwer Apprise).
    public func testNotification(id: String, token: String) async throws {
        _ = try await send("GET", "api/notifications/\(id)/test", token: token, timeout: 60)
    }

    // MARK: E-mail (SMTP) i czytniki

    public struct EreaderDevice: Codable, Sendable, Hashable, Identifiable {
        public var name: String
        public var email: String
        /// `adminOrUp`, `userOrUp`, `guestOrUp` albo `specificUsers`.
        public var availabilityOption: String
        public var users: [String]
        public var id: String { name }

        public init(name: String = "", email: String = "", availabilityOption: String = "adminOrUp", users: [String] = []) {
            self.name = name
            self.email = email
            self.availabilityOption = availabilityOption
            self.users = users
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
            email = (try? c.decode(String.self, forKey: .email)) ?? ""
            availabilityOption = (try? c.decode(String.self, forKey: .availabilityOption)) ?? "adminOrUp"
            users = (try? c.decode([String].self, forKey: .users)) ?? []
        }
    }

    /// Ustawienia poczty (`objects/settings/EmailSettings.js`). Hasło serwer trzyma u siebie;
    /// aplikacja pokazuje je tylko w zamaskowanym polu i nigdy nie loguje.
    public struct EmailSettings: Codable, Sendable, Equatable {
        public var host: String?
        public var port: Int
        public var secure: Bool
        public var rejectUnauthorized: Bool
        public var user: String?
        public var pass: String?
        public var testAddress: String?
        public var fromAddress: String?
        public var ereaderDevices: [EreaderDevice]

        private enum CodingKeys: String, CodingKey {
            case host, port, secure, rejectUnauthorized, user, pass, testAddress, fromAddress, ereaderDevices
        }

        public init(from decoder: any Decoder) throws {
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
        public func encode(to encoder: any Encoder) throws {
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

    public func emailSettings(token: String) async throws -> EmailSettings {
        struct Response: Decodable { let settings: EmailSettings }
        return try decode(Response.self, from: await send("GET", "api/emails/settings", token: token)).settings
    }

    public func updateEmailSettings(_ settings: EmailSettings, token: String) async throws -> EmailSettings {
        struct Response: Decodable { let settings: EmailSettings }
        return try decode(Response.self, from: await send("PATCH", "api/emails/settings", body: settings, token: token)).settings
    }

    /// Próbny e-mail na `testAddress` (zapisany na serwerze).
    public func sendTestEmail(token: String) async throws {
        _ = try await send("POST", "api/emails/test", token: token, timeout: 90)
    }

    public func updateEreaderDevices(_ devices: [EreaderDevice], token: String) async throws -> [EreaderDevice] {
        struct Body: Encodable { let ereaderDevices: [EreaderDevice] }
        struct Response: Decodable { let ereaderDevices: [EreaderDevice] }
        return try decode(Response.self, from: await send("POST", "api/emails/ereader-devices", body: Body(ereaderDevices: devices), token: token)).ereaderDevices
    }

    /// Wysyła e-book pozycji e-mailem na czytnik (`POST /api/emails/send-ebook-to-device`).
    public func sendEbook(itemID: String, deviceName: String, token: String) async throws {
        struct Body: Encodable { let libraryItemId: String; let deviceName: String }
        _ = try await send("POST", "api/emails/send-ebook-to-device", body: Body(libraryItemId: itemID, deviceName: deviceName), token: token, timeout: 120)
    }

    // MARK: Logowanie (hasło lokalne / OpenID Connect)

    /// `ServerSettings.authenticationSettings`. Sekret klienta przychodzi z serwera i wraca
    /// do niego bez zmian; aplikacja pokazuje go tylko w zamaskowanym polu.
    public struct AuthSettings: Codable, Sendable, Equatable {
        public var authLoginCustomMessage: String?
        public var authActiveAuthMethods: [String]
        public var authOpenIDIssuerURL: String?
        public var authOpenIDAuthorizationURL: String?
        public var authOpenIDTokenURL: String?
        public var authOpenIDUserInfoURL: String?
        public var authOpenIDJwksURL: String?
        public var authOpenIDLogoutURL: String?
        public var authOpenIDClientID: String?
        public var authOpenIDClientSecret: String?
        public var authOpenIDTokenSigningAlgorithm: String?
        public var authOpenIDButtonText: String?
        public var authOpenIDAutoLaunch: Bool
        public var authOpenIDAutoRegister: Bool
        /// `nil`, `email` albo `username`.
        public var authOpenIDMatchExistingBy: String?
        public var authOpenIDMobileRedirectURIs: [String]
        public var authOpenIDGroupClaim: String?
        public var authOpenIDAdvancedPermsClaim: String?
        public var authOpenIDSubfolderForRedirectURLs: String?

        private enum CodingKeys: String, CodingKey {
            case authLoginCustomMessage, authActiveAuthMethods, authOpenIDIssuerURL, authOpenIDAuthorizationURL,
                 authOpenIDTokenURL, authOpenIDUserInfoURL, authOpenIDJwksURL, authOpenIDLogoutURL, authOpenIDClientID,
                 authOpenIDClientSecret, authOpenIDTokenSigningAlgorithm, authOpenIDButtonText, authOpenIDAutoLaunch,
                 authOpenIDAutoRegister, authOpenIDMatchExistingBy, authOpenIDMobileRedirectURIs, authOpenIDGroupClaim,
                 authOpenIDAdvancedPermsClaim, authOpenIDSubfolderForRedirectURLs
        }

        public init(from decoder: any Decoder) throws {
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
        public func encode(to encoder: any Encoder) throws {
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
            // Brak klucza web UI traktuje jak `ROUTER_BASE_PATH` (`authentication.vue`); pusty napis to „bez podfolderu”.
            try c.encodeIfPresent(authOpenIDSubfolderForRedirectURLs, forKey: .authOpenIDSubfolderForRedirectURLs)
        }

        /// Blokada przed odcięciem aplikacji: hasło lokalne jest zawsze na liście metod.
        public static func withLocal(_ methods: [String]) -> [String] {
            methods.contains("local") ? methods : ["local"] + methods
        }
    }

    public func authSettings(token: String) async throws -> AuthSettings {
        try decode(AuthSettings.self, from: await send("GET", "api/auth-settings", token: token))
    }

    /// Zapisuje ustawienia logowania. Zwraca, czy serwer coś zmienił.
    public func updateAuthSettings(_ settings: AuthSettings, token: String) async throws -> Bool {
        struct Response: Decodable { let updated: Bool }
        return try decode(Response.self, from: await send("PATCH", "api/auth-settings", body: settings, token: token)).updated
    }

    /// Dane wystawcy OpenID (`/.well-known/openid-configuration`) pobrane przez serwer.
    public struct OpenIDConfiguration: Decodable, Sendable {
        public let issuer: String?
        public let authorization_endpoint: String?
        public let token_endpoint: String?
        public let userinfo_endpoint: String?
        public let end_session_endpoint: String?
        public let jwks_uri: String?
        public let id_token_signing_alg_values_supported: [String]?
    }

    public func openIDConfiguration(issuer: String, token: String) async throws -> OpenIDConfiguration {
        try decode(OpenIDConfiguration.self, from: await send("GET", "auth/openid/config", query: [URLQueryItem(name: "issuer", value: issuer)], token: token))
    }
}

private extension String {
    var apiPath: String { "api/" + self }
}
