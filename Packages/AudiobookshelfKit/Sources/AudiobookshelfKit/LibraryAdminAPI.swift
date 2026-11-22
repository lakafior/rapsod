// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Ostatnie strony, które wymagały web UI (etap 9i). Kształty z upstreamu v2.38.0:
/// `AuthorController.update|match|uploadImage|deleteImage`, `CollectionController.update|delete|removeBatch`,
/// `MiscController.getAllTags|renameTag|deleteTag` (i to samo dla gatunków), `LibraryController.updateNarrator|
/// removeNarrator|stats|reorder|update (folders)|downloadMultiple`, `ShareController.createMediaItemShare|
/// deleteMediaItemShare`, `UserController.getListeningStats`. Operacje zmieniające idą tokenem root
/// (`ItemManager` albo `ServerAccount.withAdminToken`); statystyki biblioteki — kontem słuchacza.
extension AudiobookshelfClient {
    /// Segment ścieżki jak `encodeURIComponent(base64(nazwa))` w web UI. `URL.appending(path:)` koduje
    /// jeszcze raz `%`, Express zdejmuje jedno kodowanie, serwer drugie (`decodeURIComponent`) — dzięki temu
    /// `/` z base64 nie rozcina ścieżki.
    public static func encodedName(_ name: String) -> String {
        let base64 = Data(name.utf8).base64EncodedString()
        return base64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? base64
    }

    // MARK: Autor

    /// Wszystkie trzy pola zawsze w treści: serwer zmienia tylko obecne klucze, więc pominięty
    /// (nil) opis albo ASIN nie dałby się wyczyścić. Puste pole to pusty napis.
    public struct AuthorUpdate: Encodable, Sendable {
        public let name: String
        public let description: String
        public let asin: String

        public init(name: String, description: String, asin: String) {
            self.name = name
            self.description = description
            self.asin = asin
        }
    }

    public struct AuthorChange: Decodable, Sendable {
        public struct Changed: Decodable, Sendable {
            public let id: String
            public let name: String
            public let imagePath: String?
            public let description: String?
            public let asin: String?
        }
        public let author: Changed
        /// Nowa nazwa należała do innego autora tej biblioteki — serwer połączył obu, stary `id` znika.
        public let merged: Bool?
        public let updated: Bool?
    }

    public func updateAuthor(id: String, _ update: AuthorUpdate, token: String) async throws -> AuthorChange {
        try decode(AuthorChange.self, from: await send("PATCH", "api/authors/\(id)", body: update, token: token))
    }

    /// Dopasowanie w Audible (`POST /api/authors/:id/match`): opis, ASIN i zdjęcie (zdjęcie tylko, gdy
    /// autor go nie miał albo zmienił się ASIN). 404, gdy nic nie znaleziono.
    public func matchAuthor(id: String, query: String?, asin: String?, region: String, token: String) async throws -> AuthorChange {
        struct Body: Encodable {
            let q: String?
            let asin: String?
            let region: String
        }
        return try decode(AuthorChange.self, from: await send("POST", "api/authors/\(id)/match", body: Body(q: query, asin: asin, region: region), token: token, timeout: 60))
    }

    /// Zdjęcie autora z adresu http(s) — serwer sam je pobiera (upstream nie przyjmuje pliku).
    public func setAuthorImage(id: String, url: String, token: String) async throws {
        struct Body: Encodable { let url: String }
        _ = try await send("POST", "api/authors/\(id)/image", body: Body(url: url), token: token, timeout: 60)
    }

    public func removeAuthorImage(id: String, token: String) async throws {
        _ = try await send("DELETE", "api/authors/\(id)/image", token: token)
    }

    // MARK: Kolekcja

    public func updateCollection(id: String, name: String, description: String, token: String) async throws {
        struct Body: Encodable {
            let name: String
            let description: String
        }
        _ = try await send("PATCH", "api/collections/\(id)", body: Body(name: name, description: description), token: token)
    }

    public func removeFromCollection(id: String, books: [String], token: String) async throws {
        struct Body: Encodable { let books: [String] }
        _ = try await send("POST", "api/collections/\(id)/batch/remove", body: Body(books: books), token: token)
    }

    public func deleteCollection(id: String, token: String) async throws {
        _ = try await send("DELETE", "api/collections/\(id)", token: token)
    }

    // MARK: Tagi, gatunki, lektorzy w całej bibliotece

    public enum MetadataList: String, Sendable {
        case tags, genres

        public var singular: String { self == .tags ? "tag" : "genre" }
    }

    /// Wszystkie tagi albo gatunki na serwerze (we wszystkich bibliotekach; tylko administrator).
    public func metadataValues(_ list: MetadataList, token: String) async throws -> [String] {
        let data = try await send("GET", "api/\(list.rawValue)", token: token)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?[list.rawValue] as? [String] ?? []
    }

    /// Zmiana nazwy w każdej pozycji; nowa nazwa już istniejąca oznacza scalenie. Zwraca liczbę pozycji.
    public func renameMetadataValue(_ list: MetadataList, from old: String, to new: String, token: String) async throws -> Int {
        let body = [list.singular: old, "new" + list.singular.prefix(1).uppercased() + list.singular.dropFirst(): new]
        let data = try await send("POST", "api/\(list.rawValue)/rename", body: body, token: token, timeout: 120)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["numItemsUpdated"] as? Int ?? 0
    }

    public func deleteMetadataValue(_ list: MetadataList, _ value: String, token: String) async throws -> Int {
        let data = try await send("DELETE", "api/\(list.rawValue)/\(Self.encodedName(value))", token: token, timeout: 120)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["numItemsUpdated"] as? Int ?? 0
    }

    /// `narratorID` jest już zakodowany (`Narrator.id` z `GET /api/libraries/:id/narrators`).
    public func renameNarrator(libraryID: String, narratorID: String, to name: String, token: String) async throws -> Int {
        struct Body: Encodable { let name: String }
        struct Response: Decodable { let updated: Int? }
        return try decode(Response.self, from: await send("PATCH", "api/libraries/\(libraryID)/narrators/\(narratorID)", body: Body(name: name), token: token, timeout: 120)).updated ?? 0
    }

    public func removeNarrator(libraryID: String, narratorID: String, token: String) async throws -> Int {
        struct Response: Decodable { let updated: Int? }
        return try decode(Response.self, from: await send("DELETE", "api/libraries/\(libraryID)/narrators/\(narratorID)", token: token, timeout: 120)).updated ?? 0
    }

    // MARK: Publiczny link udostępniania

    public struct MediaItemShare: Decodable, Sendable, Identifiable {
        public let id: String
        public let slug: String
        /// Milisekundy; `nil` — bez końca.
        public let expiresAt: Double?
        public let isDownloadable: Bool?

        private enum CodingKeys: String, CodingKey { case id, slug, expiresAt, isDownloadable }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            slug = try c.decode(String.self, forKey: .slug)
            isDownloadable = try? c.decodeIfPresent(Bool.self, forKey: .isDownloadable)
            // Sequelize zwraca datę jako napis ISO, `toJSONForClient` — jako liczbę albo napis.
            if let number = try? c.decodeIfPresent(Double.self, forKey: .expiresAt) {
                expiresAt = number
            } else if let text = try? c.decodeIfPresent(String.self, forKey: .expiresAt),
                      let date = (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                          ?? (try? Date(text, strategy: .iso8601)) {
                expiresAt = date.timeIntervalSince1970 * 1000
            } else {
                expiresAt = nil
            }
        }
    }

    /// Książka z identyfikatorem mediów i otwartym linkiem (`include=share` widzi tylko administrator).
    public func shareState(itemID: String, token: String) async throws -> (mediaID: String, share: MediaItemShare?) {
        struct Response: Decodable {
            struct Media: Decodable { let id: String }
            let media: Media
            let mediaItemShare: MediaItemShare?
        }
        let response = try decode(Response.self, from: await send("GET", "api/items/\(itemID)", query: [URLQueryItem(name: "include", value: "share")], token: token))
        return (response.media.id, response.mediaItemShare)
    }

    public func createShare(mediaID: String, slug: String, expiresAt: Double, downloadable: Bool, token: String) async throws -> MediaItemShare {
        struct Body: Encodable {
            let slug: String
            /// 0 — bez wygaśnięcia (upstream odrzuca `null`).
            let expiresAt: Double
            let mediaItemType = "book"
            let mediaItemId: String
            let isDownloadable: Bool
        }
        let body = Body(slug: slug, expiresAt: expiresAt, mediaItemId: mediaID, isDownloadable: downloadable)
        return try decode(MediaItemShare.self, from: await send("POST", "api/share/mediaitem", body: body, token: token))
    }

    public func deleteShare(id: String, token: String) async throws {
        _ = try await send("DELETE", "api/share/mediaitem/\(id)", token: token)
    }

    // MARK: Statystyki

    public struct LibraryStats: Decodable, Sendable {
        /// Autor (`id`, `name`) albo gatunek (sam `genre`) z liczbą pozycji.
        public struct Named: Decodable, Sendable, Identifiable {
            public let authorID: String?
            public let name: String?
            public let genre: String?
            public let count: Int?
            public var title: String { name ?? genre ?? "—" }
            public var id: String { authorID ?? genre ?? title }

            private enum CodingKeys: String, CodingKey {
                case authorID = "id", name, genre, count
            }
        }
        public struct Sized: Decodable, Sendable, Identifiable {
            public let id: String
            public let title: String?
            public let size: Double?
            public let duration: Double?
        }
        public let totalItems: Int?
        public let totalAuthors: Int?
        public let totalGenres: Int?
        public let totalDuration: Double?
        public let totalSize: Double?
        public let numAudioTracks: Int?
        public let authorsWithCount: LenientList<Named>?
        public let genresWithCount: LenientList<Named>?
        public let longestItems: LenientList<Sized>?
        public let largestItems: LenientList<Sized>?
    }

    public func libraryStats(libraryID: String, token: String) async throws -> LibraryStats {
        try decode(LibraryStats.self, from: await send("GET", "api/libraries/\(libraryID)/stats", token: token, timeout: 60))
    }

    /// Statystyki słuchania dowolnego konta (to samo co `/api/me/listening-stats`, tylko administrator).
    public func listeningStats(userID: String, token: String) async throws -> ListeningStats {
        try decode(ListeningStats.self, from: await send("GET", "api/users/\(userID)/listening-stats", token: token))
    }

    // MARK: Biblioteki: kolejność, foldery, archiwum

    public func reorderLibraries(_ ids: [String], token: String) async throws {
        struct Entry: Encodable {
            let id: String
            let newOrder: Int
        }
        _ = try await send("POST", "api/libraries/order", body: ids.enumerated().map { Entry(id: $1, newOrder: $0 + 1) }, token: token)
    }

    /// Foldery biblioteki. Istniejący folder musi mieć `id` — folder pominięty w liście serwer usuwa
    /// razem z pozycjami z bazy (pliki zostają); nowy ma samo `fullPath`.
    public struct FolderEntry: Encodable, Sendable {
        public let id: String?
        public let fullPath: String

        public init(id: String?, fullPath: String) {
            self.id = id
            self.fullPath = fullPath
        }
    }

    public func updateLibraryFolders(id: String, folders: [FolderEntry], token: String) async throws {
        struct Body: Encodable { let folders: [FolderEntry] }
        _ = try await send("PATCH", "api/libraries/\(id)", body: Body(folders: folders), token: token, timeout: 120)
    }

    /// Archiwum ZIP z folderami pozycji (`GET /api/libraries/:id/download?ids=`), zapisywane wprost do pliku
    /// (`URLSession.download`), bez trzymania całego archiwum w pamięci.
    public func downloadItems(libraryID: String, ids: [String], to destination: URL, token: String) async throws {
        var url = baseURL.appending(path: "api/libraries/\(libraryID)/download")
        url.append(queryItems: [URLQueryItem(name: "ids", value: ids.joined(separator: ","))])
        var request = URLRequest(url: url)
        // Pakowanie dużych pozycji trwa; serwer wysyła dane od razu, więc limit dotyczy przerw.
        request.timeoutInterval = 300
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? String(contentsOf: file, encoding: .utf8))?.prefix(500) ?? ""
            throw http.statusCode == 401 ? APIError.unauthorized : APIError.http(status: http.statusCode, message: String(message))
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: file, to: destination)
    }
}
