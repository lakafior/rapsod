import Foundation

/// Mały klient HTTP API serwera audiobookshelf.
///
/// Zależy tylko od Foundation i nie wie nic o procesie serwera, pęku kluczy ani AppKit:
/// adres i dane logowania dostaje z zewnątrz.
/// Endpointy i kształty odpowiedzi pochodzą z upstreamu (v2.38.0): `server/Server.js`
/// (`/status`, `/init`), `server/Auth.js` (`/login`) i `server/controllers/LibraryController.js`.
struct AudiobookshelfClient: Sendable {
    /// Adres serwera razem z `ROUTER_BASE_PATH`, np. `http://127.0.0.1:13378/audiobookshelf`.
    let baseURL: URL
    var session: URLSession = .shared

    // MARK: Modele

    struct Credentials: Codable, Sendable, Equatable {
        var username: String
        var password: String
    }

    struct Status: Decodable, Sendable {
        let serverVersion: String
        /// Czy istnieje konto root.
        let isInit: Bool
    }

    struct Login: Sendable {
        let userID: String
        let username: String
        /// JWT ważny godzinę (`ACCESS_TOKEN_EXPIRY` upstreamu).
        let accessToken: String
        /// Tylko gdy prosiliśmy o niego (`x-return-tokens`); ważny 30 dni, rotowany przy odświeżeniu.
        let refreshToken: String?
    }

    struct User: Decodable, Sendable, Equatable {
        let id: String
        let username: String
        /// `root`, `admin`, `user` albo `guest`.
        let type: String
    }

    struct Library: Decodable, Sendable, Identifiable, Hashable {
        struct Folder: Decodable, Sendable, Hashable {
            let id: String
            let fullPath: String
        }

        let id: String
        let name: String
        let mediaType: String
        let folders: [Folder]
        /// Domyślny dostawca metadanych biblioteki (`google`, `audible`, `custom-<id>`…).
        var provider: String? = nil
    }

    /// Zadanie w tle serwera (`TaskManager` upstreamu), np. skanowanie biblioteki.
    struct ServerTask: Decodable, Sendable {
        struct Payload: Decodable, Sendable {
            let libraryId: String?
        }

        let id: String
        let action: String
        let data: Payload?
        let isFailed: Bool?
        let error: String?
    }

    /// Własny dostawca metadanych (`server/models/CustomMetadataProvider.js`):
    /// upstream odpytuje `GET <url>/search` z nagłówkiem `Authorization: <authHeaderValue>`.
    struct CustomMetadataProvider: Decodable, Sendable, Identifiable, Equatable {
        let id: String
        let name: String
        let url: String
        let mediaType: String
        let authHeaderValue: String?
    }

    enum APIError: LocalizedError {
        case unauthorized
        case rateLimited
        case http(status: Int, message: String)
        case invalidResponse

        var errorDescription: String? {
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

    func status() async throws -> Status {
        try decode(Status.self, from: await send("GET", "status"))
    }

    /// Zakłada konto root na niezainicjalizowanym serwerze (`POST /init`).
    /// Serwer z istniejącym rootem odpowiada 500.
    func initialize(root: Credentials) async throws {
        struct Body: Encodable { let newRoot: Credentials }
        _ = try await send("POST", "init", body: Body(newRoot: root))
    }

    /// Loguje i zakłada nową sesję na serwerze. `returnRefreshToken` prosi o refresh token
    /// w odpowiedzi (jak aplikacje mobilne), zamiast w ciasteczku.
    func login(_ credentials: Credentials, returnRefreshToken: Bool = false) async throws -> Login {
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
    func me(token: String) async throws -> User {
        try decode(User.self, from: await send("GET", "api/me", token: token))
    }

    /// Zakłada zwykłe konto (`type: user`: słuchanie, postęp i pobieranie; bez edycji,
    /// usuwania, uploadu i administracji). Wymaga tokenu administratora.
    /// Zajęta nazwa: HTTP 400. Upstream tworzy konto nieaktywne, jeśli nie podać `isActive`.
    func createUser(_ credentials: Credentials, token: String) async throws -> User {
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

    func libraries(token: String) async throws -> [Library] {
        struct Response: Decodable { let libraries: [Library] }
        return try decode(Response.self, from: await send("GET", "api/libraries", token: token)).libraries
    }

    /// Tworzy bibliotekę z jednym folderem. Serwer jej nie skanuje — zob. `scanLibrary`.
    /// `provider` i `icon` są opcjonalne: bez nich upstream przyjmuje `google` i `database`
    /// (dobre dla książek; biblioteka podcastów potrzebuje `itunes`).
    func createLibrary(
        name: String,
        folderPath: String,
        mediaType: String = "book",
        provider: String? = nil,
        icon: String? = nil,
        token: String
    ) async throws -> Library {
        struct Folder: Encodable { let fullPath: String }
        struct Body: Encodable {
            let name: String
            let folders: [Folder]
            let mediaType: String
            let provider: String?
            let icon: String?
        }
        let body = Body(name: name, folders: [Folder(fullPath: folderPath)], mediaType: mediaType, provider: provider, icon: icon)
        return try decode(Library.self, from: await send("POST", "api/libraries", body: body, token: token))
    }

    /// Ustawia domyślnego dostawcę metadanych biblioteki (`PATCH /api/libraries/:id`).
    /// Upstream zmienia tylko to pole, bez skanu; `custom-<id>` musi istnieć.
    func setLibraryProvider(id: String, provider: String, token: String) async throws {
        struct Body: Encodable { let provider: String }
        _ = try await send("PATCH", "api/libraries/\(id)", body: Body(provider: provider), token: token)
    }

    /// Usuwa bibliotekę z serwera: jej pozycje, postęp słuchania, kolekcje i metadane
    /// w bazie (`LibraryController.delete` upstreamu). Plików audio na dysku nie rusza.
    func deleteLibrary(id: String, token: String) async throws {
        _ = try await send("DELETE", "api/libraries/\(id)", token: token)
    }

    /// Zleca skanowanie; serwer odpowiada od razu, a skan trwa jako zadanie `library-scan`.
    func scanLibrary(id: String, token: String) async throws {
        _ = try await send("POST", "api/libraries/\(id)/scan", token: token)
    }

    func tasks(token: String) async throws -> [ServerTask] {
        struct Response: Decodable { let tasks: [ServerTask] }
        return try decode(Response.self, from: await send("GET", "api/tasks", token: token)).tasks
    }

    func itemCount(libraryID: String, token: String) async throws -> Int {
        struct Response: Decodable { let total: Int }
        let path = "api/libraries/\(libraryID)/items"
        let response = try decode(Response.self, from: await send("GET", path, query: [URLQueryItem(name: "limit", value: "1")], token: token))
        return response.total
    }

    // MARK: Własni dostawcy metadanych (wymagają tokenu administratora)

    // `server/controllers/CustomMetadataProviderController.js`. Upstream nie ma edycji wpisu.

    func customMetadataProviders(token: String) async throws -> [CustomMetadataProvider] {
        struct Response: Decodable { let providers: [CustomMetadataProvider] }
        return try decode(Response.self, from: await send("GET", "api/custom-metadata-providers", token: token)).providers
    }

    func createCustomMetadataProvider(name: String, url: String, mediaType: String, authHeaderValue: String?, token: String) async throws -> CustomMetadataProvider {
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
    func deleteCustomMetadataProvider(id: String, token: String) async throws {
        _ = try await send("DELETE", "api/custom-metadata-providers/\(id)", token: token)
    }

    // MARK: - HTTP

    func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        token: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> Data {
        var url = baseURL.appending(path: path)
        if !query.isEmpty {
            url.append(queryItems: query)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
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

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }
}
