// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
    public enum JSONValue: Codable, Sendable, Hashable {
        case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

        public init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
            else { self = .object(try c.decode([String: JSONValue].self)) }
        }

        public func encode(to encoder: any Encoder) throws {
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

        public subscript(key: String) -> JSONValue? {
            if case .object(let dict) = self { return dict[key] }
            return nil
        }

        public var string: String? {
            switch self {
            case .string(let v): let t = v.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t
            case .number(let v): return v.rounded() == v ? String(Int(v)) : String(v)
            default: return nil
            }
        }

        public var number: Double? {
            switch self {
            case .number(let v): v
            case .string(let v): Double(v)
            default: nil
            }
        }
    }

    // MARK: Wyszukiwanie i kanał

    /// Wynik iTunes (`iTunes.cleanPodcast`).
    public struct PodcastSearchResult: Decodable, Sendable, Identifiable, Hashable {
        public let id: Int?
        public let artistId: Int?
        public let title: String?
        public let artistName: String?
        public let description: String?
        public let releaseDate: String?
        public let genres: [String]?
        public let cover: String?
        public let trackCount: Int?
        public let feedUrl: String?
        public let pageUrl: String?
        public let explicit: Bool?
        /// Katalog, z którego przyszedł wynik; `nil` — iTunes przez serwer.
        public var source: PodcastDirectory? = nil

        public var key: String { feedUrl ?? title ?? "" }

        public init(id: Int? = nil, artistId: Int? = nil, title: String?, artistName: String?, description: String?, releaseDate: String? = nil,
                    genres: [String]?, cover: String?, trackCount: Int?, feedUrl: String?, pageUrl: String? = nil, explicit: Bool?,
                    source: PodcastDirectory?) {
            self.id = id
            self.artistId = artistId
            self.title = title
            self.artistName = artistName
            self.description = description
            self.releaseDate = releaseDate
            self.genres = genres
            self.cover = cover
            self.trackCount = trackCount
            self.feedUrl = feedUrl
            self.pageUrl = pageUrl
            self.explicit = explicit
            self.source = source
        }
    }

    /// Kanał RSS po przetworzeniu przez serwer (`podcastUtils.cleanPodcastJson`).
    public struct PodcastFeed: Decodable, Sendable {
        public struct Metadata: Decodable, Sendable {
            public let title: String?
            public let author: String?
            public let description: String?
            public let descriptionPlain: String?
            public let image: String?
            public let categories: [String]?
            public let feedUrl: String?
            public let language: String?
            /// `yes`/`true`/`no`… jak w kanale.
            public let explicit: String?
            public let type: String?
            public let link: String?

            public init(from decoder: any Decoder) throws {
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

            public var isExplicit: Bool { ["yes", "true", "explicit"].contains((explicit ?? "").lowercased()) }
        }

        public let metadata: Metadata
        public let episodes: [FeedEpisode]

        private enum CodingKeys: String, CodingKey { case metadata, episodes }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            metadata = try c.decode(Metadata.self, forKey: .metadata)
            let raw = (try? c.decodeIfPresent([JSONValue].self, forKey: .episodes)) ?? []
            episodes = raw.enumerated().map { FeedEpisode(raw: $1, index: $0) }
        }
    }

    /// Odcinek z kanału: surowy JSON (wraca do serwera bez zmian) i wygodne pola do listy.
    public struct FeedEpisode: Sendable, Identifiable, Hashable {
        public let raw: JSONValue
        public let index: Int

        public var id: Int { index }
        public var title: String { raw["title"]?.string ?? "Bez tytułu" }
        public var subtitle: String? { raw["subtitle"]?.string }
        public var descriptionPlain: String? { raw["descriptionPlain"]?.string ?? HTMLText.plain(raw["description"]?.string) }
        public var season: String? { raw["season"]?.string }
        public var episode: String? { raw["episode"]?.string }
        public var episodeType: String? { raw["episodeType"]?.string }
        public var guid: String? { raw["guid"]?.string }
        public var url: String? { raw["enclosure"]?["url"]?.string }
        public var durationSeconds: Double? { raw["durationSeconds"]?.number }
        public var size: Double? { raw["enclosure"]?["length"]?.number }
        public var published: Date? { raw["publishedAt"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) } }
    }

    public struct OPMLFeed: Decodable, Sendable, Identifiable, Hashable {
        public let title: String?
        public let feedUrl: String
        public var id: String { feedUrl }
    }

    /// Podcast już w bibliotece (`GET /libraries/:id/podcast-titles`).
    public struct PodcastTitle: Decodable, Sendable {
        public let title: String?
        public let itunesId: String?
        public let libraryItemId: String
    }

    public func searchPodcasts(term: String, country: String, token: String) async throws -> [PodcastSearchResult] {
        let query = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "country", value: country)]
        let data = try await send("GET", "api/search/podcast", query: query, token: token, timeout: 30)
        return try decode(LenientList<PodcastSearchResult>.self, from: data).elements.filter { $0.title != nil }
    }

    /// Serwer sam pobiera i przetwarza kanał; 404 znaczy „nie udało się pobrać albo to nie RSS”.
    public func podcastFeed(url: String, token: String) async throws -> PodcastFeed {
        struct Body: Encodable { let rssFeed: String }
        struct Response: Decodable { let podcast: PodcastFeed }
        return try decode(Response.self, from: await send("POST", "api/podcasts/feed", body: Body(rssFeed: url), token: token, timeout: 60)).podcast
    }

    public func parseOPML(_ text: String, token: String) async throws -> [OPMLFeed] {
        struct Body: Encodable { let opmlText: String }
        struct Response: Decodable { let feeds: LenientList<OPMLFeed>? }
        return try decode(Response.self, from: await send("POST", "api/podcasts/opml/parse", body: Body(opmlText: text), token: token)).feeds?.elements ?? []
    }

    /// Import w tle (zadanie serwera „OPML import”) — odpowiedź przychodzi od razu.
    public func createPodcastsFromOPML(feeds: [String], libraryID: String, folderID: String, autoDownload: Bool, token: String) async throws {
        struct Body: Encodable {
            let feeds: [String]
            let libraryId: String
            let folderId: String
            let autoDownloadEpisodes: Bool
        }
        _ = try await send("POST", "api/podcasts/opml/create", body: Body(feeds: feeds, libraryId: libraryID, folderId: folderID, autoDownloadEpisodes: autoDownload), token: token)
    }

    public func podcastTitles(libraryID: String, token: String) async throws -> [PodcastTitle] {
        struct Response: Decodable { let podcasts: LenientList<PodcastTitle>? }
        return try decode(Response.self, from: await send("GET", "api/libraries/\(libraryID)/podcast-titles", token: token)).podcasts?.elements ?? []
    }

    // MARK: Tworzenie

    /// Ciało `POST /api/podcasts` jak w `NewModal.vue`. `path` musi leżeć w folderze biblioteki.
    public struct NewPodcast: Encodable, Sendable {
        public struct Media: Encodable, Sendable {
            public struct Metadata: Encodable, Sendable {
                public var title: String
                public var author: String
                public var description: String
                public var releaseDate: String
                public var genres: [String]
                public var feedUrl: String
                public var imageUrl: String
                public var itunesPageUrl: String
                public var itunesId: String
                public var itunesArtistId: String
                public var language: String
                public var explicit: Bool
                public var type: String

                public init(title: String, author: String, description: String, releaseDate: String, genres: [String], feedUrl: String, imageUrl: String, itunesPageUrl: String, itunesId: String, itunesArtistId: String, language: String, explicit: Bool, type: String) {
                    self.title = title
                    self.author = author
                    self.description = description
                    self.releaseDate = releaseDate
                    self.genres = genres
                    self.feedUrl = feedUrl
                    self.imageUrl = imageUrl
                    self.itunesPageUrl = itunesPageUrl
                    self.itunesId = itunesId
                    self.itunesArtistId = itunesArtistId
                    self.language = language
                    self.explicit = explicit
                    self.type = type
                }
            }
            public var metadata: Metadata
            public var autoDownloadEpisodes: Bool

            public init(metadata: Metadata, autoDownloadEpisodes: Bool) {
                self.metadata = metadata
                self.autoDownloadEpisodes = autoDownloadEpisodes
            }
        }
        public var path: String
        public var folderId: String
        public var libraryId: String
        public var media: Media

        public init(path: String, folderId: String, libraryId: String, media: Media) {
            self.path = path
            self.folderId = folderId
            self.libraryId = libraryId
            self.media = media
        }
    }

    /// Zwraca id nowej pozycji.
    public func createPodcast(_ podcast: NewPodcast, token: String) async throws -> String {
        struct Response: Decodable { let id: String }
        return try decode(Response.self, from: await send("POST", "api/podcasts", body: podcast, token: token, timeout: 60)).id
    }

    // MARK: Odcinki i pobieranie

    /// Pobieranie w kolejce serwera (`PodcastEpisodeDownload.toJSONForClient`).
    /// Etap pobierania odcinka w zdarzeniach serwera (`episode_download_queued|started|finished`).
    public enum EpisodeDownloadPhase: Sendable {
        case queued, started, finished
    }

    public struct EpisodeDownload: Decodable, Sendable, Identifiable, Hashable {
        public let id: String
        public let episodeDisplayTitle: String?
        public let libraryItemId: String
        public let libraryId: String?
        public let isFinished: Bool?
        public let failed: Bool?
        public let startedAt: Double?
        public let createdAt: Double?
        public let finishedAt: Double?
        public let podcastTitle: String?
        public let season: String?
        public let episode: String?
        public let publishedAt: Double?
        public let guid: String?
        public let url: String?
    }

    public struct DownloadQueue: Decodable, Sendable {
        public let currentDownload: EpisodeDownload?
        public let queue: LenientList<EpisodeDownload>?
    }

    public func episodeDownloadQueue(libraryID: String, token: String) async throws -> DownloadQueue {
        try decode(DownloadQueue.self, from: await send("GET", "api/libraries/\(libraryID)/episode-downloads", token: token))
    }

    /// Kolejkuje odcinki z kanału; serwer pobiera je po kolei w tle.
    public func downloadEpisodes(itemID: String, _ episodes: [FeedEpisode], token: String) async throws {
        _ = try await send("POST", "api/podcasts/\(itemID)/download-episodes", body: episodes.map(\.raw), token: token, timeout: 60)
    }

    /// Nowe odcinki od `lastEpisodeCheck` (najwyżej `limit`) — od razu trafiają do kolejki pobierania.
    public func checkNewEpisodes(itemID: String, limit: Int, token: String) async throws -> Int {
        struct Response: Decodable { let episodes: LenientList<JSONValue>? }
        let data = try await send("GET", "api/podcasts/\(itemID)/checknew", query: [URLQueryItem(name: "limit", value: String(limit))], token: token, timeout: 90)
        return try decode(Response.self, from: data).episodes?.elements.count ?? 0
    }

    public func clearDownloadQueue(itemID: String, token: String) async throws {
        _ = try await send("GET", "api/podcasts/\(itemID)/clear-queue", token: token)
    }

    /// Uzupełnia opisy odcinków z kanału (`override` nadpisuje też wypełnione). Zwraca liczbę zmienionych.
    public func quickMatchEpisodes(itemID: String, override: Bool, token: String) async throws -> Int {
        struct Response: Decodable { let numEpisodesUpdated: Int? }
        let query = override ? [URLQueryItem(name: "override", value: "1")] : []
        return try decode(Response.self, from: await send("POST", "api/podcasts/\(itemID)/match-episodes", query: query, token: token, timeout: 90)).numEpisodesUpdated ?? 0
    }

    /// Zmiana odcinka (`PodcastController.updateEpisode`): pola `nil` nie są wysyłane.
    public struct EpisodeUpdate: Encodable, Sendable {
        public var title: String?
        public var subtitle: String?
        public var description: String?
        public var pubDate: String?
        public var publishedAt: Double?
        public var episode: String?
        public var season: String?
        public var episodeType: String?

        public var isEmpty: Bool {
            title == nil && subtitle == nil && description == nil && pubDate == nil && publishedAt == nil
                && episode == nil && season == nil && episodeType == nil
        }

        public init(title: String? = nil, subtitle: String? = nil, description: String? = nil, pubDate: String? = nil, publishedAt: Double? = nil, episode: String? = nil, season: String? = nil, episodeType: String? = nil) {
            self.title = title
            self.subtitle = subtitle
            self.description = description
            self.pubDate = pubDate
            self.publishedAt = publishedAt
            self.episode = episode
            self.season = season
            self.episodeType = episodeType
        }
    }

    public func updateEpisode(itemID: String, episodeID: String, _ update: EpisodeUpdate, token: String) async throws {
        _ = try await send("PATCH", "api/podcasts/\(itemID)/episode/\(episodeID)", body: update, token: token)
    }

    /// Usuwa odcinek z biblioteki (postęp i wpisy w playlistach też); `hard` kasuje również plik audio.
    public func removeEpisode(itemID: String, episodeID: String, hard: Bool, token: String) async throws {
        let query = hard ? [URLQueryItem(name: "hard", value: "1")] : []
        _ = try await send("DELETE", "api/podcasts/\(itemID)/episode/\(episodeID)", query: query, token: token)
    }

    // MARK: Szczegóły i harmonogram

    /// `PATCH /api/items/:id/media` dla podcastu (`Podcast.updateFromRequest`). Pola `nil` nie są wysyłane.
    public struct PodcastUpdate: Encodable, Sendable {
        public struct Metadata: Encodable, Sendable {
            public var title: String?
            public var author: String?
            public var description: String?
            public var releaseDate: String?
            public var genres: [String]?
            public var feedUrl: String?
            public var itunesPageUrl: String?
            public var itunesId: String?
            public var itunesArtistId: String?
            public var language: String?
            public var type: String?
            public var explicit: Bool?

            public var isEmpty: Bool {
                title == nil && author == nil && description == nil && releaseDate == nil && genres == nil && feedUrl == nil
                    && itunesPageUrl == nil && itunesId == nil && itunesArtistId == nil && language == nil && type == nil && explicit == nil
            }

            public init(title: String? = nil, author: String? = nil, description: String? = nil, releaseDate: String? = nil, genres: [String]? = nil, feedUrl: String? = nil, itunesPageUrl: String? = nil, itunesId: String? = nil, itunesArtistId: String? = nil, language: String? = nil, type: String? = nil, explicit: Bool? = nil) {
                self.title = title
                self.author = author
                self.description = description
                self.releaseDate = releaseDate
                self.genres = genres
                self.feedUrl = feedUrl
                self.itunesPageUrl = itunesPageUrl
                self.itunesId = itunesId
                self.itunesArtistId = itunesArtistId
                self.language = language
                self.type = type
                self.explicit = explicit
            }
        }
        public var metadata: Metadata?
        public var tags: [String]?
        public var autoDownloadEpisodes: Bool?
        public var autoDownloadSchedule: String?
        public var maxEpisodesToKeep: Int?
        public var maxNewEpisodesToDownload: Int?
        /// Milisekundy — od tej daty `checknew` szuka nowych odcinków.
        public var lastEpisodeCheck: Double?

        public var isEmpty: Bool {
            (metadata?.isEmpty ?? true) && tags == nil && autoDownloadEpisodes == nil && autoDownloadSchedule == nil
                && maxEpisodesToKeep == nil && maxNewEpisodesToDownload == nil && lastEpisodeCheck == nil
        }

        public init(metadata: Metadata? = nil, tags: [String]? = nil, autoDownloadEpisodes: Bool? = nil, autoDownloadSchedule: String? = nil, maxEpisodesToKeep: Int? = nil, maxNewEpisodesToDownload: Int? = nil, lastEpisodeCheck: Double? = nil) {
            self.metadata = metadata
            self.tags = tags
            self.autoDownloadEpisodes = autoDownloadEpisodes
            self.autoDownloadSchedule = autoDownloadSchedule
            self.maxEpisodesToKeep = maxEpisodesToKeep
            self.maxNewEpisodesToDownload = maxNewEpisodesToDownload
            self.lastEpisodeCheck = lastEpisodeCheck
        }
    }

    public func updatePodcast(itemID: String, _ update: PodcastUpdate, token: String) async throws -> Bool {
        struct Response: Decodable { let updated: Bool? }
        return try decode(Response.self, from: await send("PATCH", "api/items/\(itemID)/media", body: update, token: token)).updated ?? false
    }

    /// Okładki podcastu z iTunes (`/search/covers?podcast=1`).
    public func searchPodcastCovers(title: String, token: String) async throws -> [String] {
        struct Response: Decodable { let results: LenientList<String>? }
        let query = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "podcast", value: "1")]
        let data = try await send("GET", "api/search/covers", query: query, token: token, timeout: 60)
        var seen = Set<String>()
        return (try decode(Response.self, from: data).results?.elements ?? []).filter { seen.insert($0).inserted }
    }
}
