// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mały klient HTTP API serwera audiobookshelf.
///
/// Zależy tylko od Foundation i nie wie nic o procesie serwera, pęku kluczy ani AppKit:
/// adres i dane logowania dostaje z zewnątrz.
/// Endpointy i kształty odpowiedzi pochodzą z upstreamu (v2.38.0): `server/Server.js`
/// (`/status`, `/init`), `server/Auth.js` (`/login`) i `server/controllers/LibraryController.js`.
public struct AudiobookshelfClient: Sendable {
    /// Adres serwera razem z `ROUTER_BASE_PATH`, np. `http://127.0.0.1:13378/audiobookshelf`.
    public let baseURL: URL
    public var session: URLSession = .shared

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: Modele

    public struct Credentials: Codable, Sendable, Equatable {
        public var username: String
        public var password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    public struct Status: Decodable, Sendable {
        public let serverVersion: String
        /// Czy istnieje konto root.
        public let isInit: Bool
    }

    public struct Login: Sendable {
        public let userID: String
        public let username: String
        /// JWT ważny godzinę (`ACCESS_TOKEN_EXPIRY` upstreamu).
        public let accessToken: String
        /// Tylko gdy prosiliśmy o niego (`x-return-tokens`); ważny 30 dni, rotowany przy odświeżeniu.
        public let refreshToken: String?
    }

    public struct User: Decodable, Sendable, Equatable {
        public let id: String
        public let username: String
        /// `root`, `admin`, `user` albo `guest`.
        public let type: String
    }

    public struct Library: Decodable, Sendable, Identifiable, Hashable {
        public struct Folder: Decodable, Sendable, Hashable {
            public let id: String
            public let fullPath: String
        }

        public let id: String
        public let name: String
        public let mediaType: String
        public let folders: [Folder]
        /// Domyślny dostawca metadanych biblioteki (`google`, `audible`, `custom-<id>`…).
        public var provider: String? = nil
    }

    /// Zadanie w tle serwera (`TaskManager` upstreamu), np. skanowanie biblioteki.
    public struct ServerTask: Decodable, Sendable {
        public struct Payload: Decodable, Sendable {
            public let libraryId: String?
            /// Zadania pozycji (`encode-m4b`, `embed-metadata`).
            public let libraryItemId: String?
            /// Wynik skanu albo dopasowania (`LibraryScan.scanResults`), tylko w `task_finished`.
            public let scanResults: ScanResults?
        }

        public struct ScanResults: Decodable, Sendable, Equatable {
            public let added: Int?
            public let updated: Int?
            public let missing: Int?
            /// Milisekundy.
            public let elapsed: Double?
        }

        public let id: String
        public let action: String
        public let data: Payload?
        public let isFailed: Bool?
        public let isFinished: Bool?
        /// Po anulowaniu scalania: `Task canceled by user` (`errorKey` `MessageTaskCanceledByUser`).
        public let error: String?
        public let errorKey: String?
        /// Np. `Task canceled by user` po anulowaniu.
        public let description: String?
    }

    /// Własny dostawca metadanych (`server/models/CustomMetadataProvider.js`):
    /// upstream odpytuje `GET <url>/search` z nagłówkiem `Authorization: <authHeaderValue>`.
    public struct CustomMetadataProvider: Decodable, Sendable, Identifiable, Equatable {
        public let id: String
        public let name: String
        public let url: String
        public let mediaType: String
        public let authHeaderValue: String?
    }

    public enum APIError: LocalizedError {
        case unauthorized
        case rateLimited
        case http(status: Int, message: String)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .unauthorized:
                "Serwer odrzucił dane logowania."
            case .rateLimited:
                "Zbyt wiele prób logowania — serwer chwilowo je blokuje. Spróbuj za kilka minut."
            case let .http(status, message):
                message.isEmpty ? "Serwer zwrócił błąd HTTP \(status)." : "Serwer zwrócił błąd HTTP \(status): \(message)"
            case .invalidResponse:
                "Nieprawidłowa odpowiedź serwera."
            }
        }
    }

    // MARK: Bez uwierzytelnienia

    public func status() async throws -> Status {
        try decode(Status.self, from: await send("GET", "status"))
    }

    /// Zakłada konto root na niezainicjalizowanym serwerze (`POST /init`).
    /// Serwer z istniejącym rootem odpowiada 500.
    public func initialize(root: Credentials) async throws {
        struct Body: Encodable { let newRoot: Credentials }
        _ = try await send("POST", "init", body: Body(newRoot: root))
    }

    /// Loguje i zakłada nową sesję na serwerze. `returnRefreshToken` prosi o refresh token
    /// w odpowiedzi (jak aplikacje mobilne), zamiast w ciasteczku.
    public func login(_ credentials: Credentials, returnRefreshToken: Bool = false) async throws -> Login {
        struct Response: Decodable {
            struct User: Decodable {
                let id: String
                let username: String
                let accessToken: String
                let refreshToken: String?
            }
            let user: User
        }
        let headers = returnRefreshToken ? ["x-return-tokens": "true"] : [:]
        let response = try decode(Response.self, from: await send("POST", "login", body: credentials, headers: headers))
        return Login(
            userID: response.user.id,
            username: response.user.username,
            accessToken: response.user.accessToken,
            refreshToken: response.user.refreshToken
        )
    }

    // MARK: Użytkownicy

    /// Użytkownik, do którego należy token.
    /// `timeout` — limit czasu tego zapytania. Limit z `URLRequest` wygrywa z limitem sesji,
    /// więc sprawdzanie adresów (telefon: sieć lokalna → tunel) musi podać go tutaj; inaczej
    /// nieosiągalny adres lokalny blokował przejście na tunel przez pełne 30 s.
    public func me(token: String, timeout: TimeInterval = 30) async throws -> User {
        try decode(User.self, from: await send("GET", "api/me", token: token, timeout: timeout))
    }

    /// Zakłada zwykłe konto (`type: user`: słuchanie, postęp i pobieranie; bez edycji,
    /// usuwania, uploadu i administracji). Wymaga tokenu administratora.
    /// Zajęta nazwa: HTTP 400. Upstream tworzy konto nieaktywne, jeśli nie podać `isActive`.
    public func createUser(_ credentials: Credentials, token: String) async throws -> User {
        struct Body: Encodable {
            let username: String
            let password: String
            let type = "user"
            let isActive = true
        }
        struct Response: Decodable { let user: User }
        let body = Body(username: credentials.username, password: credentials.password)
        return try decode(Response.self, from: await send("POST", "api/users", body: body, token: token)).user
    }

    // MARK: Biblioteki (wymagają tokenu administratora)

    public func libraries(token: String) async throws -> [Library] {
        struct Response: Decodable { let libraries: [Library] }
        return try decode(Response.self, from: await send("GET", "api/libraries", token: token)).libraries
    }

    /// Tworzy bibliotekę z jednym folderem. Serwer jej nie skanuje — zob. `scanLibrary`.
    /// `provider` i `icon` są opcjonalne: bez nich upstream przyjmuje `google` i `database`
    /// (dobre dla książek; biblioteka podcastów potrzebuje `itunes`).
    public func createLibrary(
        name: String,
        folderPath: String,
        mediaType: String = "book",
        provider: String? = nil,
        icon: String? = nil,
        token: String
    ) async throws -> Library {
        struct Folder: Encodable { let fullPath: String }
        struct Settings: Encodable { let podcastSearchRegion: String }
        struct Body: Encodable {
            let name: String
            let folders: [Folder]
            let mediaType: String
            let provider: String?
            let icon: String?
            /// Biblioteka podcastów szuka domyślnie w polskim sklepie iTunes (upstream: `us`); zmiana
            /// w ustawieniach biblioteki (etap 9g).
            let settings: Settings?
        }
        let body = Body(name: name, folders: [Folder(fullPath: folderPath)], mediaType: mediaType, provider: provider, icon: icon,
                        settings: mediaType == "podcast" ? Settings(podcastSearchRegion: "pl") : nil)
        return try decode(Library.self, from: await send("POST", "api/libraries", body: body, token: token))
    }

    /// Ustawia domyślnego dostawcę metadanych biblioteki (`PATCH /api/libraries/:id`).
    /// Upstream zmienia tylko to pole, bez skanu; `custom-<id>` musi istnieć.
    public func setLibraryProvider(id: String, provider: String, token: String) async throws {
        struct Body: Encodable { let provider: String }
        _ = try await send("PATCH", "api/libraries/\(id)", body: Body(provider: provider), token: token)
    }

    /// Usuwa bibliotekę z serwera: jej pozycje, postęp słuchania, kolekcje i metadane
    /// w bazie (`LibraryController.delete` upstreamu). Plików audio na dysku nie rusza.
    public func deleteLibrary(id: String, token: String) async throws {
        _ = try await send("DELETE", "api/libraries/\(id)", token: token)
    }

    /// Zleca skanowanie; serwer odpowiada od razu, a skan trwa jako zadanie `library-scan`.
    public func scanLibrary(id: String, token: String) async throws {
        _ = try await send("POST", "api/libraries/\(id)/scan", token: token)
    }

    public func tasks(token: String) async throws -> [ServerTask] {
        struct Response: Decodable { let tasks: [ServerTask] }
        return try decode(Response.self, from: await send("GET", "api/tasks", token: token)).tasks
    }

    public func itemCount(libraryID: String, token: String) async throws -> Int {
        struct Response: Decodable { let total: Int }
        let path = "api/libraries/\(libraryID)/items"
        let response = try decode(Response.self, from: await send("GET", path, query: [URLQueryItem(name: "limit", value: "1")], token: token))
        return response.total
    }

    // MARK: Własni dostawcy metadanych (wymagają tokenu administratora)

    // `server/controllers/CustomMetadataProviderController.js`. Upstream nie ma edycji wpisu.

    public func customMetadataProviders(token: String) async throws -> [CustomMetadataProvider] {
        struct Response: Decodable { let providers: [CustomMetadataProvider] }
        return try decode(Response.self, from: await send("GET", "api/custom-metadata-providers", token: token)).providers
    }

    public func createCustomMetadataProvider(name: String, url: String, mediaType: String, authHeaderValue: String?, token: String) async throws -> CustomMetadataProvider {
        struct Body: Encodable {
            let name: String
            let url: String
            let mediaType: String
            let authHeaderValue: String?
        }
        struct Response: Decodable { let provider: CustomMetadataProvider }
        let body = Body(name: name, url: url, mediaType: mediaType, authHeaderValue: authHeaderValue)
        return try decode(Response.self, from: await send("POST", "api/custom-metadata-providers", body: body, token: token)).provider
    }

    /// Usuwa wpis. Biblioteki, które miały go jako domyślnego dostawcę, upstream
    /// przestawia na `google`.
    public func deleteCustomMetadataProvider(id: String, token: String) async throws {
        _ = try await send("DELETE", "api/custom-metadata-providers/\(id)", token: token)
    }

    // MARK: - HTTP

    public func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        token: String? = nil,
        headers: [String: String] = [:],
        timeout: TimeInterval = 30
    ) async throws -> Data {
        var url = baseURL.appending(path: path)
        if !query.isEmpty {
            url.append(queryItems: query)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return try await execute(request)
    }

    /// Wysyła gotowe zapytanie i zamienia status HTTP na `APIError`
    /// (wspólne dla JSON i np. wysyłania plików w `multipart/form-data`).
    public func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw APIError.unauthorized
        case 429:
            throw APIError.rateLimited
        default:
            let message = String(decoding: data.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw APIError.http(status: http.statusCode, message: message)
        }
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }
}
