import Foundation

/// Punkty API zarządzania podcastami (etap 9d). Prawie wszystkie są w upstreamie tylko dla
/// administratora (`isAdminOrUp`), więc woła je wyłącznie `ItemManager` tokenem konta root.
///
/// Kształty z upstreamu v2.38.0: `server/controllers/PodcastController.js` (tworzenie, kanał,
/// OPML, pobieranie, odcinki), `SearchController.findPodcasts` (iTunes), `LibraryController`
/// (`episode-downloads`, `podcast-titles`), `utils/podcastUtils.js` (kształt kanału),
/// `objects/PodcastEpisodeDownload.toJSONForClient` (kolejka) i `models/Podcast.updateFromRequest`.
extension AudiobookshelfClient {
    // MARK: Dowolny JSON

    /// Dowolna wartość JSON. Odcinki z kanału wracają do serwera (`download-episodes`) dokładnie
    /// w kształcie, w jakim przyszły — z rozdziałami, `guid` i polami, których okno nie pokazuje.
    enum JSONValue: Codable, Sendable, Hashable {
        case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
            else { self = .object(try c.decode([String: JSONValue].self)) }
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            case .bool(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .null: try c.encodeNil()
            }
        }

        subscript(key: String) -> JSONValue? {
            if case .object(let dict) = self { return dict[key] }
            return nil
        }

        var string: String? {
            switch self {
            case .string(let v): let t = v.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t
            case .number(let v): return v.rounded() == v ? String(Int(v)) : String(v)
            default: return nil
            }
        }

        var number: Double? {
            switch self {
            case .number(let v): v
            case .string(let v): Double(v)
            default: nil
            }
        }
    }

    // MARK: Wyszukiwanie i kanał

    /// Wynik iTunes (`iTunes.cleanPodcast`).
    struct PodcastSearchResult: Decodable, Sendable, Identifiable, Hashable {
        let id: Int?
        let artistId: Int?
        let title: String?
        let artistName: String?
        let description: String?
        let releaseDate: String?
        let genres: [String]?
        let cover: String?
        let trackCount: Int?
        let feedUrl: String?
        let pageUrl: String?
        let explicit: Bool?

        var key: String { feedUrl ?? title ?? "" }
    }

    /// Kanał RSS po przetworzeniu przez serwer (`podcastUtils.cleanPodcastJson`).
    struct PodcastFeed: Decodable, Sendable {
        struct Metadata: Decodable, Sendable {
            let title: String?
            let author: String?
            let description: String?
            let descriptionPlain: String?
            let image: String?
            let categories: [String]?
            let feedUrl: String?
            let language: String?
            /// `yes`/`true`/`no`… jak w kanale.
            let explicit: String?
            let type: String?
            let link: String?

            init(from decoder: any Decoder) throws {
                // Pola z kanału bywają liczbą albo obiektem — każde czytane osobno i pobłażliwie.
                let raw = try JSONValue(from: decoder)
                title = raw["title"]?.string
                author = raw["author"]?.string
                description = raw["description"]?.string
                descriptionPlain = raw["descriptionPlain"]?.string
                image = raw["image"]?.string
                if case .array(let list) = raw["categories"] { categories = list.compactMap(\.string) } else { categories = nil }
                feedUrl = raw["feedUrl"]?.string
                language = raw["language"]?.string
                explicit = raw["explicit"]?.string
                type = raw["type"]?.string
                link = raw["link"]?.string
            }

            var isExplicit: Bool { ["yes", "true", "explicit"].contains((explicit ?? "").lowercased()) }
        }

        let metadata: Metadata
        let episodes: [FeedEpisode]

        private enum CodingKeys: String, CodingKey { case metadata, episodes }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            metadata = try c.decode(Metadata.self, forKey: .metadata)
            let raw = (try? c.decodeIfPresent([JSONValue].self, forKey: .episodes)) ?? []
            episodes = raw.enumerated().map { FeedEpisode(raw: $1, index: $0) }
        }
    }

    /// Odcinek z kanału: surowy JSON (wraca do serwera bez zmian) i wygodne pola do listy.
    struct FeedEpisode: Sendable, Identifiable, Hashable {
        let raw: JSONValue
        let index: Int

        var id: Int { index }
        var title: String { raw["title"]?.string ?? "Bez tytułu" }
        var subtitle: String? { raw["subtitle"]?.string }
        var descriptionPlain: String? { raw["descriptionPlain"]?.string ?? HTMLText.plain(raw["description"]?.string) }
        var season: String? { raw["season"]?.string }
        var episode: String? { raw["episode"]?.string }
        var episodeType: String? { raw["episodeType"]?.string }
        var guid: String? { raw["guid"]?.string }
        var url: String? { raw["enclosure"]?["url"]?.string }
        var durationSeconds: Double? { raw["durationSeconds"]?.number }
        var size: Double? { raw["enclosure"]?["length"]?.number }
        var published: Date? { raw["publishedAt"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) } }
    }

    /// Adres odcinka bez parametrów śledzących — tak `EpisodeFeed.vue` porównuje z pobranymi
    /// (zostaje tylko `id`, bo bywa częścią adresu pliku).
    static func cleanEpisodeURL(_ url: String) -> String {
        guard var components = URLComponents(string: url), let items = components.queryItems, !items.isEmpty else { return url }
        let kept = items.filter { $0.name == "id" }
        guard !kept.isEmpty else { return url }
        components.queryItems = kept
        return components.string ?? url
    }

    struct OPMLFeed: Decodable, Sendable, Identifiable, Hashable {
        let title: String?
        let feedUrl: String
        var id: String { feedUrl }
    }

    /// Podcast już w bibliotece (`GET /libraries/:id/podcast-titles`).
    struct PodcastTitle: Decodable, Sendable {
        let title: String?
        let itunesId: String?
        let libraryItemId: String
    }

    func searchPodcasts(term: String, country: String, token: String) async throws -> [PodcastSearchResult] {
        let query = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "country", value: country)]
        let data = try await send("GET", "api/search/podcast", query: query, token: token, timeout: 30)
        return try decode(LenientList<PodcastSearchResult>.self, from: data).elements.filter { $0.title != nil }
    }

    /// Serwer sam pobiera i przetwarza kanał; 404 znaczy „nie udało się pobrać albo to nie RSS”.
    func podcastFeed(url: String, token: String) async throws -> PodcastFeed {
        struct Body: Encodable { let rssFeed: String }
        struct Response: Decodable { let podcast: PodcastFeed }
        return try decode(Response.self, from: await send("POST", "api/podcasts/feed", body: Body(rssFeed: url), token: token, timeout: 60)).podcast
    }

    func parseOPML(_ text: String, token: String) async throws -> [OPMLFeed] {
        struct Body: Encodable { let opmlText: String }
        struct Response: Decodable { let feeds: LenientList<OPMLFeed>? }
        return try decode(Response.self, from: await send("POST", "api/podcasts/opml/parse", body: Body(opmlText: text), token: token)).feeds?.elements ?? []
    }

    /// Import w tle (zadanie serwera „OPML import”) — odpowiedź przychodzi od razu.
    func createPodcastsFromOPML(feeds: [String], libraryID: String, folderID: String, autoDownload: Bool, token: String) async throws {
        struct Body: Encodable {
            let feeds: [String]
            let libraryId: String
            let folderId: String
            let autoDownloadEpisodes: Bool
        }
        _ = try await send("POST", "api/podcasts/opml/create", body: Body(feeds: feeds, libraryId: libraryID, folderId: folderID, autoDownloadEpisodes: autoDownload), token: token)
    }

    func podcastTitles(libraryID: String, token: String) async throws -> [PodcastTitle] {
        struct Response: Decodable { let podcasts: LenientList<PodcastTitle>? }
        return try decode(Response.self, from: await send("GET", "api/libraries/\(libraryID)/podcast-titles", token: token)).podcasts?.elements ?? []
    }

    // MARK: Tworzenie

    /// Ciało `POST /api/podcasts` jak w `NewModal.vue`. `path` musi leżeć w folderze biblioteki.
    struct NewPodcast: Encodable, Sendable {
        struct Media: Encodable, Sendable {
            struct Metadata: Encodable, Sendable {
                var title: String
                var author: String
                var description: String
                var releaseDate: String
                var genres: [String]
                var feedUrl: String
                var imageUrl: String
                var itunesPageUrl: String
                var itunesId: String
                var itunesArtistId: String
                var language: String
                var explicit: Bool
                var type: String
            }
            var metadata: Metadata
            var autoDownloadEpisodes: Bool
        }
        var path: String
        var folderId: String
        var libraryId: String
        var media: Media
    }

    /// Zwraca id nowej pozycji.
    func createPodcast(_ podcast: NewPodcast, token: String) async throws -> String {
        struct Response: Decodable { let id: String }
        return try decode(Response.self, from: await send("POST", "api/podcasts", body: podcast, token: token, timeout: 60)).id
    }

    /// Nazwa folderu z tytułu — ta sama zasada co `$sanitizeFilename` web UI (pierwszy dwukropek → „ - ”).
    static func podcastFolderName(_ title: String) -> String {
        var name = title
        if let colon = name.firstIndex(of: ":") { name.replaceSubrange(colon...colon, with: " - ") }
        name = name.replacingOccurrences(of: "[/?<>\\\\:*|\"]", with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: "[\\x00-\\x1f\\x80-\\x9f\\n\\r]", with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: "[. ]+$", with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        name = name.trimmingCharacters(in: .whitespaces)
        if name.allSatisfy({ $0 == "." }) { name = "" }
        // 255 bajtów UTF-16 jak w upstreamie — tnie po znakach, nie w połowie.
        while name.utf16.count * 2 > 255 { name.removeLast() }
        return name
    }

    // MARK: Odcinki i pobieranie

    /// Pobieranie w kolejce serwera (`PodcastEpisodeDownload.toJSONForClient`).
    struct EpisodeDownload: Decodable, Sendable, Identifiable, Hashable {
        let id: String
        let episodeDisplayTitle: String?
        let libraryItemId: String
        let libraryId: String?
        let isFinished: Bool?
        let failed: Bool?
        let startedAt: Double?
        let createdAt: Double?
        let finishedAt: Double?
        let podcastTitle: String?
        let season: String?
        let episode: String?
        let publishedAt: Double?
        let guid: String?
        let url: String?
    }

    struct DownloadQueue: Decodable, Sendable {
        let currentDownload: EpisodeDownload?
        let queue: LenientList<EpisodeDownload>?
    }

    func episodeDownloadQueue(libraryID: String, token: String) async throws -> DownloadQueue {
        try decode(DownloadQueue.self, from: await send("GET", "api/libraries/\(libraryID)/episode-downloads", token: token))
    }

    /// Kolejkuje odcinki z kanału; serwer pobiera je po kolei w tle.
    func downloadEpisodes(itemID: String, _ episodes: [FeedEpisode], token: String) async throws {
        _ = try await send("POST", "api/podcasts/\(itemID)/download-episodes", body: episodes.map(\.raw), token: token, timeout: 60)
    }

    /// Nowe odcinki od `lastEpisodeCheck` (najwyżej `limit`) — od razu trafiają do kolejki pobierania.
    func checkNewEpisodes(itemID: String, limit: Int, token: String) async throws -> Int {
        struct Response: Decodable { let episodes: LenientList<JSONValue>? }
        let data = try await send("GET", "api/podcasts/\(itemID)/checknew", query: [URLQueryItem(name: "limit", value: String(limit))], token: token, timeout: 90)
        return try decode(Response.self, from: data).episodes?.elements.count ?? 0
    }

    func clearDownloadQueue(itemID: String, token: String) async throws {
        _ = try await send("GET", "api/podcasts/\(itemID)/clear-queue", token: token)
    }

    /// Uzupełnia opisy odcinków z kanału (`override` nadpisuje też wypełnione). Zwraca liczbę zmienionych.
    func quickMatchEpisodes(itemID: String, override: Bool, token: String) async throws -> Int {
        struct Response: Decodable { let numEpisodesUpdated: Int? }
        let query = override ? [URLQueryItem(name: "override", value: "1")] : []
        return try decode(Response.self, from: await send("POST", "api/podcasts/\(itemID)/match-episodes", query: query, token: token, timeout: 90)).numEpisodesUpdated ?? 0
    }

    /// Zmiana odcinka (`PodcastController.updateEpisode`): pola `nil` nie są wysyłane.
    struct EpisodeUpdate: Encodable, Sendable {
        var title: String?
        var subtitle: String?
        var description: String?
        var pubDate: String?
        var publishedAt: Double?
        var episode: String?
        var season: String?
        var episodeType: String?

        var isEmpty: Bool {
            title == nil && subtitle == nil && description == nil && pubDate == nil && publishedAt == nil
                && episode == nil && season == nil && episodeType == nil
        }
    }

    func updateEpisode(itemID: String, episodeID: String, _ update: EpisodeUpdate, token: String) async throws {
        _ = try await send("PATCH", "api/podcasts/\(itemID)/episode/\(episodeID)", body: update, token: token)
    }

    /// Usuwa odcinek z biblioteki (postęp i wpisy w playlistach też); `hard` kasuje również plik audio.
    func removeEpisode(itemID: String, episodeID: String, hard: Bool, token: String) async throws {
        let query = hard ? [URLQueryItem(name: "hard", value: "1")] : []
        _ = try await send("DELETE", "api/podcasts/\(itemID)/episode/\(episodeID)", query: query, token: token)
    }

    // MARK: Szczegóły i harmonogram

    /// `PATCH /api/items/:id/media` dla podcastu (`Podcast.updateFromRequest`). Pola `nil` nie są wysyłane.
    struct PodcastUpdate: Encodable, Sendable {
        struct Metadata: Encodable, Sendable {
            var title: String?
            var author: String?
            var description: String?
            var releaseDate: String?
            var genres: [String]?
            var feedUrl: String?
            var itunesPageUrl: String?
            var itunesId: String?
            var itunesArtistId: String?
            var language: String?
            var type: String?
            var explicit: Bool?

            var isEmpty: Bool {
                title == nil && author == nil && description == nil && releaseDate == nil && genres == nil && feedUrl == nil
                    && itunesPageUrl == nil && itunesId == nil && itunesArtistId == nil && language == nil && type == nil && explicit == nil
            }
        }
        var metadata: Metadata?
        var tags: [String]?
        var autoDownloadEpisodes: Bool?
        var autoDownloadSchedule: String?
        var maxEpisodesToKeep: Int?
        var maxNewEpisodesToDownload: Int?
        /// Milisekundy — od tej daty `checknew` szuka nowych odcinków.
        var lastEpisodeCheck: Double?

        var isEmpty: Bool {
            (metadata?.isEmpty ?? true) && tags == nil && autoDownloadEpisodes == nil && autoDownloadSchedule == nil
                && maxEpisodesToKeep == nil && maxNewEpisodesToDownload == nil && lastEpisodeCheck == nil
        }
    }

    func updatePodcast(itemID: String, _ update: PodcastUpdate, token: String) async throws -> Bool {
        struct Response: Decodable { let updated: Bool? }
        return try decode(Response.self, from: await send("PATCH", "api/items/\(itemID)/media", body: update, token: token)).updated ?? false
    }

    /// Okładki podcastu z iTunes (`/search/covers?podcast=1`).
    func searchPodcastCovers(title: String, token: String) async throws -> [String] {
        struct Response: Decodable { let results: LenientList<String>? }
        let query = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "podcast", value: "1")]
        let data = try await send("GET", "api/search/covers", query: query, token: token, timeout: 60)
        var seen = Set<String>()
        return (try decode(Response.self, from: data).results?.elements ?? []).filter { seen.insert($0).inserted }
    }
}
