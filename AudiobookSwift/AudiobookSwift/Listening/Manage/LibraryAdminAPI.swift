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
    static func encodedName(_ name: String) -> String {
        let base64 = Data(name.utf8).base64EncodedString()
        return base64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? base64
    }

    // MARK: Autor

    struct AuthorUpdate: Encodable, Sendable {
        let name: String
        let description: String?
        let asin: String?
    }

    struct AuthorChange: Decodable, Sendable {
        struct Changed: Decodable, Sendable {
            let id: String
            let name: String
            let imagePath: String?
            let description: String?
            let asin: String?
        }
        let author: Changed
        /// Nowa nazwa należała do innego autora tej biblioteki — serwer połączył obu, stary `id` znika.
        let merged: Bool?
        let updated: Bool?
    }

    func updateAuthor(id: String, _ update: AuthorUpdate, token: String) async throws -> AuthorChange {
        try decode(AuthorChange.self, from: await send("PATCH", "api/authors/\(id)", body: update, token: token))
    }

    /// Dopasowanie w Audible (`POST /api/authors/:id/match`): opis, ASIN i zdjęcie (zdjęcie tylko, gdy
    /// autor go nie miał albo zmienił się ASIN). 404, gdy nic nie znaleziono.
    func matchAuthor(id: String, query: String?, asin: String?, region: String, token: String) async throws -> AuthorChange {
        struct Body: Encodable {
            let q: String?
            let asin: String?
            let region: String
        }
        return try decode(AuthorChange.self, from: await send("POST", "api/authors/\(id)/match", body: Body(q: query, asin: asin, region: region), token: token, timeout: 60))
    }

    /// Zdjęcie autora z adresu http(s) — serwer sam je pobiera (upstream nie przyjmuje pliku).
    func setAuthorImage(id: String, url: String, token: String) async throws {
        struct Body: Encodable { let url: String }
        _ = try await send("POST", "api/authors/\(id)/image", body: Body(url: url), token: token, timeout: 60)
    }

    func removeAuthorImage(id: String, token: String) async throws {
        _ = try await send("DELETE", "api/authors/\(id)/image", token: token)
    }

    // MARK: Kolekcja

    func updateCollection(id: String, name: String, description: String, token: String) async throws {
        struct Body: Encodable {
            let name: String
            let description: String
        }
        _ = try await send("PATCH", "api/collections/\(id)", body: Body(name: name, description: description), token: token)
    }

    func removeFromCollection(id: String, books: [String], token: String) async throws {
        struct Body: Encodable { let books: [String] }
        _ = try await send("POST", "api/collections/\(id)/batch/remove", body: Body(books: books), token: token)
    }

    func deleteCollection(id: String, token: String) async throws {
        _ = try await send("DELETE", "api/collections/\(id)", token: token)
    }

    // MARK: Tagi, gatunki, lektorzy w całej bibliotece

    enum MetadataList: String, Sendable {
        case tags, genres

        var singular: String { self == .tags ? "tag" : "genre" }
    }

    /// Wszystkie tagi albo gatunki na serwerze (we wszystkich bibliotekach; tylko administrator).
    func metadataValues(_ list: MetadataList, token: String) async throws -> [String] {
        let data = try await send("GET", "api/\(list.rawValue)", token: token)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?[list.rawValue] as? [String] ?? []
    }

    /// Zmiana nazwy w każdej pozycji; nowa nazwa już istniejąca oznacza scalenie. Zwraca liczbę pozycji.
    func renameMetadataValue(_ list: MetadataList, from old: String, to new: String, token: String) async throws -> Int {
        let body = [list.singular: old, "new" + list.singular.prefix(1).uppercased() + list.singular.dropFirst(): new]
        let data = try await send("POST", "api/\(list.rawValue)/rename", body: body, token: token, timeout: 120)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["numItemsUpdated"] as? Int ?? 0
    }

    func deleteMetadataValue(_ list: MetadataList, _ value: String, token: String) async throws -> Int {
        let data = try await send("DELETE", "api/\(list.rawValue)/\(Self.encodedName(value))", token: token, timeout: 120)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["numItemsUpdated"] as? Int ?? 0
    }

    /// `narratorID` jest już zakodowany (`Narrator.id` z `GET /api/libraries/:id/narrators`).
    func renameNarrator(libraryID: String, narratorID: String, to name: String, token: String) async throws -> Int {
        struct Body: Encodable { let name: String }
        struct Response: Decodable { let updated: Int? }
        return try decode(Response.self, from: await send("PATCH", "api/libraries/\(libraryID)/narrators/\(narratorID)", body: Body(name: name), token: token, timeout: 120)).updated ?? 0
    }

    func removeNarrator(libraryID: String, narratorID: String, token: String) async throws -> Int {
        struct Response: Decodable { let updated: Int? }
        return try decode(Response.self, from: await send("DELETE", "api/libraries/\(libraryID)/narrators/\(narratorID)", token: token, timeout: 120)).updated ?? 0
    }

    // MARK: Publiczny link udostępniania

    struct MediaItemShare: Decodable, Sendable, Identifiable {
        let id: String
        let slug: String
        /// Milisekundy; `nil` — bez końca.
        let expiresAt: Double?
        let isDownloadable: Bool?

        private enum CodingKeys: String, CodingKey { case id, slug, expiresAt, isDownloadable }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            slug = try c.decode(String.self, forKey: .slug)
            isDownloadable = try? c.decodeIfPresent(Bool.self, forKey: .isDownloadable)
            // Sequelize zwraca datę jako napis ISO, `toJSONForClient` — jako liczbę albo napis.
            if let number = try? c.decodeIfPresent(Double.self, forKey: .expiresAt) {
                expiresAt = number
            } else if let text = try? c.decodeIfPresent(String.self, forKey: .expiresAt),
                      let date = ISO8601DateFormatter.withFractions.date(from: text) ?? ISO8601DateFormatter().date(from: text) {
                expiresAt = date.timeIntervalSince1970 * 1000
            } else {
                expiresAt = nil
            }
        }
    }

    /// Książka z identyfikatorem mediów i otwartym linkiem (`include=share` widzi tylko administrator).
    func shareState(itemID: String, token: String) async throws -> (mediaID: String, share: MediaItemShare?) {
        struct Response: Decodable {
            struct Media: Decodable { let id: String }
            let media: Media
            let mediaItemShare: MediaItemShare?
        }
        let response = try decode(Response.self, from: await send("GET", "api/items/\(itemID)", query: [URLQueryItem(name: "include", value: "share")], token: token))
        return (response.media.id, response.mediaItemShare)
    }

    func createShare(mediaID: String, slug: String, expiresAt: Double, downloadable: Bool, token: String) async throws -> MediaItemShare {
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

    func deleteShare(id: String, token: String) async throws {
        _ = try await send("DELETE", "api/share/mediaitem/\(id)", token: token)
    }

    // MARK: Statystyki

    struct LibraryStats: Decodable, Sendable {
        /// Autor (`id`, `name`) albo gatunek (sam `genre`) z liczbą pozycji.
        struct Named: Decodable, Sendable, Identifiable {
            let authorID: String?
            let name: String?
            let genre: String?
            let count: Int?
            var title: String { name ?? genre ?? "—" }
            var id: String { authorID ?? genre ?? title }

            private enum CodingKeys: String, CodingKey {
                case authorID = "id", name, genre, count
            }
        }
        struct Sized: Decodable, Sendable, Identifiable {
            let id: String
            let title: String?
            let size: Double?
            let duration: Double?
        }
        let totalItems: Int?
        let totalAuthors: Int?
        let totalGenres: Int?
        let totalDuration: Double?
        let totalSize: Double?
        let numAudioTracks: Int?
        let authorsWithCount: LenientList<Named>?
        let genresWithCount: LenientList<Named>?
        let longestItems: LenientList<Sized>?
        let largestItems: LenientList<Sized>?
    }

    func libraryStats(libraryID: String, token: String) async throws -> LibraryStats {
        try decode(LibraryStats.self, from: await send("GET", "api/libraries/\(libraryID)/stats", token: token, timeout: 60))
    }

    /// Statystyki słuchania dowolnego konta (to samo co `/api/me/listening-stats`, tylko administrator).
    func listeningStats(userID: String, token: String) async throws -> ListeningStats {
        try decode(ListeningStats.self, from: await send("GET", "api/users/\(userID)/listening-stats", token: token))
    }

    // MARK: Biblioteki: kolejność, foldery, archiwum

    func reorderLibraries(_ ids: [String], token: String) async throws {
        struct Entry: Encodable {
            let id: String
            let newOrder: Int
        }
        _ = try await send("POST", "api/libraries/order", body: ids.enumerated().map { Entry(id: $1, newOrder: $0 + 1) }, token: token)
    }

    /// Foldery biblioteki. Istniejący folder musi mieć `id` — folder pominięty w liście serwer usuwa
    /// razem z pozycjami z bazy (pliki zostają); nowy ma samo `fullPath`.
    struct FolderEntry: Encodable, Sendable {
        let id: String?
        let fullPath: String
    }

    func updateLibraryFolders(id: String, folders: [FolderEntry], token: String) async throws {
        struct Body: Encodable { let folders: [FolderEntry] }
        _ = try await send("PATCH", "api/libraries/\(id)", body: Body(folders: folders), token: token, timeout: 120)
    }

    /// Archiwum ZIP z folderami pozycji (`GET /api/libraries/:id/download?ids=`), zapisywane wprost do pliku
    /// (`URLSession.download`), bez trzymania całego archiwum w pamięci.
    func downloadItems(libraryID: String, ids: [String], to destination: URL, token: String) async throws {
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

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
