import Foundation

/// Punkty API do słuchania (etap 9a). Wszystkie wołane tokenem zwykłego konta użytkownika
/// (tego samego, którego używa telefon), więc postęp jest wspólny.
///
/// Kształty odpowiedzi sprawdzone na upstreamie v2.38.0:
/// `server/controllers/LibraryController.js` (`/libraries`, `/libraries/:id/items`),
/// `MeController.js` (`/me`, `/me/progress`, `/me/items-in-progress`),
/// `LibraryItemController.js` (`/items/:id`, `/items/:id/play`, `/items/:id/cover`),
/// `SessionController.js` + `managers/PlaybackSessionManager.js` (`/session/:id/sync|close`)
/// oraz `Auth.js` (`/auth/refresh`).
extension AudiobookshelfClient {
    // MARK: Modele

    /// Pozycja biblioteki w wersji skróconej (`minified=1`) albo pełnej (`expanded`, kolekcje,
    /// wyszukiwanie) — pełna to nadzbiór skróconej, więc oba kształty dekodują się tu tak samo.
    public struct LibraryItem: Decodable, Sendable, Identifiable, Hashable {
        public struct Media: Decodable, Sendable, Hashable {
            public struct Metadata: Decodable, Sendable, Hashable {
                public let title: String?
                public let subtitle: String?
                public let authorName: String?
                /// Podcasty mają autora w polu `author`.
                public let author: String?
                public let narratorName: String?
                /// „Nazwa #1, Inna #2” — w wersji skróconej jedyna informacja o serii.
                public let seriesName: String?
                /// Seria jako obiekt (lista filtrowana po serii, „Kolejne w serii”, strona autora)
                /// albo tablica (wersja pełna); w zwykłej liście skróconej jej nie ma.
                public let series: OneOrMany<SeriesRef>?
                public let publishedYear: String?
            }

            public let metadata: Metadata
            public let coverPath: String?
            public let duration: Double?
            public let numEpisodes: Int?
            public let numTracks: Int?
            /// Format podstawowego e-booka (lista pozycji, `toOldJSONMinified`).
            public var ebookFormat: String? = nil
            public let size: Double?
        }

        public let id: String
        public let libraryId: String
        public let mediaType: String
        public let media: Media
        /// Tylko w `/me/items-in-progress` i półkach odcinków: odcinek, którego dotyczy pozycja.
        public let recentEpisode: PodcastEpisode?
        /// Tylko w `/me/items-in-progress`, w milisekundach.
        public let progressLastUpdate: Double?
        public let addedAt: Double?

        public var title: String { media.metadata.title ?? "Bez tytułu" }
        public var author: String? { media.metadata.authorName ?? media.metadata.author }
        public var isPodcast: Bool { mediaType == "podcast" }
        /// Numer w serii, gdy lista ją zawiera (strona serii, „Kolejne w serii”).
        public func sequence(in seriesID: String? = nil) -> String? {
            let all = media.metadata.series?.values ?? []
            return (seriesID.flatMap { id in all.first { $0.id == id } } ?? all.first)?.sequence
        }
    }

    public struct SeriesRef: Decodable, Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        public let sequence: String?
    }

    /// Wartość, którą serwer zwraca raz jako obiekt, raz jako tablicę.
    public struct OneOrMany<Element: Decodable & Sendable & Hashable>: Decodable, Sendable, Hashable {
        public let values: [Element]

        public init(from decoder: any Decoder) throws {
            if let list = try? LenientList<Element>(from: decoder) {
                values = list.elements
            } else {
                values = [try Element(from: decoder)]
            }
        }
    }

    public struct PodcastEpisode: Decodable, Sendable, Identifiable, Hashable {
        public struct AudioFile: Decodable, Sendable, Hashable {
            public struct FileMetadata: Decodable, Sendable, Hashable {
                public let filename: String?
                public let path: String?
                public let size: Double?
            }
            public let duration: Double?
            public let metadata: FileMetadata?
        }

        public let id: String
        public let title: String?
        public let subtitle: String?
        /// HTML z kanału RSS.
        public let description: String?
        public let season: String?
        public let episode: String?
        public let episodeType: String?
        public let publishedAt: Double?
        /// Data z kanału w postaci RFC 2822 (to, co edytuje web UI obok `publishedAt`).
        public let pubDate: String?
        public let guid: String?
        public let enclosure: Enclosure?
        public let audioFile: AudioFile?
        public let duration: Double?
        public let size: Double?
        /// Tylko w „Najnowszych odcinkach”.
        public let libraryItemId: String?
        public let podcast: PodcastInfo?

        public struct Enclosure: Decodable, Sendable, Hashable {
            public let url: String?
        }

        public var length: Double? { duration ?? audioFile?.duration }
        public var published: Date? { publishedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

        public struct PodcastInfo: Decodable, Sendable, Hashable {
            public struct Metadata: Decodable, Sendable, Hashable {
                public let title: String?
                public let author: String?
            }
            public let metadata: Metadata?
            public let coverPath: String?
        }
    }

    /// Dowolny obiekt JSON, którego nie potrzebujemy — tylko po to, by przesunąć się w liście.
    private struct SkippedElement: Decodable {}

    /// Lista, w której element o nieoczekiwanym kształcie jest pomijany zamiast psuć całą odpowiedź
    /// (dane z prawdziwych bibliotek bywają różne, np. postęp samego e-booka).
    public struct LenientList<Element: Decodable & Sendable>: Decodable, Sendable {
        public let elements: [Element]

        public init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var elements: [Element] = []
            while !container.isAtEnd {
                if let element = try? container.decode(Element.self) {
                    elements.append(element)
                } else if (try? container.decode(SkippedElement.self)) == nil {
                    break
                }
            }
            self.elements = elements
        }
    }

    /// Postęp słuchania (`MediaProgress.getOldMediaProgress()` upstreamu). `libraryItemId` bywa `null`
    /// (rekord bez `extraData`), a `currentTime` pusty przy postępie samego e-booka.
    public struct MediaProgress: Decodable, Sendable, Hashable {
        /// Identyfikator rekordu — potrzebny do usunięcia postępu (`DELETE /api/me/progress/:id`).
        public var id: String? = nil
        public let libraryItemId: String?
        public let episodeId: String?
        public let duration: Double?
        public let progress: Double?
        public let currentTime: Double?
        public let isFinished: Bool
        public let hideFromContinueListening: Bool?
        /// Milisekundy od epoki; zmienia się przy każdym zapisie z dowolnego urządzenia.
        public let lastUpdate: Double
        public var startedAt: Double? = nil
        public var finishedAt: Double? = nil
        /// Miejsce w e-booku (etap 9g): CFI dla EPUB, numer strony dla PDF i komiksów.
        public var ebookLocation: EbookLocation? = nil
        /// Przeczytana część e-booka, 0…1.
        public var ebookProgress: Double? = nil

        public init(id: String? = nil, libraryItemId: String?, episodeId: String?, duration: Double?, progress: Double?, currentTime: Double?, isFinished: Bool, hideFromContinueListening: Bool?, lastUpdate: Double, startedAt: Double? = nil, finishedAt: Double? = nil, ebookLocation: EbookLocation? = nil, ebookProgress: Double? = nil) {
            self.id = id
            self.libraryItemId = libraryItemId
            self.episodeId = episodeId
            self.duration = duration
            self.progress = progress
            self.currentTime = currentTime
            self.isFinished = isFinished
            self.hideFromContinueListening = hideFromContinueListening
            self.lastUpdate = lastUpdate
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.ebookLocation = ebookLocation
            self.ebookProgress = ebookProgress
        }
    }

    /// `ebookLocation` to w bazie tekst, ale web UI zapisuje tam liczbę (stronę PDF), a serwer ją
    /// oddaje bez zmiany typu. Dekodujemy łagodnie — błąd tego pola nie może zgubić całego postępu.
    public struct EbookLocation: Decodable, Sendable, Hashable {
        public let value: String

        public init(_ value: String) { self.value = value }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                value = text
            } else if let number = try? container.decode(Double.self) {
                value = number.rounded() == number ? String(Int(number)) : String(number)
            } else {
                value = ""
            }
        }
    }

    /// Sesja odtwarzania (`PlaybackSession.toJSONForClient`).
    public struct PlaybackSession: Decodable, Sendable {
        public struct Track: Decodable, Sendable {
            public struct FileMetadata: Decodable, Sendable {
                /// Pełna ścieżka pliku na dysku serwera — ten sam Mac, więc czytamy ją wprost.
                public let path: String?
            }

            public let index: Int
            /// Początek pliku na osi czasu całej książki (sekundy).
            public let startOffset: Double
            public let duration: Double
            public let title: String?
            /// Względem `baseURL`, np. `/api/items/<id>/file/<ino>` albo `/hls/<sesja>/output.m3u8`.
            public let contentUrl: String
            public let mimeType: String?
            public let metadata: FileMetadata?
        }

        public struct Chapter: Decodable, Sendable {
            public let start: Double
            public let end: Double
            public let title: String
        }

        public let id: String
        public let libraryItemId: String
        public let episodeId: String?
        public let mediaType: String
        public let displayTitle: String?
        public let displayAuthor: String?
        public let coverPath: String?
        public let duration: Double
        /// Pozycja z postępu na serwerze; 0 dla ukończonych (upstream zaczyna je od nowa).
        public let currentTime: Double
        /// 0 odtwarzanie bezpośrednie, 1 direct stream, 2 transkodowanie (HLS), 3 lokalne.
        public let playMethod: Int
        public let audioTracks: [Track]
        public let chapters: [Chapter]
    }

    /// Dane urządzenia wysyłane przy starcie sesji; stały `deviceId` sprawia, że nowa sesja
    /// zamyka poprzednią tego samego urządzenia (`PlaybackSessionManager.startSession`).
    public struct DeviceInfo: Encodable, Sendable {
        public let deviceId: String
        public var clientName = "AudiobookSwift"
        public let clientVersion: String
        public var manufacturer = "Apple"
        public var model = "Mac"

        public init(deviceId: String, clientName: String = "", clientVersion: String, manufacturer: String = "", model: String = "") {
            self.deviceId = deviceId
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.manufacturer = manufacturer
            self.model = model
        }
    }

    // MARK: Token

    /// Nowa para tokenów z refresh tokenu (`POST /auth/refresh` z nagłówkiem `x-refresh-token`).
    /// Refresh token jest przy tym rotowany — stary przestaje działać.
    public func refresh(refreshToken: String) async throws -> Login {
        struct Response: Decodable {
            struct User: Decodable {
                let id: String
                let username: String
                let accessToken: String
                let refreshToken: String?
            }
            let user: User
        }
        let data = try await send("POST", "auth/refresh", headers: ["x-refresh-token": refreshToken])
        let user = try decode(Response.self, from: data).user
        return Login(userID: user.id, username: user.username, accessToken: user.accessToken, refreshToken: user.refreshToken)
    }

    // MARK: Biblioteki i pozycje

    /// Biblioteki dostępne dla użytkownika tokenu (to samo `libraries(token:)` co dla roota).
    public func userLibraries(token: String) async throws -> [Library] {
        try await libraries(token: token)
    }

    /// „Słuchaj dalej” ze wszystkich bibliotek: rozpoczęte i nieukończone, z czasem ostatniej zmiany.
    public func itemsInProgress(token: String) async throws -> [LibraryItem] {
        struct Response: Decodable { let libraryItems: LenientList<LibraryItem> }
        let query = [URLQueryItem(name: "limit", value: "50")]
        return try decode(Response.self, from: await send("GET", "api/me/items-in-progress", query: query, token: token)).libraryItems.elements
    }

    /// Postęp i zakładki użytkownika (`GET /api/me`).
    public func me(token: String) async throws -> MeState {
        try decode(MeState.self, from: await send("GET", "api/me", token: token))
    }

    /// Postęp jednej pozycji; `nil`, gdy jej jeszcze nie słuchano (serwer odpowiada 404).
    public func progress(itemID: String, episodeID: String?, token: String) async throws -> MediaProgress? {
        do {
            return try decode(MediaProgress.self, from: await send("GET", progressPath(itemID, episodeID), token: token))
        } catch APIError.http(status: 404, _) {
            return nil
        }
    }

    /// Zapisuje postęp bez sesji odtwarzania (`PATCH /api/me/progress/:id/:episodeId?`).
    /// Używane, gdy sesji już nie ma (np. serwer uruchomiony ponownie) i do oznaczenia jako ukończone.
    public func updateProgress(itemID: String, episodeID: String?, currentTime: Double?, duration: Double, isFinished: Bool? = nil, token: String) async throws {
        struct Body: Encodable {
            let currentTime: Double?
            let duration: Double
            let progress: Double?
            let isFinished: Bool?
        }
        let progress = currentTime.map { duration > 0 ? min(1, $0 / duration) : 0 }
        let body = Body(currentTime: currentTime, duration: duration, progress: progress, isFinished: isFinished)
        _ = try await send("PATCH", progressPath(itemID, episodeID), body: body, token: token)
    }

    public func progressPath(_ itemID: String, _ episodeID: String?) -> String {
        episodeID.map { "api/me/progress/\(itemID)/\($0)" } ?? "api/me/progress/\(itemID)"
    }

    /// Okładka przeskalowana przez serwer (gdy pliku okładki nie da się przeczytać z dysku).
    public func cover(itemID: String, width: Int, token: String) async throws -> Data {
        let query = [URLQueryItem(name: "width", value: String(width)), URLQueryItem(name: "format", value: "jpeg")]
        return try await send("GET", "api/items/\(itemID)/cover", query: query, token: token)
    }

    /// Czy plik strumienia (segment HLS) już istnieje. Brakujący segment poza zasięgiem trwającego
    /// transkodowania każe serwerowi zacząć transkodowanie od niego (`HlsRouter.streamFileRequest`).
    public func streamFileExists(path: String, token: String) async throws -> Bool {
        do {
            _ = try await send("GET", path, token: token)
            return true
        } catch APIError.http(status: 404, _) {
            return false
        }
    }

    // MARK: Sesja odtwarzania

    /// Otwiera sesję. `transcode == false` wymusza odtwarzanie bezpośrednie (pliki z dysku albo
    /// `contentUrl` pliku); `true` każe serwerowi transkodować do HLS (formaty, których
    /// AVFoundation nie odtwarza, np. WMA).
    public func startPlayback(itemID: String, episodeID: String?, device: DeviceInfo, transcode: Bool, token: String) async throws -> PlaybackSession {
        struct Body: Encodable {
            let deviceInfo: DeviceInfo
            let forceDirectPlay: Bool
            let forceTranscode: Bool
            let mediaPlayer = "AVPlayer"
        }
        let path = episodeID.map { "api/items/\(itemID)/play/\($0)" } ?? "api/items/\(itemID)/play"
        let body = Body(deviceInfo: device, forceDirectPlay: !transcode, forceTranscode: transcode)
        return try decode(PlaybackSession.self, from: await send("POST", path, body: body, token: token))
    }

    public struct SyncData: Encodable, Sendable {
        public let currentTime: Double
        /// Sekundy faktycznie przesłuchane od poprzedniej udanej synchronizacji (statystyki).
        public let timeListened: Double
        public let duration: Double

        public init(currentTime: Double, timeListened: Double, duration: Double) {
            self.currentTime = currentTime
            self.timeListened = timeListened
            self.duration = duration
        }
    }

    /// Zapisuje pozycję w otwartej sesji (serwer aktualizuje też postęp, który widzi telefon).
    /// Sesji, której serwer już nie zna (np. po ponownym uruchomieniu), odpowiada 404.
    public func syncSession(id: String, _ data: SyncData, token: String) async throws {
        _ = try await send("POST", "api/session/\(id)/sync", body: data, token: token)
    }

    /// Zamyka sesję; bez `data` niczego nie zapisuje (pozycja się nie zmieniła od ostatniej synchronizacji).
    public func closeSession(id: String, _ data: SyncData?, token: String) async throws {
        if let data {
            _ = try await send("POST", "api/session/\(id)/close", body: data, token: token)
        } else {
            _ = try await send("POST", "api/session/\(id)/close", token: token)
        }
    }
}
