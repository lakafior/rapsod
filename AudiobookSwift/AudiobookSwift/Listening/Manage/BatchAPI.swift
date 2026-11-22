import Foundation

/// Operacje na wielu pozycjach naraz (etap 9h; wzorzec: pasek zaznaczenia `components/app/Appbar.vue`,
/// strona `pages/batch/index.vue` i `modals/BatchQuickMatchModel.vue`). Kształty z upstreamu v2.38.0:
/// `LibraryItemController.batchUpdate|batchGet|batchQuickMatch|batchScan`, `ToolsController.batchEmbedMetadata`,
/// `CollectionController.create|addBatch`, `PlaylistController.addBatch`. Zmiany pozycji tokenem root
/// (przez `ItemManager`), playlisty i postęp — kontem słuchacza (to jego dane).
extension AudiobookshelfClient {
    private struct ItemIDs: Encodable { let libraryItemIds: [String] }

    /// Pełne pozycje (`POST /api/items/batch/get`) — dla edycji wsadowej z dopisywaniem.
    func batchItems(ids: [String], token: String) async throws -> [ItemDetail] {
        struct Response: Decodable { let libraryItems: LenientList<ItemDetail> }
        return try decode(Response.self, from: await send("POST", "api/items/batch/get", body: ItemIDs(libraryItemIds: ids), token: token)).libraryItems.elements
    }

    struct BatchUpdate: Encodable, Sendable {
        let id: String
        let mediaPayload: BatchMediaPayload
    }

    struct BatchMediaPayload: Encodable, Sendable {
        var metadata = BatchMetadata()
        var tags: [String]?
    }

    /// Tylko pola wybrane w arkuszu — reszta zostaje pominięta (upstream zmienia tylko podane).
    struct BatchMetadata: Encodable, Sendable {
        struct Named: Encodable, Sendable { let name: String }
        struct SeriesEntry: Encodable, Sendable {
            let name: String
            let sequence: String?
        }
        var subtitle: String?
        var authors: [Named]?
        var narrators: [String]?
        var series: [SeriesEntry]?
        var genres: [String]?
        var publishedYear: String?
        var publisher: String?
        var language: String?
        var explicit: Bool?
        var abridged: Bool?
    }

    /// `POST /api/items/batch/update` — zwraca liczbę zmienionych pozycji.
    func batchUpdate(_ updates: [BatchUpdate], token: String) async throws -> Int {
        struct Response: Decodable { let updates: Int? }
        return try decode(Response.self, from: await send("POST", "api/items/batch/update", body: updates, token: token, timeout: 120)).updates ?? 0
    }

    struct QuickMatchOptions: Encodable, Sendable {
        var provider: String?
        var overrideCover: Bool
        var overrideDetails: Bool
    }

    /// Szybkie dopasowanie w tle (`POST /api/items/batch/quickmatch`); serwer odpowiada od razu,
    /// a zmienione pozycje przychodzą zdarzeniami `item_updated`.
    func batchQuickMatch(ids: [String], options: QuickMatchOptions, token: String) async throws {
        struct Body: Encodable {
            let libraryItemIds: [String]
            let options: QuickMatchOptions
        }
        _ = try await send("POST", "api/items/batch/quickmatch", body: Body(libraryItemIds: ids, options: options), token: token)
    }

    /// Ponowny skan wielu pozycji w tle (`POST /api/items/batch/scan`).
    func batchScan(ids: [String], token: String) async throws {
        _ = try await send("POST", "api/items/batch/scan", body: ItemIDs(libraryItemIds: ids), token: token)
    }

    /// Osadzenie metadanych w plikach audio wielu książek (zadania serwera w kolejce).
    func batchEmbedMetadata(ids: [String], backup: Bool, token: String) async throws {
        let query = backup ? [URLQueryItem(name: "backup", value: "1")] : []
        _ = try await send("POST", "api/tools/batch/embed-metadata", query: query, body: ItemIDs(libraryItemIds: ids), token: token)
    }

    func createCollection(libraryID: String, name: String, books: [String], token: String) async throws {
        struct Body: Encodable {
            let libraryId: String
            let name: String
            let books: [String]
        }
        _ = try await send("POST", "api/collections", body: Body(libraryId: libraryID, name: name, books: books), token: token)
    }

    func addToCollection(id: String, books: [String], token: String) async throws {
        struct Body: Encodable { let books: [String] }
        _ = try await send("POST", "api/collections/\(id)/batch/add", body: Body(books: books), token: token)
    }

    func addToPlaylist(id: String, entries: [PlaylistEntry], token: String) async throws {
        struct Body: Encodable { let items: [PlaylistEntry] }
        _ = try await send("POST", "api/playlists/\(id)/batch/add", body: Body(items: entries), token: token)
    }
}
