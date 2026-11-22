import Foundation

/// Operacje na wielu pozycjach naraz (etap 9h; wzorzec: pasek zaznaczenia `components/app/Appbar.vue`,
/// strona `pages/batch/index.vue` i `modals/BatchQuickMatchModel.vue`). Kształty z upstreamu v2.38.0:
/// `LibraryItemController.batchUpdate|batchGet|batchQuickMatch|batchScan`, `ToolsController.batchEmbedMetadata`,
/// `CollectionController.create|addBatch`, `PlaylistController.addBatch`. Zmiany pozycji tokenem root
/// (przez `ItemManager`), playlisty i postęp — kontem słuchacza (to jego dane).
extension AudiobookshelfClient {
    private struct ItemIDs: Encodable { let libraryItemIds: [String] }

    /// Pełne pozycje (`POST /api/items/batch/get`) — dla edycji wsadowej z dopisywaniem.
    public func batchItems(ids: [String], token: String) async throws -> [ItemDetail] {
        struct Response: Decodable { let libraryItems: LenientList<ItemDetail> }
        return try decode(Response.self, from: await send("POST", "api/items/batch/get", body: ItemIDs(libraryItemIds: ids), token: token)).libraryItems.elements
    }

    public struct BatchUpdate: Encodable, Sendable {
        public let id: String
        public let mediaPayload: BatchMediaPayload

        public init(id: String, mediaPayload: BatchMediaPayload) {
            self.id = id
            self.mediaPayload = mediaPayload
        }
    }

    public struct BatchMediaPayload: Encodable, Sendable {
        public var metadata = BatchMetadata()
        public var tags: [String]?

        public init(metadata: BatchMetadata = BatchMetadata(), tags: [String]? = nil) {
            self.metadata = metadata
            self.tags = tags
        }
    }

    /// Tylko pola wybrane w arkuszu — reszta zostaje pominięta (upstream zmienia tylko podane).
    public struct BatchMetadata: Encodable, Sendable {
        public struct Named: Encodable, Sendable { public let name: String; public init(name: String) { self.name = name } }
        public struct SeriesEntry: Encodable, Sendable {
            public let name: String
            public let sequence: String?

            public init(name: String, sequence: String?) {
                self.name = name
                self.sequence = sequence
            }
        }
        public var subtitle: String?
        public var authors: [Named]?
        public var narrators: [String]?
        public var series: [SeriesEntry]?
        public var genres: [String]?
        public var publishedYear: String?
        public var publisher: String?
        public var language: String?
        public var explicit: Bool?
        public var abridged: Bool?

        public init(subtitle: String? = nil, authors: [Named]? = nil, narrators: [String]? = nil, series: [SeriesEntry]? = nil, genres: [String]? = nil, publishedYear: String? = nil, publisher: String? = nil, language: String? = nil, explicit: Bool? = nil, abridged: Bool? = nil) {
            self.subtitle = subtitle
            self.authors = authors
            self.narrators = narrators
            self.series = series
            self.genres = genres
            self.publishedYear = publishedYear
            self.publisher = publisher
            self.language = language
            self.explicit = explicit
            self.abridged = abridged
        }
    }

    /// `POST /api/items/batch/update` — zwraca liczbę zmienionych pozycji.
    public func batchUpdate(_ updates: [BatchUpdate], token: String) async throws -> Int {
        struct Response: Decodable { let updates: Int? }
        return try decode(Response.self, from: await send("POST", "api/items/batch/update", body: updates, token: token, timeout: 120)).updates ?? 0
    }

    public struct QuickMatchOptions: Encodable, Sendable {
        public var provider: String?
        public var overrideCover: Bool
        public var overrideDetails: Bool

        public init(provider: String? = nil, overrideCover: Bool, overrideDetails: Bool) {
            self.provider = provider
            self.overrideCover = overrideCover
            self.overrideDetails = overrideDetails
        }
    }

    /// Szybkie dopasowanie w tle (`POST /api/items/batch/quickmatch`); serwer odpowiada od razu,
    /// a zmienione pozycje przychodzą zdarzeniami `item_updated`.
    public func batchQuickMatch(ids: [String], options: QuickMatchOptions, token: String) async throws {
        struct Body: Encodable {
            let libraryItemIds: [String]
            let options: QuickMatchOptions
        }
        _ = try await send("POST", "api/items/batch/quickmatch", body: Body(libraryItemIds: ids, options: options), token: token)
    }

    /// Ponowny skan wielu pozycji w tle (`POST /api/items/batch/scan`).
    public func batchScan(ids: [String], token: String) async throws {
        _ = try await send("POST", "api/items/batch/scan", body: ItemIDs(libraryItemIds: ids), token: token)
    }

    /// Osadzenie metadanych w plikach audio wielu książek (zadania serwera w kolejce).
    public func batchEmbedMetadata(ids: [String], backup: Bool, token: String) async throws {
        let query = backup ? [URLQueryItem(name: "backup", value: "1")] : []
        _ = try await send("POST", "api/tools/batch/embed-metadata", query: query, body: ItemIDs(libraryItemIds: ids), token: token)
    }

    public func createCollection(libraryID: String, name: String, books: [String], token: String) async throws {
        struct Body: Encodable {
            let libraryId: String
            let name: String
            let books: [String]
        }
        _ = try await send("POST", "api/collections", body: Body(libraryId: libraryID, name: name, books: books), token: token)
    }

    public func addToCollection(id: String, books: [String], token: String) async throws {
        struct Body: Encodable { let books: [String] }
        _ = try await send("POST", "api/collections/\(id)/batch/add", body: Body(books: books), token: token)
    }

    public func addToPlaylist(id: String, entries: [PlaylistEntry], token: String) async throws {
        struct Body: Encodable { let items: [PlaylistEntry] }
        _ = try await send("POST", "api/playlists/\(id)/batch/add", body: Body(items: entries), token: token)
    }
}
