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

    struct Page<Element: Decodable & Sendable>: Decodable, Sendable {
        let results: LenientList<Element>
        /// Brak przy `collapseseries` z filtrem serii — tej kombinacji nie używamy.
        let total: Int?
    }

    struct NamedRef: Decodable, Sendable, Hashable, Identifiable {
        let id: String
        let name: String
    }

    /// Seria z książkami w kolejności tomów (`/libraries/:id/series`, półka „Ostatnie serie”).
    struct Series: Decodable, Sendable, Identifiable {
        let id: String
        let name: String
        let description: String?
        let books: LenientList<LibraryItem>?

        var items: [LibraryItem] { books?.elements ?? [] }
    }

    struct Author: Decodable, Sendable, Hashable, Identifiable {
        let id: String
        let name: String
        let description: String?
        let imagePath: String?
        let numBooks: Int?
        let updatedAt: Double?
    }

    /// Autor z książkami i seriami (`GET /api/authors/:id?include=items,series`).
    struct AuthorDetail: Decodable, Sendable {
        struct AuthorSeries: Decodable, Sendable, Identifiable {
            let id: String
            let name: String
            let items: LenientList<LibraryItem>
        }
        let id: String
        let name: String
        let description: String?
        let imagePath: String?
        let libraryItems: LenientList<LibraryItem>?
        let series: LenientList<AuthorSeries>?
    }

    struct Narrator: Decodable, Sendable, Hashable, Identifiable {
        /// Już zakodowana nazwa (`encodeURIComponent(base64(name))`) — gotowa do filtra.
        let id: String
        let name: String
        let numBooks: Int?
    }

    struct Collection: Decodable, Sendable, Identifiable {
        let id: String
        let name: String
        let description: String?
        let books: LenientList<LibraryItem>
    }

    struct Playlist: Decodable, Sendable, Identifiable {
        struct Item: Decodable, Sendable, Hashable {
            let libraryItemId: String
            let episodeId: String?
            let libraryItem: LibraryItem?
            let episode: PodcastEpisode?
        }
        let id: String
        let name: String
        let description: String?
        let libraryId: String
        let items: LenientList<Item>
    }

    /// Wartości do filtrów (`GET /api/libraries/:id/filterdata`). Serwer ich nie zawęża do
    /// uprawnień użytkownika — tak samo jak web UI.
    struct FilterData: Decodable, Sendable {
        let authors: [NamedRef]?
        let genres: [String]?
        let tags: [String]?
        let series: [NamedRef]?
        let narrators: [String]?
        let languages: [String]?
        let publishers: [String]?
        let publishedDecades: [String]?
    }

    /// Półka strony startowej (`GET /api/libraries/:id/personalized`).
    struct Shelf: Decodable, Sendable, Identifiable {
        enum Entities: Sendable {
            case items([LibraryItem])
            case series([Series])
            case authors([Author])
        }
        let id: String
        let label: String
        let type: String
        let entities: Entities

        private enum CodingKeys: String, CodingKey { case id, label, type, entities }

        init(from decoder: any Decoder) throws {
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
    struct SearchResults: Decodable, Sendable {
        struct Hit: Decodable, Sendable { let libraryItem: LibraryItem }
        struct SeriesHit: Decodable, Sendable {
            struct Info: Decodable, Sendable { let id: String; let name: String }
            let series: Info
            let books: LenientList<LibraryItem>?
        }
        struct Count: Decodable, Sendable {
            let name: String
            let numBooks: Int?
            let numItems: Int?
            var count: Int { numBooks ?? numItems ?? 0 }
        }
        let book: LenientList<Hit>?
        let podcast: LenientList<Hit>?
        let episodes: LenientList<Hit>?
        let series: LenientList<SeriesHit>?
        let authors: LenientList<Author>?
        let narrators: LenientList<Count>?
        let tags: LenientList<Count>?
        let genres: LenientList<Count>?

        var isEmpty: Bool {
            [book?.elements.count, podcast?.elements.count, episodes?.elements.count, series?.elements.count,
             authors?.elements.count, narrators?.elements.count, tags?.elements.count, genres?.elements.count]
                .allSatisfy { ($0 ?? 0) == 0 }
        }
    }

    /// Pełna pozycja (`GET /api/items/:id?expanded=1`): wszystko, co pokazuje strona książki lub podcastu.
    struct ItemDetail: Decodable, Sendable, Identifiable {
        struct Media: Decodable, Sendable {
            struct Metadata: Decodable, Sendable {
                let title: String?
                let subtitle: String?
                let authors: [NamedRef]?
                let narrators: [String]?
                let series: OneOrMany<SeriesRef>?
                let genres: [String]?
                let publishedYear: String?
                let publishedDate: String?
                let publisher: String?
                /// HTML.
                let description: String?
                let isbn: String?
                let asin: String?
                let language: String?
                let explicit: Bool?
                let abridged: Bool?
                // Podcast
                let author: String?
                let releaseDate: String?
                let type: String?
                let feedUrl: String?
                let imageUrl: String?
                let itunesPageUrl: String?
                let itunesId: String?
                let itunesArtistId: String?
            }
            struct Chapter: Decodable, Sendable, Identifiable, Hashable {
                let id: Int
                let start: Double
                let end: Double
                let title: String
            }
            struct FileMetadata: Decodable, Sendable, Hashable {
                let filename: String?
                let path: String?
                let relPath: String?
                let size: Double?
            }
            struct Track: Decodable, Sendable, Identifiable, Hashable {
                let index: Int
                let ino: String?
                let duration: Double?
                let startOffset: Double?
                let codec: String?
                let bitRate: Double?
                let metadata: FileMetadata?
                var id: Int { index }
            }

            let metadata: Metadata
            let coverPath: String?
            let tags: [String]?
            let duration: Double?
            let size: Double?
            let chapters: [Chapter]?
            let tracks: LenientList<Track>?
            let episodes: LenientList<PodcastEpisode>?
            let numEpisodes: Int?
            // Podcast: automatyczne pobieranie (`Podcast.toOldJSON`).
            let autoDownloadEpisodes: Bool?
            let autoDownloadSchedule: String?
            let lastEpisodeCheck: Double?
            let maxEpisodesToKeep: Int?
            let maxNewEpisodesToDownload: Int?
        }
        struct LibraryFile: Decodable, Sendable, Identifiable, Hashable {
            let ino: String
            let metadata: Media.FileMetadata
            let fileType: String?
            var id: String { ino }
        }

        let id: String
        let libraryId: String
        let mediaType: String
        let path: String?
        let size: Double?
        let addedAt: Double?
        let media: Media
        let libraryFiles: LenientList<LibraryFile>?

        var title: String { media.metadata.title ?? "Bez tytułu" }
        var isPodcast: Bool { mediaType == "podcast" }
    }

    struct Bookmark: Decodable, Sendable, Hashable, Identifiable {
        let libraryItemId: String
        let time: Double
        let title: String
        let createdAt: Double?
        var id: String { "\(libraryItemId)@\(time)" }
    }

    /// Stan użytkownika z `GET /api/me` (i zdarzenia `user_updated`).
    struct MeState: Decodable, Sendable {
        let mediaProgress: LenientList<MediaProgress>
        let bookmarks: LenientList<Bookmark>?
    }

    /// Statystyki słuchania (`GET /api/me/listening-stats`).
    struct ListeningStats: Decodable, Sendable {
        struct ItemStat: Decodable, Sendable, Identifiable {
            struct MediaMetadata: Decodable, Sendable {
                let title: String?
                let authorName: String?
                let author: String?
            }
            let id: String
            let timeListening: Double
            let mediaMetadata: MediaMetadata?
            let lastUpdate: Double?
        }
        struct Session: Decodable, Sendable, Identifiable {
            let id: String
            let libraryItemId: String?
            let displayTitle: String?
            let displayAuthor: String?
            let timeListening: Double?
            let updatedAt: Double?
            let date: String?
        }
        let totalTime: Double
        let items: [String: ItemStat]
        let days: [String: Double]
        let today: Double?
        let recentSessions: LenientList<Session>?
    }

    // MARK: Listy biblioteki

    /// Filtr listy pozycji w zapisie web UI: `grupa.encodeURIComponent(base64(wartość))`.
    static func filter(_ group: String, _ value: String) -> String {
        let base64 = Data(value.utf8).base64EncodedString()
        return group + "." + (base64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? base64)
    }

    /// Jedna strona pozycji biblioteki z sortowaniem i filtrem.
    func itemsPage(libraryID: String, page: Int, limit: Int, sort: String, descending: Bool, filter: String?, token: String) async throws -> Page<LibraryItem> {
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

    func seriesPage(libraryID: String, page: Int, limit: Int, sort: String, descending: Bool, token: String) async throws -> Page<Series> {
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
    func series(libraryID: String, seriesID: String, token: String) async throws -> Series {
        try decode(Series.self, from: await send("GET", "api/libraries/\(libraryID)/series/\(seriesID)", token: token))
    }

    func authorsPage(libraryID: String, page: Int, limit: Int, sort: String, descending: Bool, token: String) async throws -> Page<Author> {
        let query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "minified", value: "1"),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "desc", value: descending ? "1" : "0"),
        ]
        return try decode(Page<Author>.self, from: await send("GET", "api/libraries/\(libraryID)/authors", query: query, token: token))
    }

    func author(id: String, token: String) async throws -> AuthorDetail {
        let query = [URLQueryItem(name: "include", value: "items,series")]
        return try decode(AuthorDetail.self, from: await send("GET", "api/authors/\(id)", query: query, token: token))
    }

    func authorImage(id: String, width: Int, token: String) async throws -> Data {
        let query = [URLQueryItem(name: "width", value: String(width)), URLQueryItem(name: "format", value: "jpeg")]
        return try await send("GET", "api/authors/\(id)/image", query: query, token: token)
    }

    func narrators(libraryID: String, token: String) async throws -> [Narrator] {
        struct Response: Decodable { let narrators: LenientList<Narrator> }
        return try decode(Response.self, from: await send("GET", "api/libraries/\(libraryID)/narrators", token: token)).narrators.elements
    }

    func collections(libraryID: String, token: String) async throws -> [Collection] {
        let query = [URLQueryItem(name: "limit", value: "0"), URLQueryItem(name: "minified", value: "1")]
        return try decode(Page<Collection>.self, from: await send("GET", "api/libraries/\(libraryID)/collections", query: query, token: token)).results.elements
    }

    func playlists(libraryID: String, token: String) async throws -> [Playlist] {
        let query = [URLQueryItem(name: "limit", value: "0")]
        return try decode(Page<Playlist>.self, from: await send("GET", "api/libraries/\(libraryID)/playlists", query: query, token: token)).results.elements
    }

    func filterData(libraryID: String, token: String) async throws -> FilterData {
        try decode(FilterData.self, from: await send("GET", "api/libraries/\(libraryID)/filterdata", token: token))
    }

    func personalized(libraryID: String, token: String) async throws -> [Shelf] {
        let query = [URLQueryItem(name: "include", value: "numEpisodesIncomplete"), URLQueryItem(name: "limit", value: "12")]
        return try decode(LenientList<Shelf>.self, from: await send("GET", "api/libraries/\(libraryID)/personalized", query: query, token: token)).elements
    }

    func search(libraryID: String, query text: String, token: String) async throws -> SearchResults {
        let query = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "limit", value: "12")]
        return try decode(SearchResults.self, from: await send("GET", "api/libraries/\(libraryID)/search", query: query, token: token))
    }

    /// Najnowsze nieukończone odcinki biblioteki podcastów.
    func recentEpisodes(libraryID: String, page: Int, limit: Int, token: String) async throws -> [PodcastEpisode] {
        struct Response: Decodable { let episodes: LenientList<PodcastEpisode> }
        let query = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "page", value: String(page))]
        return try decode(Response.self, from: await send("GET", "api/libraries/\(libraryID)/recent-episodes", query: query, token: token)).episodes.elements
    }

    func item(id: String, token: String) async throws -> ItemDetail {
        let query = [URLQueryItem(name: "expanded", value: "1")]
        return try decode(ItemDetail.self, from: await send("GET", "api/items/\(id)", query: query, token: token))
    }

    // MARK: Postęp

    /// Usuwa postęp (web UI: „Wyzeruj postęp”). `id` to identyfikator rekordu postępu, nie pozycji.
    func deleteProgress(id: String, token: String) async throws {
        _ = try await send("DELETE", "api/me/progress/\(id)", token: token)
    }

    /// Zmienia tylko „ukończone” (bez pozycji — tak jak przycisk w web UI).
    func setFinished(itemID: String, episodeID: String?, finished: Bool, token: String) async throws {
        struct Body: Encodable { let isFinished: Bool }
        _ = try await send("PATCH", progressPath(itemID, episodeID), body: Body(isFinished: finished), token: token)
    }

    struct BatchProgress: Encodable, Sendable {
        let libraryItemId: String
        let episodeId: String?
        let isFinished: Bool
    }

    /// Ukończone/nieukończone dla wielu pozycji naraz (cała seria, wszystkie odcinki).
    func setFinished(_ entries: [BatchProgress], token: String) async throws {
        _ = try await send("PATCH", "api/me/progress/batch/update", body: entries, token: token)
    }

    func removeFromContinueListening(progressID: String, token: String) async throws {
        _ = try await send("GET", "api/me/progress/\(progressID)/remove-from-continue-listening", token: token)
    }

    // MARK: Zakładki

    private struct BookmarkBody: Encodable {
        let time: Double
        let title: String
    }

    func createBookmark(itemID: String, time: Double, title: String, token: String) async throws {
        _ = try await send("POST", "api/me/item/\(itemID)/bookmark", body: BookmarkBody(time: time, title: title), token: token)
    }

    /// Zmienia tytuł zakładki (serwer szuka jej po czasie).
    func updateBookmark(itemID: String, time: Double, title: String, token: String) async throws {
        _ = try await send("PATCH", "api/me/item/\(itemID)/bookmark", body: BookmarkBody(time: time, title: title), token: token)
    }

    func deleteBookmark(itemID: String, time: Double, token: String) async throws {
        _ = try await send("DELETE", "api/me/item/\(itemID)/bookmark/\(Self.number(time))", token: token)
    }

    /// Czas w ścieżce tak, jak zapisał go serwer (bez „.0” dla pełnych sekund).
    private static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }

    // MARK: Playlisty (własne playlisty użytkownika)

    struct PlaylistEntry: Encodable, Sendable, Hashable {
        let libraryItemId: String
        let episodeId: String?
    }

    func createPlaylist(libraryID: String, name: String, items: [PlaylistEntry], token: String) async throws -> Playlist {
        struct Body: Encodable {
            let libraryId: String
            let name: String
            let items: [PlaylistEntry]
        }
        return try decode(Playlist.self, from: await send("POST", "api/playlists", body: Body(libraryId: libraryID, name: name, items: items), token: token))
    }

    func renamePlaylist(id: String, name: String, token: String) async throws {
        struct Body: Encodable { let name: String }
        _ = try await send("PATCH", "api/playlists/\(id)", body: Body(name: name), token: token)
    }

    func deletePlaylist(id: String, token: String) async throws {
        _ = try await send("DELETE", "api/playlists/\(id)", token: token)
    }

    func addToPlaylist(id: String, _ entry: PlaylistEntry, token: String) async throws {
        _ = try await send("POST", "api/playlists/\(id)/item", body: entry, token: token)
    }

    func removeFromPlaylist(id: String, _ entry: PlaylistEntry, token: String) async throws {
        let path = entry.episodeId.map { "api/playlists/\(id)/item/\(entry.libraryItemId)/\($0)" } ?? "api/playlists/\(id)/item/\(entry.libraryItemId)"
        _ = try await send("DELETE", path, token: token)
    }

    // MARK: Statystyki

    func listeningStats(token: String) async throws -> ListeningStats {
        try decode(ListeningStats.self, from: await send("GET", "api/me/listening-stats", token: token))
    }
}
