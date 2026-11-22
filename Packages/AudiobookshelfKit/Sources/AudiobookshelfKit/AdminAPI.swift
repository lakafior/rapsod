import Foundation

/// Punkty API administracji serwerem (etap 9c): kopie zapasowe, ustawienia automatu kopii,
/// użytkownicy, skan i dopasowanie całej biblioteki. Wszystkie wymagają tokenu root
/// (`ServerAccount.withAdminToken`). Kształty z upstreamu v2.38.0:
/// `server/controllers/BackupController.js`, `MiscController.js` (`/settings`, `/authorize`, `/tags`),
/// `UserController.js` i `LibraryController.js` (`scan`, `matchall`).
extension AudiobookshelfClient {
    // MARK: Kopie zapasowe

    /// Kopia zapasowa (`server/objects/Backup.js`, `toJSON`).
    public struct Backup: Decodable, Sendable, Identifiable, Hashable {
        public let id: String
        public let filename: String
        public let fullPath: String
        public let fileSize: Int64?
        /// Milisekundy od 1970.
        public let createdAt: Double?
        public let serverVersion: String?

        public var date: Date? { createdAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
    }

    public struct BackupList: Decodable, Sendable {
        public let backups: [Backup]
        /// Folder kopii (`backupPath` z ustawień serwera).
        public let backupLocation: String?
        /// Ścieżka ustawiona zmienną `BACKUP_PATH` — wtedy nie da się jej zmienić z API.
        public let backupPathEnvSet: Bool?
    }

    public func backups(token: String) async throws -> BackupList {
        try decode(BackupList.self, from: await send("GET", "api/backups", token: token))
    }

    /// Tworzy kopię; serwer odpowiada dopiero po spakowaniu (stąd długi limit czasu).
    /// Porażka to goły HTTP 500 — najczęściej przekroczony limit rozmiaru kopii.
    public func createBackup(token: String) async throws -> [Backup] {
        struct Response: Decodable { let backups: [Backup] }
        return try decode(Response.self, from: await send("POST", "api/backups", token: token, timeout: 900)).backups
    }

    public func deleteBackup(id: String, token: String) async throws {
        _ = try await send("DELETE", "api/backups/\(id)", token: token)
    }

    /// Przywraca kopię: serwer zamyka bazę, podmienia ją i metadane pozycji oraz autorów
    /// i odpowiada po zakończeniu. Wszyscy klienci dostają `backup_applied`.
    public func applyBackup(id: String, token: String) async throws {
        _ = try await send("GET", "api/backups/\(id)/apply", token: token, timeout: 900)
    }

    /// Wgrywa plik `.audiobookshelf` do folderu kopii (pole `file` w `multipart/form-data`,
    /// jak `BackupUploader.vue`). Treść jest składana w pliku tymczasowym, nie w pamięci.
    public func uploadBackup(file: URL, token: String) async throws -> [Backup] {
        struct Response: Decodable { let backups: [Backup] }
        let boundary = "AudiobookSwift-\(UUID().uuidString)"
        let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "")
        let body = FileManager.default.temporaryDirectory.appending(path: "backup-upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: body.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: body) }

        let output = try FileHandle(forWritingTo: body)
        do {
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try output.close()
        } catch {
            try? output.close()
            throw error
        }

        var request = URLRequest(url: baseURL.appending(path: "api/backups/upload"))
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, fromFile: body)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            return try decode(Response.self, from: data).backups
        case 401:
            throw APIError.unauthorized
        default:
            let message = String(decoding: data.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw APIError.http(status: http.statusCode, message: message)
        }
    }

    /// Zmienia folder kopii (`PATCH /api/backups/path`); serwer tworzy go, jeśli nie istnieje,
    /// i wczytuje kopie z nowego miejsca.
    public func setBackupPath(_ path: String, token: String) async throws {
        struct Body: Encodable { let path: String }
        _ = try await send("PATCH", "api/backups/path", body: Body(path: path), token: token)
    }

    // MARK: Ustawienia serwera (automat kopii)

    /// Harmonogram kopii: `false` (wyłączony) albo wyrażenie cron.
    public enum BackupSchedule: Codable, Sendable, Equatable {
        case disabled
        case cron(String)

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self), !text.isEmpty {
                self = .cron(text)
            } else {
                self = .disabled
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .disabled: try container.encode(false)
            case .cron(let expression): try container.encode(expression)
            }
        }
    }

    /// Ustawienia kopii z `serverSettings` (`server/objects/settings/ServerSettings.js`).
    public struct BackupSettings: Decodable, Sendable, Equatable {
        public var backupSchedule: BackupSchedule
        public var backupsToKeep: Int
        /// GB; 0 = bez limitu.
        public var maxBackupSize: Double
        public var backupPath: String?

        private enum CodingKeys: String, CodingKey { case backupSchedule, backupsToKeep, maxBackupSize, backupPath }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            backupSchedule = (try? container.decode(BackupSchedule.self, forKey: .backupSchedule)) ?? .disabled
            backupsToKeep = (try? container.decode(Int.self, forKey: .backupsToKeep)) ?? 2
            maxBackupSize = (try? container.decode(Double.self, forKey: .maxBackupSize)) ?? 1
            backupPath = try? container.decode(String.self, forKey: .backupPath)
        }
    }

    /// Ustawienia serwera bez `GET /api/settings` (upstream go nie ma): `POST /api/authorize`
    /// zwraca je razem z użytkownikiem tokenu — i nie przechodzi przez ogranicznik `/login`.
    public func backupSettings(token: String) async throws -> BackupSettings {
        struct Response: Decodable { let serverSettings: BackupSettings }
        return try decode(Response.self, from: await send("POST", "api/authorize", token: token)).serverSettings
    }

    /// Zmienia tylko podane pola ustawień kopii (`PATCH /api/settings`).
    public func updateBackupSettings(schedule: BackupSchedule?, backupsToKeep: Int?, maxBackupSize: Double?, token: String) async throws {
        struct Body: Encodable {
            let backupSchedule: BackupSchedule?
            let backupsToKeep: Int?
            let maxBackupSize: Double?
        }
        _ = try await send("PATCH", "api/settings", body: Body(backupSchedule: schedule, backupsToKeep: backupsToKeep, maxBackupSize: maxBackupSize), token: token)
    }

    // MARK: Biblioteki: skan i dopasowanie

    /// Zleca skan; `force` (`?force=1`) skanuje ponownie także niezmienione pozycje.
    public func scanLibrary(id: String, force: Bool, token: String) async throws {
        let query = force ? [URLQueryItem(name: "force", value: "1")] : []
        _ = try await send("POST", "api/libraries/\(id)/scan", query: query, token: token)
    }

    /// Szybkie dopasowanie wszystkich książek biblioteki (zadanie `library-match-all`).
    public func matchAllItems(libraryID: String, token: String) async throws {
        _ = try await send("GET", "api/libraries/\(libraryID)/matchall", token: token)
    }

    // MARK: Użytkownicy

    public struct Permissions: Codable, Sendable, Equatable {
        public var download = true
        public var update = false
        public var delete = false
        public var upload = false
        public var createEreader = false
        public var accessAllLibraries = true
        public var accessAllTags = true
        public var accessExplicitContent = false
        /// Gdy `true`, wybrane tagi są *niedostępne*; gdy `false` — dostępne są tylko one.
        public var selectedTagsNotAccessible = false

        public init() {}

        /// Domyślne uprawnienia typu konta (jak `userTypeUpdated` w `AccountModal.vue`).
        public static func defaults(for type: String) -> Permissions {
            var permissions = Permissions()
            let isAdmin = type == "admin"
            permissions.download = type != "guest"
            permissions.update = isAdmin
            permissions.delete = isAdmin
            permissions.upload = isAdmin
            permissions.accessExplicitContent = isAdmin
            permissions.createEreader = isAdmin
            return permissions
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func flag(_ key: CodingKeys, _ fallback: Bool) -> Bool {
                (try? container.decode(Bool.self, forKey: key)) ?? fallback
            }
            download = flag(.download, true)
            update = flag(.update, false)
            delete = flag(.delete, false)
            upload = flag(.upload, false)
            createEreader = flag(.createEreader, false)
            accessAllLibraries = flag(.accessAllLibraries, true)
            accessAllTags = flag(.accessAllTags, true)
            accessExplicitContent = flag(.accessExplicitContent, false)
            selectedTagsNotAccessible = flag(.selectedTagsNotAccessible, false)
        }
    }

    /// Konto na serwerze w widoku administratora (`User.toOldJSONForBrowser`, wersja minimalna).
    public struct ManagedUser: Decodable, Sendable, Identifiable, Equatable {
        public let id: String
        public let username: String
        /// `root`, `admin`, `user` albo `guest`.
        public let type: String
        public let isActive: Bool
        public let isLocked: Bool
        /// Milisekundy od 1970.
        public let lastSeen: Double?
        public let createdAt: Double?
        public let permissions: Permissions
        public let librariesAccessible: [String]
        public let itemTagsSelected: [String]
        public let hasOpenIDLink: Bool

        public var isRoot: Bool { type == "root" }

        private enum CodingKeys: String, CodingKey {
            case id, username, type, isActive, isLocked, lastSeen, createdAt, permissions, librariesAccessible, itemTagsSelected, hasOpenIDLink
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            username = try container.decode(String.self, forKey: .username)
            type = (try? container.decode(String.self, forKey: .type)) ?? "user"
            isActive = (try? container.decode(Bool.self, forKey: .isActive)) ?? false
            isLocked = (try? container.decode(Bool.self, forKey: .isLocked)) ?? false
            lastSeen = try? container.decode(Double.self, forKey: .lastSeen)
            createdAt = try? container.decode(Double.self, forKey: .createdAt)
            permissions = (try? container.decode(Permissions.self, forKey: .permissions)) ?? Permissions()
            librariesAccessible = (try? container.decode([String].self, forKey: .librariesAccessible)) ?? []
            itemTagsSelected = (try? container.decode([String].self, forKey: .itemTagsSelected)) ?? []
            hasOpenIDLink = (try? container.decode(Bool.self, forKey: .hasOpenIDLink)) ?? false
        }
    }

    /// Zmiany konta. Biblioteki i tagi idą *wewnątrz* `permissions`: `UserController.update`
    /// bierze je pod uwagę tylko w gałęzi uprawnień, więc `permissions` jest zawsze wysyłane.
    /// Hasło nigdy nie trafia do logów; puste pole znaczy „bez zmiany”.
    public struct UserChanges: Encodable, Sendable {
        public var username: String?
        public var password: String?
        public var type: String?
        public var isActive: Bool?
        public var permissions: Permissions
        public var librariesAccessible: [String]
        public var itemTagsSelected: [String]

        private enum CodingKeys: String, CodingKey { case username, password, type, isActive, permissions }
        private enum PermissionKeys: String, CodingKey {
            case download, update, delete, upload, createEreader, accessAllLibraries, accessAllTags,
                 accessExplicitContent, selectedTagsNotAccessible, librariesAccessible, itemTagsSelected
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(username, forKey: .username)
            try container.encodeIfPresent(password, forKey: .password)
            try container.encodeIfPresent(type, forKey: .type)
            try container.encodeIfPresent(isActive, forKey: .isActive)
            var nested = container.nestedContainer(keyedBy: PermissionKeys.self, forKey: .permissions)
            try nested.encode(permissions.download, forKey: .download)
            try nested.encode(permissions.update, forKey: .update)
            try nested.encode(permissions.delete, forKey: .delete)
            try nested.encode(permissions.upload, forKey: .upload)
            try nested.encode(permissions.createEreader, forKey: .createEreader)
            try nested.encode(permissions.accessAllLibraries, forKey: .accessAllLibraries)
            try nested.encode(permissions.accessAllTags, forKey: .accessAllTags)
            try nested.encode(permissions.accessExplicitContent, forKey: .accessExplicitContent)
            try nested.encode(permissions.selectedTagsNotAccessible, forKey: .selectedTagsNotAccessible)
            try nested.encode(librariesAccessible, forKey: .librariesAccessible)
            try nested.encode(itemTagsSelected, forKey: .itemTagsSelected)
        }

        public init(username: String? = nil, password: String? = nil, type: String? = nil, isActive: Bool? = nil, permissions: Permissions, librariesAccessible: [String], itemTagsSelected: [String]) {
            self.username = username
            self.password = password
            self.type = type
            self.isActive = isActive
            self.permissions = permissions
            self.librariesAccessible = librariesAccessible
            self.itemTagsSelected = itemTagsSelected
        }
    }

    public func users(token: String) async throws -> [ManagedUser] {
        struct Response: Decodable { let users: [ManagedUser] }
        return try decode(Response.self, from: await send("GET", "api/users", token: token)).users
    }

    /// Zakłada konto (wymagane nazwa i hasło). Zajęta nazwa: HTTP 400.
    public func createUser(_ changes: UserChanges, token: String) async throws -> ManagedUser {
        struct Response: Decodable { let user: ManagedUser }
        return try decode(Response.self, from: await send("POST", "api/users", body: changes, token: token)).user
    }

    /// Zmienia konto. Zmiana nazwy albo hasła unieważnia sesje tego konta na serwerze.
    public func updateUser(id: String, _ changes: UserChanges, token: String) async throws -> ManagedUser {
        struct Response: Decodable { let user: ManagedUser }
        return try decode(Response.self, from: await send("PATCH", "api/users/\(id)", body: changes, token: token)).user
    }

    /// Usuwa konto razem z jego playlistami; sesje odtwarzania zostają bez właściciela.
    /// Roota nie da się usunąć (403), samego siebie też nie (400).
    public func deleteUser(id: String, token: String) async throws {
        _ = try await send("DELETE", "api/users/\(id)", token: token)
    }

    /// Wszystkie tagi książek i podcastów (do ograniczania dostępu po tagach).
    public func allTags(token: String) async throws -> [String] {
        struct Response: Decodable { let tags: [String] }
        return try decode(Response.self, from: await send("GET", "api/tags", token: token)).tags
    }
}
