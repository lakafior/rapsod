// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Punkty API przeglądania biblioteki (etap 9b) — to, co zwykły użytkownik widzi w web UI.
/// Wołane tokenem konta do słuchania; nic tu nie wymaga uprawnień administratora.
///
/// Kształty sprawdzone na upstreamie v2.38.0: `server/controllers/LibraryController.js`
/// (`/libraries/:id/items|series|authors|narrators|collections|playlists|personalized|search|filterdata|recent-episodes`),
/// `LibraryItemController.js` (`/items/:id?expanded=1`), `AuthorController.js` (`/authors/:id`),
/// `CollectionController.js`, `PlaylistController.js`, `MeController.js` (postęp, zakładki)
/// i `ApiRouter.js` (`/me/listening-stats`). Szczegóły w notatce etapu 9b.
extension AudiobookshelfClient {
    // MARK: Modele

    public struct Page<Element: Decodable & Sendable>: Decodable, Sendable {
        public let results: LenientList<Element>
        /// Brak przy `collapseseries` z filtrem serii — tej kombinacji nie używamy.
        public let total: Int?
    }

    public struct NamedRef: Decodable, Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
    }

    /// Seria z książkami w kolejności tomów (`/libraries/:id/series`, półka „Ostatnie serie”).
    public struct Series: Decodable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let description: String?
        public let books: LenientList<LibraryItem>?

        public var items: [LibraryItem] { books?.elements ?? [] }

        public init(id: String, name: String, description: String?, books: LenientList<LibraryItem>?) {
            self.id = id
            self.name = name
            self.description = description
            self.books = books
        }
    }

    public struct Author: Decodable, Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        public let description: String?
        public let imagePath: String?
        public let numBooks: Int?
        public let updatedAt: Double?

        public init(id: String, name: String, description: String?, imagePath: String?, numBooks: Int?, updatedAt: Double?) {
            self.id = id
            self.name = name
            self.description = description
            self.imagePath = imagePath
            self.numBooks = numBooks
            self.updatedAt = updatedAt
        }
    }

    /// Autor z książkami i seriami (`GET /api/authors/:id?include=items,series`).
    public struct AuthorDetail: Decodable, Sendable {
        public struct AuthorSeries: Decodable, Sendable, Identifiable {
            public let id: String
            public let name: String
            public let items: LenientList<LibraryItem>
        }
        public let id: String
        public let name: String
        public let description: String?
        public let imagePath: String?
        public let asin: String?
        public let libraryItems: LenientList<LibraryItem>?
        public let series: LenientList<AuthorSeries>?
    }

    public struct Narrator: Decodable, Sendable, Hashable, Identifiable {
        /// Już zakodowana nazwa (`encodeURIComponent(base64(name))`) — gotowa do filtra.
        public let id: String
        public let name: String
        public let numBooks: Int?
    }

    public struct Collection: Decodable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let description: String?
        public let books: LenientList<LibraryItem>
    }

    public struct Playlist: Decodable, Sendable, Identifiable {
        public struct Item: Decodable, Sendable, Hashable {
            public let libraryItemId: String
            public let episodeId: String?
            public let libraryItem: LibraryItem?
            public let episode: PodcastEpisode?
        }
        public let id: String
        public let name: String
        public let description: String?
        public let libraryId: String
        public let items: LenientList<Item>
    }

    /// Wartości do filtrów (`GET /api/libraries/:id/filterdata`). Serwer ich nie zawęża do
    /// uprawnień użytkownika — tak samo jak web UI.
    public struct FilterData: Decodable, Sendable {
        public let authors: [NamedRef]?
        public let genres: [String]?
        public let tags: [String]?
        public let series: [NamedRef]?
        public let narrators: [String]?
        public let languages: [String]?
        public let publishers: [String]?
        public let publishedDecades: [String]?
    }

    /// Półka strony startowej (`GET /api/libraries/:id/personalized`).
    public struct Shelf: Decodable, Sendable, Identifiable {
        public enum Entities: Sendable {
            case items([LibraryItem])
            case series([Series])
            case authors([Author])
        }
        public let id: String
        public let label: String
        public let type: String
        public let entities: Entities

        private enum CodingKeys: String, CodingKey { case id, label, type, entities }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? id
            type = try container.decode(String.self, forKey: .type)
            switch type {
            case "series": entities = .series(try container.decode(LenientList<Series>.self, forKey: .entities).elements)
            case "authors": entities = .authors(try container.decode(LenientList<Author>.self, forKey: .entities).elements)
            default: entities = .items(try container.decode(LenientList<LibraryItem>.self, forKey: .entities).elements)
            }
        }
    }

    /// Wyniki wyszukiwania (`GET /api/libraries/:id/search`).
    public struct SearchResults: Decodable, Sendable {
        public struct Hit: Decodable, Sendable { public let libraryItem: LibraryItem }
        public struct SeriesHit: Decodable, Sendable {
            public struct Info: Decodable, Sendable { public let id: String; public let name: String }
            public let series: Info
            public let books: LenientList<LibraryItem>?
        }
        public struct Count: Decodable, Sendable {
            public let name: String
            public let numBooks: Int?
            public let numItems: Int?
            public var count: Int { numBooks ?? numItems ?? 0 }
        }
        public let book: LenientList<Hit>?
        public let podcast: LenientList<Hit>?
        public let episodes: LenientList<Hit>?
        public let series: LenientList<SeriesHit>?
        public let authors: LenientList<Author>?
        public let narrators: LenientList<Count>?
        public let tags: LenientList<Count>?
        public let genres: LenientList<Count>?

        public var isEmpty: Bool {
            [book?.elements.count, podcast?.elements.count, episodes?.elements.count, series?.elements.count,
             authors?.elements.count, narrators?.elements.count, tags?.elements.count, genres?.elements.count]
                .allSatisfy { ($0 ?? 0) == 0 }
        }
    }

    /// Pełna pozycja (`GET /api/items/:id?expanded=1`): wszystko, co pokazuje strona książki lub podcastu.
    public struct ItemDetail: Decodable, Sendable, Identifiable {
        public struct Media: Decodable, Sendable {
            public struct Metadata: Decodable, Sendable {
                public let title: String?
                public let subtitle: String?
                public let authors: [NamedRef]?
                public let narrators: [String]?
                public let series: OneOrMany<SeriesRef>?
                public let genres: [String]?
                public let publishedYear: String?
                public let publishedDate: String?
                public let publisher: String?
                /// HTML.
                public let description: String?
                public let isbn: String?
                public let asin: String?
                public let language: String?
                public let explicit: Bool?
                public let abridged: Bool?
                // Podcast
                public let author: String?
                public let releaseDate: String?
                public let type: String?
                public let feedUrl: String?
                public let imageUrl: String?
                public let itunesPageUrl: String?
                public let itunesId: String?
                public let itunesArtistId: String?
            }
            public struct Chapter: Decodable, Sendable, Identifiable, Hashable {
                public let id: Int
                public let start: Double
                public let end: Double
                public let title: String
            }
            public struct FileMetadata: Decodable, Sendable, Hashable {
                public let filename: String?
                public let path: String?
                public let relPath: String?
                public let size: Double?
            }
            public struct EbookFile: Decodable, Sendable, Hashable {
                public let ino: String?
                public let ebookFormat: String?
                public let metadata: FileMetadata?
            }
            public struct Track: Decodable, Sendable, Identifiable, Hashable {
                public let index: Int
                public let ino: String?
                public let duration: Double?
                public let startOffset: Double?
                public let codec: String?
                public let bitRate: Double?
                public let metadata: FileMetadata?
                public var id: Int { index }
            }

            public let metadata: Metadata
            public let coverPath: String?
            public let tags: [String]?
            public let duration: Double?
            public let size: Double?
            public let chapters: [Chapter]?
            /// Podstawowy e-book książki (`Book.ebookFile`).
            public let ebookFile: EbookFile?
            public let tracks: LenientList<Track>?
            /// Wszystkie pliki audio, także wykluczone (zakładka „Pliki”, etap 9e).
            public let audioFiles: LenientList<AudiobookshelfClient.AudioFileEntry>?
            public let episodes: LenientList<PodcastEpisode>?
            public let numEpisodes: Int?
            // Podcast: automatyczne pobieranie (`Podcast.toOldJSON`).
            public let autoDownloadEpisodes: Bool?
            public let autoDownloadSchedule: String?
            public let lastEpisodeCheck: Double?
            public let maxEpisodesToKeep: Int?
            public let maxNewEpisodesToDownload: Int?
        }
        public struct LibraryFile: Decodable, Sendable, Identifiable, Hashable {
            public let ino: String
            public let metadata: Media.FileMetadata
            public let fileType: String?
            /// E-book dodatkowy (nie podstawowy); `nil` dla plików innych typów.
            public let isSupplementary: Bool?
            public var id: String { ino }
            public var isEbook: Bool { fileType == "ebook" }
        }

        public let id: String
        public let libraryId: String
        public let mediaType: String
        public let path: String?
        /// Pozycja z jednego pliku leżącego wprost w folderze biblioteki (`path` to wtedy plik).
        public let isFile: Bool?
        /// Pliki zniknęły z dysku (skan oznaczył pozycję jako brakującą).
        public let isMissing: Bool?
        public let size: Double?
        public let addedAt: Double?
        public let media: Media
        public let libraryFiles: LenientList<LibraryFile>?

        public var title: String { media.metadata.title ?? "Bez tytułu" }
        public var isPodcast: Bool { mediaType == "podcast" }
    }

    public struct Bookmark: Decodable, Sendable, Hashable, Identifiable {
        public let libraryItemId: String
        public let time: Double
        public let title: String
        public let createdAt: Double?
        public var id: String { "\(libraryItemId)@\(time)" }
    }

    /// Stan użytkownika z `GET /api/me` (i zdarzenia `user_updated`).
    public struct MeState: Decodable, Sendable {
        public let mediaProgress: LenientList<MediaProgress>
        public let bookmarks: LenientList<Bookmark>?
    }

    /// Statystyki słuchania (`GET /api/me/listening-stats`).
    public struct ListeningStats: Decodable, Sendable {
        public struct ItemStat: Decodable, Sendable, Identifiable {
            public struct MediaMetadata: Decodable, Sendable {
                public let title: String?
                public let authorName: String?
                public let author: String?
            }
            public let id: String
            public let timeListening: Double
            public let mediaMetadata: MediaMetadata?
            public let lastUpdate: Double?
        }
        public struct Session: Decodable, Sendable, Identifiable {
            public let id: String
            public let libraryItemId: String?
            public let displayTitle: String?
            public let displayAuthor: String?
            public let timeListening: Double?
            public let updatedAt: Double?
            public let date: String?
        }
        public let totalTime: Double
        public let items: [String: ItemStat]
        public let days: [String: Double]
        public let today: Double?
        public let recentSessions: LenientList<Session>?
    }

    // MARK: Listy biblioteki

    /// Filtr listy pozycji w zapisie web UI: `grupa.encodeURIComponent(base64(wartość))`.
    public static func filter(_ group: String, _ value: String) -> String {
        let base64 = Data(value.utf8).base64EncodedString()
        return group + "." + (base64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? base64)
    }

    /// Jedna strona pozycji biblioteki z sortowaniem i filtrem.
    public func itemsPage(libraryID: String, page: Int, limit: Int, sort: String, descending: Bool, filter: String?, token: String) async throws -> Page<LibraryItem> {
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "minified", value: "1"),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "desc", value: descending ? "1" : "0"),
            URLQueryItem(name: "include", value: "numEpisodesIncomplete"),
        ]
        if let filter { query.append(URLQueryItem(name: "filter", value: filter)) }
        return try decode(Page<LibraryItem>.self, from: await send("GET", "api/libraries/\(libraryID)/items", query: query, token: token))
    }

    public func seriesPage(libraryID: String, page: Int, limit: Int, sort: String, descending: Bool, token: String) async throws -> Page<Series> {
        let query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "minified", value: "1"),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "desc", value: descending ? "1" : "0"),
        ]
        return try decode(Page<Series>.self, from: await send("GET", "api/libraries/\(libraryID)/series", query: query, token: token))
    }

    /// Nazwa i opis serii (książki — `itemsPage` z filtrem serii, posortowane po tomie).
    public func series(libraryID: String, seriesID: String, token: String) async throws -> Series {
        try decode(Series.self, from: await send("GET", "api/libraries/\(libraryID)/series/\(seriesID)", token: token))
    }

    public func authorsPage(libraryID: String, page: Int, limit: Int, sort: String, descending: Bool, token: String) async throws -> Page<Author> {
        let query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "minified", value: "1"),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "desc", value: descending ? "1" : "0"),
        ]
        return try decode(Page<Author>.self, from: await send("GET", "api/libraries/\(libraryID)/authors", query: query, token: token))
    }

    public func author(id: String, token: String) async throws -> AuthorDetail {
        let query = [URLQueryItem(name: "include", value: "items,series")]
        return try decode(AuthorDetail.self, from: await send("GET", "api/authors/\(id)", query: query, token: token))
    }

    public func authorImage(id: String, width: Int, token: String) async throws -> Data {
        let query = [URLQueryItem(name: "width", value: String(width)), URLQueryItem(name: "format", value: "jpeg")]
        return try await send("GET", "api/authors/\(id)/image", query: query, token: token)
    }

    public func narrators(libraryID: String, token: String) async throws -> [Narrator] {
        struct Response: Decodable { let narrators: LenientList<Narrator> }
        return try decode(Response.self, from: await send("GET", "api/libraries/\(libraryID)/narrators", token: token)).narrators.elements
    }

    public func collections(libraryID: String, token: String) async throws -> [Collection] {
        let query = [URLQueryItem(name: "limit", value: "0"), URLQueryItem(name: "minified", value: "1")]
        return try decode(Page<Collection>.self, from: await send("GET", "api/libraries/\(libraryID)/collections", query: query, token: token)).results.elements
    }

    public func playlists(libraryID: String, token: String) async throws -> [Playlist] {
        let query = [URLQueryItem(name: "limit", value: "0")]
        return try decode(Page<Playlist>.self, from: await send("GET", "api/libraries/\(libraryID)/playlists", query: query, token: token)).results.elements
    }

    public func filterData(libraryID: String, token: String) async throws -> FilterData {
        try decode(FilterData.self, from: await send("GET", "api/libraries/\(libraryID)/filterdata", token: token))
    }

    public func personalized(libraryID: String, token: String) async throws -> [Shelf] {
        let query = [URLQueryItem(name: "include", value: "numEpisodesIncomplete"), URLQueryItem(name: "limit", value: "12")]
        return try decode(LenientList<Shelf>.self, from: await send("GET", "api/libraries/\(libraryID)/personalized", query: query, token: token)).elements
    }

    public func search(libraryID: String, query text: String, token: String) async throws -> SearchResults {
        let query = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "limit", value: "12")]
        return try decode(SearchResults.self, from: await send("GET", "api/libraries/\(libraryID)/search", query: query, token: token))
    }

    /// Najnowsze nieukończone odcinki biblioteki podcastów.
    public func recentEpisodes(libraryID: String, page: Int, limit: Int, token: String) async throws -> [PodcastEpisode] {
        struct Response: Decodable { let episodes: LenientList<PodcastEpisode> }
        let query = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "page", value: String(page))]
        return try decode(Response.self, from: await send("GET", "api/libraries/\(libraryID)/recent-episodes", query: query, token: token)).episodes.elements
    }

    public func item(id: String, token: String) async throws -> ItemDetail {
        let query = [URLQueryItem(name: "expanded", value: "1")]
        return try decode(ItemDetail.self, from: await send("GET", "api/items/\(id)", query: query, token: token))
    }

    // MARK: Postęp

    /// Usuwa postęp (web UI: „Wyzeruj postęp”). `id` to identyfikator rekordu postępu, nie pozycji.
    public func deleteProgress(id: String, token: String) async throws {
        _ = try await send("DELETE", "api/me/progress/\(id)", token: token)
    }

    /// Zmienia tylko „ukończone” (bez pozycji — tak jak przycisk w web UI).
    public func setFinished(itemID: String, episodeID: String?, finished: Bool, token: String) async throws {
        struct Body: Encodable { let isFinished: Bool }
        _ = try await send("PATCH", progressPath(itemID, episodeID), body: Body(isFinished: finished), token: token)
    }

    public struct BatchProgress: Encodable, Sendable {
        public let libraryItemId: String
        public let episodeId: String?
        public let isFinished: Bool

        public init(libraryItemId: String, episodeId: String?, isFinished: Bool) {
            self.libraryItemId = libraryItemId
            self.episodeId = episodeId
            self.isFinished = isFinished
        }
    }

    /// Ukończone/nieukończone dla wielu pozycji naraz (cała seria, wszystkie odcinki).
    public func setFinished(_ entries: [BatchProgress], token: String) async throws {
        _ = try await send("PATCH", "api/me/progress/batch/update", body: entries, token: token)
    }

    public func removeFromContinueListening(progressID: String, token: String) async throws {
        _ = try await send("GET", "api/me/progress/\(progressID)/remove-from-continue-listening", token: token)
    }

    // MARK: Zakładki

    private struct BookmarkBody: Encodable {
        public let time: Double
        public let title: String
    }

    public func createBookmark(itemID: String, time: Double, title: String, token: String) async throws {
        _ = try await send("POST", "api/me/item/\(itemID)/bookmark", body: BookmarkBody(time: time, title: title), token: token)
    }

    /// Zmienia tytuł zakładki (serwer szuka jej po czasie).
    public func updateBookmark(itemID: String, time: Double, title: String, token: String) async throws {
        _ = try await send("PATCH", "api/me/item/\(itemID)/bookmark", body: BookmarkBody(time: time, title: title), token: token)
    }

    public func deleteBookmark(itemID: String, time: Double, token: String) async throws {
        _ = try await send("DELETE", "api/me/item/\(itemID)/bookmark/\(Self.number(time))", token: token)
    }

    /// Czas w ścieżce tak, jak zapisał go serwer (bez „.0” dla pełnych sekund).
    private static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }

    // MARK: Playlisty (własne playlisty użytkownika)

    public struct PlaylistEntry: Encodable, Sendable, Hashable {
        public let libraryItemId: String
        public let episodeId: String?

        public init(libraryItemId: String, episodeId: String?) {
            self.libraryItemId = libraryItemId
            self.episodeId = episodeId
        }
    }

    public func createPlaylist(libraryID: String, name: String, items: [PlaylistEntry], token: String) async throws -> Playlist {
        struct Body: Encodable {
            let libraryId: String
            let name: String
            let items: [PlaylistEntry]
        }
        return try decode(Playlist.self, from: await send("POST", "api/playlists", body: Body(libraryId: libraryID, name: name, items: items), token: token))
    }

    public func renamePlaylist(id: String, name: String, token: String) async throws {
        struct Body: Encodable { let name: String }
        _ = try await send("PATCH", "api/playlists/\(id)", body: Body(name: name), token: token)
    }

    public func deletePlaylist(id: String, token: String) async throws {
        _ = try await send("DELETE", "api/playlists/\(id)", token: token)
    }

    public func addToPlaylist(id: String, _ entry: PlaylistEntry, token: String) async throws {
        _ = try await send("POST", "api/playlists/\(id)/item", body: entry, token: token)
    }

    public func removeFromPlaylist(id: String, _ entry: PlaylistEntry, token: String) async throws {
        let path = entry.episodeId.map { "api/playlists/\(id)/item/\(entry.libraryItemId)/\($0)" } ?? "api/playlists/\(id)/item/\(entry.libraryItemId)"
        _ = try await send("DELETE", path, token: token)
    }

    // MARK: Statystyki

    public func listeningStats(token: String) async throws -> ListeningStats {
        try decode(ListeningStats.self, from: await send("GET", "api/me/listening-stats", token: token))
    }
}
