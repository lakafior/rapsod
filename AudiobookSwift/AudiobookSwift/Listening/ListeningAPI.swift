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
    struct LibraryItem: Decodable, Sendable, Identifiable, Hashable {
        struct Media: Decodable, Sendable, Hashable {
            struct Metadata: Decodable, Sendable, Hashable {
                let title: String?
                let subtitle: String?
                let authorName: String?
                /// Podcasty mają autora w polu `author`.
                let author: String?
                let narratorName: String?
                /// „Nazwa #1, Inna #2” — w wersji skróconej jedyna informacja o serii.
                let seriesName: String?
                /// Seria jako obiekt (lista filtrowana po serii, „Kolejne w serii”, strona autora)
                /// albo tablica (wersja pełna); w zwykłej liście skróconej jej nie ma.
                let series: OneOrMany<SeriesRef>?
                let publishedYear: String?
            }

            let metadata: Metadata
            let coverPath: String?
            let duration: Double?
            let numEpisodes: Int?
            let numTracks: Int?
            let size: Double?
        }

        let id: String
        let libraryId: String
        let mediaType: String
        let media: Media
        /// Tylko w `/me/items-in-progress` i półkach odcinków: odcinek, którego dotyczy pozycja.
        let recentEpisode: PodcastEpisode?
        /// Tylko w `/me/items-in-progress`, w milisekundach.
        let progressLastUpdate: Double?
        let addedAt: Double?

        var title: String { media.metadata.title ?? "Bez tytułu" }
        var author: String? { media.metadata.authorName ?? media.metadata.author }
        var isPodcast: Bool { mediaType == "podcast" }
        /// Numer w serii, gdy lista ją zawiera (strona serii, „Kolejne w serii”).
        func sequence(in seriesID: String? = nil) -> String? {
            let all = media.metadata.series?.values ?? []
            return (seriesID.flatMap { id in all.first { $0.id == id } } ?? all.first)?.sequence
        }
    }

    struct SeriesRef: Decodable, Sendable, Hashable, Identifiable {
        let id: String
        let name: String
        let sequence: String?
    }

    /// Wartość, którą serwer zwraca raz jako obiekt, raz jako tablicę.
    struct OneOrMany<Element: Decodable & Sendable & Hashable>: Decodable, Sendable, Hashable {
        let values: [Element]

        init(from decoder: any Decoder) throws {
            if let list = try? LenientList<Element>(from: decoder) {
                values = list.elements
            } else {
                values = [try Element(from: decoder)]
            }
        }
    }

    struct PodcastEpisode: Decodable, Sendable, Identifiable, Hashable {
        struct AudioFile: Decodable, Sendable, Hashable {
            struct FileMetadata: Decodable, Sendable, Hashable {
                let filename: String?
                let size: Double?
            }
            let duration: Double?
            let metadata: FileMetadata?
        }

        let id: String
        let title: String?
        let subtitle: String?
        /// HTML z kanału RSS.
        let description: String?
        let season: String?
        let episode: String?
        let episodeType: String?
        let publishedAt: Double?
        let audioFile: AudioFile?
        let duration: Double?
        let size: Double?
        /// Tylko w „Najnowszych odcinkach”.
        let libraryItemId: String?
        let podcast: PodcastInfo?

        var length: Double? { duration ?? audioFile?.duration }
        var published: Date? { publishedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

        struct PodcastInfo: Decodable, Sendable, Hashable {
            struct Metadata: Decodable, Sendable, Hashable {
                let title: String?
                let author: String?
            }
            let metadata: Metadata?
            let coverPath: String?
        }
    }

    /// Dowolny obiekt JSON, którego nie potrzebujemy — tylko po to, by przesunąć się w liście.
    private struct SkippedElement: Decodable {}

    /// Lista, w której element o nieoczekiwanym kształcie jest pomijany zamiast psuć całą odpowiedź
    /// (dane z prawdziwych bibliotek bywają różne, np. postęp samego e-booka).
    struct LenientList<Element: Decodable & Sendable>: Decodable, Sendable {
        let elements: [Element]

        init(from decoder: any Decoder) throws {
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
    struct MediaProgress: Decodable, Sendable, Hashable {
        /// Identyfikator rekordu — potrzebny do usunięcia postępu (`DELETE /api/me/progress/:id`).
        var id: String? = nil
        let libraryItemId: String?
        let episodeId: String?
        let duration: Double?
        let progress: Double?
        let currentTime: Double?
        let isFinished: Bool
        let hideFromContinueListening: Bool?
        /// Milisekundy od epoki; zmienia się przy każdym zapisie z dowolnego urządzenia.
        let lastUpdate: Double
        var startedAt: Double? = nil
        var finishedAt: Double? = nil
    }

    /// Sesja odtwarzania (`PlaybackSession.toJSONForClient`).
    struct PlaybackSession: Decodable, Sendable {
        struct Track: Decodable, Sendable {
            struct FileMetadata: Decodable, Sendable {
                /// Pełna ścieżka pliku na dysku serwera — ten sam Mac, więc czytamy ją wprost.
                let path: String?
            }

            let index: Int
            /// Początek pliku na osi czasu całej książki (sekundy).
            let startOffset: Double
            let duration: Double
            let title: String?
            /// Względem `baseURL`, np. `/api/items/<id>/file/<ino>` albo `/hls/<sesja>/output.m3u8`.
            let contentUrl: String
            let mimeType: String?
            let metadata: FileMetadata?
        }

        struct Chapter: Decodable, Sendable {
            let start: Double
            let end: Double
            let title: String
        }

        let id: String
        let libraryItemId: String
        let episodeId: String?
        let mediaType: String
        let displayTitle: String?
        let displayAuthor: String?
        let coverPath: String?
        let duration: Double
        /// Pozycja z postępu na serwerze; 0 dla ukończonych (upstream zaczyna je od nowa).
        let currentTime: Double
        /// 0 odtwarzanie bezpośrednie, 1 direct stream, 2 transkodowanie (HLS), 3 lokalne.
        let playMethod: Int
        let audioTracks: [Track]
        let chapters: [Chapter]
    }

    /// Dane urządzenia wysyłane przy starcie sesji; stały `deviceId` sprawia, że nowa sesja
    /// zamyka poprzednią tego samego urządzenia (`PlaybackSessionManager.startSession`).
    struct DeviceInfo: Encodable, Sendable {
        let deviceId: String
        var clientName = "AudiobookSwift"
        let clientVersion: String
        var manufacturer = "Apple"
        var model = "Mac"
    }

    // MARK: Token

    /// Nowa para tokenów z refresh tokenu (`POST /auth/refresh` z nagłówkiem `x-refresh-token`).
    /// Refresh token jest przy tym rotowany — stary przestaje działać.
    func refresh(refreshToken: String) async throws -> Login {
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
    func userLibraries(token: String) async throws -> [Library] {
        try await libraries(token: token)
    }

    /// „Słuchaj dalej” ze wszystkich bibliotek: rozpoczęte i nieukończone, z czasem ostatniej zmiany.
    func itemsInProgress(token: String) async throws -> [LibraryItem] {
        struct Response: Decodable { let libraryItems: LenientList<LibraryItem> }
        let query = [URLQueryItem(name: "limit", value: "50")]
        return try decode(Response.self, from: await send("GET", "api/me/items-in-progress", query: query, token: token)).libraryItems.elements
    }

    /// Postęp i zakładki użytkownika (`GET /api/me`).
    func me(token: String) async throws -> MeState {
        try decode(MeState.self, from: await send("GET", "api/me", token: token))
    }

    /// Postęp jednej pozycji; `nil`, gdy jej jeszcze nie słuchano (serwer odpowiada 404).
    func progress(itemID: String, episodeID: String?, token: String) async throws -> MediaProgress? {
        do {
            return try decode(MediaProgress.self, from: await send("GET", progressPath(itemID, episodeID), token: token))
        } catch APIError.http(status: 404, _) {
            return nil
        }
    }

    /// Zapisuje postęp bez sesji odtwarzania (`PATCH /api/me/progress/:id/:episodeId?`).
    /// Używane, gdy sesji już nie ma (np. serwer uruchomiony ponownie) i do oznaczenia jako ukończone.
    func updateProgress(itemID: String, episodeID: String?, currentTime: Double?, duration: Double, isFinished: Bool? = nil, token: String) async throws {
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

    func progressPath(_ itemID: String, _ episodeID: String?) -> String {
        episodeID.map { "api/me/progress/\(itemID)/\($0)" } ?? "api/me/progress/\(itemID)"
    }

    /// Okładka przeskalowana przez serwer (gdy pliku okładki nie da się przeczytać z dysku).
    func cover(itemID: String, width: Int, token: String) async throws -> Data {
        let query = [URLQueryItem(name: "width", value: String(width)), URLQueryItem(name: "format", value: "jpeg")]
        return try await send("GET", "api/items/\(itemID)/cover", query: query, token: token)
    }

    /// Czy plik strumienia (segment HLS) już istnieje. Brakujący segment poza zasięgiem trwającego
    /// transkodowania każe serwerowi zacząć transkodowanie od niego (`HlsRouter.streamFileRequest`).
    func streamFileExists(path: String, token: String) async throws -> Bool {
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
    func startPlayback(itemID: String, episodeID: String?, device: DeviceInfo, transcode: Bool, token: String) async throws -> PlaybackSession {
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

    struct SyncData: Encodable, Sendable {
        let currentTime: Double
        /// Sekundy faktycznie przesłuchane od poprzedniej udanej synchronizacji (statystyki).
        let timeListened: Double
        let duration: Double
    }

    /// Zapisuje pozycję w otwartej sesji (serwer aktualizuje też postęp, który widzi telefon).
    /// Sesji, której serwer już nie zna (np. po ponownym uruchomieniu), odpowiada 404.
    func syncSession(id: String, _ data: SyncData, token: String) async throws {
        _ = try await send("POST", "api/session/\(id)/sync", body: data, token: token)
    }

    /// Zamyka sesję; bez `data` niczego nie zapisuje (pozycja się nie zmieniła od ostatniej synchronizacji).
    func closeSession(id: String, _ data: SyncData?, token: String) async throws {
        if let data {
            _ = try await send("POST", "api/session/\(id)/close", body: data, token: token)
        } else {
            _ = try await send("POST", "api/session/\(id)/close", token: token)
        }
    }
}
