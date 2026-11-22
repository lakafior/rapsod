// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu — reguły synchronizacji z `ListeningController.swift` aplikacji
// na Maca (etap 9a: wysyłanie tylko pozycji wytworzonej tutaj, „ostatnio uzgodniona” pozycja przed
// wznowieniem, nic po ukończeniu, ponowienie bez sesji po 404), przepisane dla klienta, który
// gra strumień z serwera przez sieć. Kształty zapytań — z kodu serwera audiobookshelf
// (`SessionController.js`, `PlaybackSessionManager.js`), bez przenoszenia jego kodu.
// Odcinki prosto z kanału RSS (etap 10e): kod własny projektu.

import AVFoundation
import AudiobookshelfKit
import Observation
import OSLog

private let logger = Logger(subsystem: "net.smigi.abswift", category: "Playback")

/// Słuchanie z serwera: sesja odtwarzania, pliki przez sesję i synchronizacja postępu.
///
/// **Pozycja.** Źródłem prawdy jest serwer — ten sam postęp, który widzi aplikacja na Macu.
/// Książka zaczyna od pozycji z serwera; podczas słuchania pozycja idzie na serwer co
/// `syncInterval`, przy pauzie i przy zmianie książki. Wysyłana jest tylko pozycja, którą wytworzył
/// ten odtwarzacz (`AudiobookPlayer.isDirty`), żeby nie cofnąć postępu z innego urządzenia.
/// Nieudana wysyłka zostaje w `pending` (w pamięci) i idzie przy następnej okazji; przed
/// wznowieniem po pauzie odtwarzacz przejmuje pozycję z serwera, jeśli zmieniła się gdzie indziej.
///
/// **Odcinek prosto z kanału** (`play(external:)`): dźwięk idzie wprost od wydawcy, a postęp —
/// do `localEpisodes` na telefonie, bo na serwerze odcinka jeszcze nie ma. Gdy serwer go pobierze
/// (`serverEpisodeAvailable`), zmienia się tylko cel postępu (odcinek na serwerze, zapis bez
/// sesji), a źródło dźwięku zostaje do następnego startu — słuchanie nie urywa się w pół zdania.
/// Wszystkie drogi do serwera idą przez `target(for:)`.
@MainActor
@Observable
public final class PlaybackCoordinator {
    public let player = AudiobookPlayer()
    public var loadError: String?
    /// Pozycja, której sesja się właśnie otwiera.
    public private(set) var startingKey: String?
    /// Pozycje czekające na wysłanie (brak sieci, serwer wyłączony), według klucza pozycji.
    public private(set) var pending: [String: PendingPosition] = [:]
    /// Rośnie po każdym zapisie postępu na serwerze — strony pozycji odświeżają wtedy postęp.
    public private(set) var progressRevision = 0
    /// Odcinki z kanału, których postęp idzie już do odcinka na serwerze: klucz odtwarzacza → id odcinka.
    public private(set) var redirected: [String: String] = [:]
    /// Długość pliku na serwerze dla przekierowanych odcinków (pozycja przeliczana proporcjonalnie).
    @ObservationIgnored private var redirectedDurations: [String: Double] = [:]

    /// Postęp odcinków słuchanych prosto z kanału (trwały, na telefonie).
    @ObservationIgnored public var localEpisodes: LocalEpisodeStore?
    /// Sprawdzenie pliku od wydawcy (adres do odtworzenia, długość); `nil` — AVFoundation.
    /// Podmieniane tylko w testach (przez zaślepkę serwera AVFoundation nie przechodzi).
    @ObservationIgnored public var streamProbe: (@Sendable (URL) async throws -> (URL, Double?))?

    /// Bieżące połączenie z serwerem (zmienia się przy przejściu sieć lokalna ↔ tunel).
    @ObservationIgnored public var authProvider: @MainActor () -> ListeningAuth?
    /// Okładka do „Teraz odtwarzane”.
    @ObservationIgnored public var coverLoader: (@MainActor (_ itemID: String, _ coverPath: String?) async -> PlatformImage?)?
    /// Prosi system o chwilę pracy w tle (iOS: `beginBackgroundTask`); zwraca zakończenie.
    @ObservationIgnored public var beginBackgroundWork: (@MainActor (_ name: String) -> (@MainActor () -> Void))?
    /// Zapytanie nie doszło do serwera — warto sprawdzić adres od nowa.
    @ObservationIgnored public var onConnectionError: (@MainActor () -> Void)?
    /// Zapis postępu doszedł do serwera — połączenie znowu działa.
    @ObservationIgnored public var onServerReached: (@MainActor () -> Void)?

    public static let syncInterval: Duration = .seconds(15)

    @ObservationIgnored private let device: AudiobookshelfClient.DeviceInfo
    @ObservationIgnored private var session: (id: String, key: String)?
    @ObservationIgnored private var reopenTask: Task<Void, any Error>?
    /// Pozycja, którą ostatnio ustaliliśmy z serwerem (wysłana albo przejęta).
    @ObservationIgnored private var lastAgreed: Double?
    @ObservationIgnored private var syncLoop: Task<Void, Never>?
    @ObservationIgnored private var syncInFlight: Task<Void, Never>?

    public init(device: AudiobookshelfClient.DeviceInfo, authProvider: @escaping @MainActor () -> ListeningAuth?) {
        self.device = device
        self.authProvider = authProvider
        player.assetProvider = { [weak self] track, fresh in
            guard let self else { throw CancellationError() }
            return try await asset(for: track, fresh: fresh)
        }
        player.onEvent = { [weak self] in self?.handle($0) }
        player.resumeCheck = { [weak self] in await self?.serverPositionIfChanged() }
        player.waitForStream = { [weak self] in await self?.waitForSegment(at: $0) }
    }

    public var nowPlayingKey: String? { player.book?.key }

    public func isLoaded(itemID: String, episodeID: String? = nil) -> Bool {
        guard let book = player.book else { return false }
        if book.key == PlaybackTimeline.key(itemID, episodeID) { return true }
        return episodeID != nil && book.itemID == itemID && redirected[book.key] == episodeID
    }

    /// Klucze, pod którymi widać bieżący odcinek: klucz odtwarzacza i — po pobraniu przez serwer —
    /// klucz odcinka na serwerze.
    public var nowPlayingKeys: Set<String> {
        guard let book = player.book else { return [] }
        var keys: Set<String> = [book.key]
        if let episodeID = redirected[book.key] { keys.insert(PlaybackTimeline.key(book.itemID, episodeID)) }
        return keys
    }

    /// Bieżący odcinek z kanału zapisuje postęp tylko na telefonie.
    public var isProgressLocal: Bool {
        guard let book = player.book, book.feedKey != nil else { return false }
        return redirected[book.key] == nil
    }

    // MARK: - Cel postępu

    private enum Target {
        case server(itemID: String, episodeID: String?)
        case local(LocalEpisodeRecord)
    }

    /// Wzór lokalnego wpisu bieżącego odcinka z kanału (gdy magazyn go jeszcze nie ma).
    @ObservationIgnored private var externalTemplate: LocalEpisodeRecord?

    private func target(for book: PlaybackBook) -> Target {
        guard let feedKey = book.feedKey else { return .server(itemID: book.itemID, episodeID: book.episodeID) }
        if let episodeID = redirected[book.key] { return .server(itemID: book.itemID, episodeID: episodeID) }
        if let stored = localEpisodes?.record(itemID: book.itemID, feedKey: feedKey) { return .local(stored) }
        if let externalTemplate, externalTemplate.itemID == book.itemID, externalTemplate.feedKey == feedKey { return .local(externalTemplate) }
        return .local(LocalEpisodeRecord(itemID: book.itemID, feedKey: feedKey, title: book.title, podcastTitle: book.author, guid: nil,
                                         enclosureURL: "", published: nil, duration: book.duration, currentTime: 0, isFinished: false, updatedAt: .now))
    }

    private func saveLocal(_ base: LocalEpisodeRecord, book: PlaybackBook, time: Double, finished: Bool = false) {
        var record = base
        record.duration = book.duration
        record.currentTime = finished ? book.duration : time
        record.isFinished = finished
        record.updatedAt = .now
        externalTemplate = record
        localEpisodes?.save(record)
        progressRevision += 1
    }

    // MARK: - Odtwarzanie

    /// Zaczyna słuchać pozycji (albo odcinka) od miejsca zapisanego na serwerze, a z `position`
    /// — od tego miejsca osi czasu książki (np. początek rozdziału ze strony pozycji).
    /// Gdy to już bieżąca książka — wznawia albo zatrzymuje (z `position`: przewija i gra).
    public func play(itemID: String, episodeID: String? = nil, from position: Double? = nil) async {
        let key = PlaybackTimeline.key(itemID, episodeID)
        // Także odcinek z kanału, którego postęp idzie już do tego odcinka serwera.
        if player.book?.key == key || isLoaded(itemID: itemID, episodeID: episodeID) {
            if let position {
                player.seek(to: position)
                if !player.isPlaying { player.play() }
            } else {
                player.togglePlayPause()
            }
            return
        }
        guard let auth = authProvider(), startingKey == nil else { return }
        startingKey = key
        defer { startingKey = nil }
        loadError = nil

        // Poprzednia książka: pozycja na serwer, sesja zamknięta.
        if player.book != nil {
            player.pause()
            await closeSession()
            player.stop()
        }
        redirected = [:]
        redirectedDurations = [:]
        externalTemplate = nil

        do {
            var playback = try await auth.perform {
                try await $0.startPlayback(itemID: itemID, episodeID: episodeID, device: device, transcode: false, token: $1)
            }
            if PlaybackTimeline.needsTranscoding(playback) {
                // Formaty spoza AVFoundation (np. WMA): serwer transkoduje do HLS. Nowa sesja tego
                // samego urządzenia zamyka poprzednią.
                logger.notice("Format spoza AVFoundation — odtwarzanie przez transkodowanie")
                playback = try await auth.perform {
                    try await $0.startPlayback(itemID: itemID, episodeID: episodeID, device: device, transcode: true, token: $1)
                }
            }
            let tracks = PlaybackTimeline.tracks(from: playback)
            guard !tracks.isEmpty else { throw PlaybackError.noAudio }

            var start = PlaybackTimeline.rewoundStart(playback.currentTime)
            var adoptedLocal = false
            if let unsent = pending[key] {
                let server = try? await auth.perform { try await $0.progress(itemID: itemID, episodeID: episodeID, token: $1) }
                let resolved = PendingPosition.resolveStart(server: server, sessionTime: playback.currentTime, pending: unsent)
                if resolved.local {
                    start = resolved.time
                    adoptedLocal = true
                } else {
                    pending[key] = nil
                }
            }

            let book = PlaybackBook(
                itemID: itemID,
                episodeID: episodeID,
                title: playback.displayTitle ?? "Bez tytułu",
                author: playback.displayAuthor,
                duration: playback.duration,
                tracks: tracks,
                chapters: PlaybackTimeline.chapters(from: playback, tracks: tracks),
                coverPath: playback.coverPath
            )
            // Wybrane miejsce (rozdział) zamiast zapisanego — wysyłane jak zmiana z tego urządzenia.
            if let position { start = position }
            let chosen = adoptedLocal || position != nil
            session = (playback.id, key)
            lastAgreed = chosen ? nil : playback.currentTime
            player.start(book, at: start)
            if chosen { player.isDirty = true }
            startSyncLoop()
            loadArtwork(book)
        } catch {
            logger.error("Start odtwarzania: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
            reportIfConnection(error)
        }
    }

    // MARK: - Odcinek prosto z kanału

    /// Odcinek z kanału RSS, którego nie ma na serwerze: wszystko, czego trzeba do odtworzenia
    /// i do późniejszego rozpoznania go na serwerze.
    public struct ExternalEpisode: Sendable {
        public var itemID: String
        public var feedKey: String
        public var title: String
        public var podcastTitle: String?
        public var guid: String?
        /// Adres pliku dokładnie jak w kanale.
        public var enclosureURL: String
        public var published: Date?
        /// Długość według kanału — tylko gdy plik jej nie poda (prawdziwa jest w pliku).
        public var feedDuration: Double?

        public init(itemID: String, feedKey: String, title: String, podcastTitle: String?, guid: String?, enclosureURL: String, published: Date?, feedDuration: Double?) {
            self.itemID = itemID
            self.feedKey = feedKey
            self.title = title
            self.podcastTitle = podcastTitle
            self.guid = guid
            self.enclosureURL = enclosureURL
            self.published = published
            self.feedDuration = feedDuration
        }
    }

    public enum StreamError: LocalizedError, Equatable {
        case invalidURL
        /// Tylko przez HTTP, a aplikacja łączy się z internetem wyłącznie przez HTTPS.
        case insecureOnly
        /// Wydawca nie obsługuje zakresów bajtów (AVFoundation wymaga ich przy strumieniu).
        case noRangeSupport
        case notFound
        case unknownDuration
        case timedOut
        case other(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: "Odcinek nie ma poprawnego adresu pliku."
            case .insecureOnly: "Wydawca udostępnia ten plik tylko przez niezabezpieczone HTTP, którego aplikacja nie używa. Pobierz odcinek na serwer, żeby go posłuchać."
            case .noRangeSupport: "Serwer wydawcy nie pozwala odtwarzać tego pliku strumieniowo. Pobierz odcinek na serwer, żeby go posłuchać."
            case .notFound: "Wydawca nie ma już tego pliku (odcinek mógł zniknąć z kanału)."
            case .unknownDuration: "Nie udało się ustalić długości odcinka."
            case .timedOut: "Wydawca nie odpowiedział na czas."
            case .other(let message): message
            }
        }
    }

    /// Słucha odcinka wprost od wydawcy, od miejsca zapisanego na telefonie. Gdy to bieżący
    /// odcinek — wznawia albo zatrzymuje.
    public func play(external episode: ExternalEpisode) async {
        let key = PlaybackTimeline.feedKey(episode.itemID, episode.feedKey)
        if player.book?.key == key {
            player.togglePlayPause()
            return
        }
        guard startingKey == nil else { return }
        startingKey = key
        defer { startingKey = nil }
        loadError = nil
        if player.book != nil {
            player.pause()
            await closeSession()
            player.stop()
        }
        redirected = [:]
        redirectedDurations = [:]
        externalTemplate = nil
        do {
            guard let original = URL(string: episode.enclosureURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["http", "https"].contains(original.scheme?.lowercased() ?? "") else { throw StreamError.invalidURL }
            let (url, probed) = try await (streamProbe ?? { try await Self.probe($0) })(original)
            guard let duration = probed ?? episode.feedDuration, duration > 1 else { throw StreamError.unknownDuration }

            let stored = localEpisodes?.record(itemID: episode.itemID, feedKey: episode.feedKey)
            var record = stored ?? LocalEpisodeRecord(
                itemID: episode.itemID, feedKey: episode.feedKey, title: episode.title, podcastTitle: episode.podcastTitle,
                guid: episode.guid, enclosureURL: episode.enclosureURL, published: episode.published,
                duration: duration, currentTime: 0, isFinished: false, updatedAt: .now
            )
            // Dane z bieżącego kanału (tytuł mógł się zmienić), pozycja — z telefonu.
            record.title = episode.title
            record.podcastTitle = episode.podcastTitle
            record.guid = episode.guid
            record.enclosureURL = episode.enclosureURL
            record.duration = duration
            let start = record.isFinished ? 0 : PlaybackTimeline.rewoundStart(record.currentTime)
            if record.isFinished {
                record.isFinished = false
                record.currentTime = 0
            }
            externalTemplate = record

            let book = PlaybackBook(
                itemID: episode.itemID,
                episodeID: nil,
                title: episode.title,
                author: episode.podcastTitle,
                duration: duration,
                tracks: [PlaybackTrack(startOffset: 0, duration: duration, title: episode.title, source: .remote(url))],
                chapters: [PlaybackChapter(id: 0, start: 0, end: duration, title: episode.title)],
                coverPath: nil,
                feedKey: episode.feedKey
            )
            session = nil
            lastAgreed = nil
            player.start(book, at: start)
            // Wpis od razu: odcinek jest „w trakcie” i da się go rozpoznać po pobraniu na serwer.
            if stored == nil { localEpisodes?.save(record) }
            startSyncLoop()
            loadArtwork(book)
        } catch {
            logger.error("Odcinek z kanału: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
    }

    /// Serwer pobrał odcinek słuchany prosto z kanału. Bieżący odcinek: od teraz postęp idzie
    /// do odcinka na serwerze (zapis bez sesji, od razu), dźwięk dalej od wydawcy. Zwraca `true`,
    /// gdy to był bieżący odcinek (lokalnym wpisem zajmuje się wtedy koordynator).
    @discardableResult
    public func serverEpisodeAvailable(itemID: String, feedKey: String, episodeID: String, serverDuration: Double? = nil) async -> Bool {
        guard let book = player.book, book.itemID == itemID, book.feedKey == feedKey else { return false }
        guard redirected[book.key] == nil else { return true }
        logger.notice("Odcinek z kanału jest już na serwerze — postęp idzie od teraz na serwer")
        redirected[book.key] = episodeID
        if let serverDuration, serverDuration > 0 { redirectedDurations[book.key] = serverDuration }
        player.isDirty = true
        await sync()
        return true
    }

    /// Adres do odtworzenia (dla `http://` najpierw ten sam po HTTPS) i długość pliku według
    /// AVFoundation — prawdziwa, nie z kanału (`nil`, gdy plik jej nie podaje).
    private static func probe(_ original: URL) async throws -> (URL, Double?) {
        var candidates = [original]
        if original.scheme?.lowercased() == "http", var components = URLComponents(url: original, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            if components.port == 80 { components.port = nil }
            if let secure = components.url { candidates.insert(secure, at: 0) }
        }
        var lastError: StreamError = .invalidURL
        for url in candidates {
            do {
                return (url, try await duration(of: url))
            } catch let error as StreamError {
                lastError = error
            }
        }
        throw lastError
    }

    private static func duration(of url: URL) async throws -> Double? {
        try await withThrowingTaskGroup(of: Double?.self) { group in
            group.addTask {
                let asset = AVURLAsset(url: url)
                do {
                    let (time, playable) = try await asset.load(.duration, .isPlayable)
                    guard playable else { throw StreamError.other("Tego pliku nie da się odtworzyć na telefonie.") }
                    let seconds = time.seconds
                    return seconds.isFinite && seconds > 0 ? seconds : nil
                } catch let error as StreamError {
                    throw error
                } catch {
                    throw streamError(error)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(25))
                throw StreamError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw StreamError.timedOut }
            return first
        }
    }

    /// Błąd AVFoundation/URL po ludzku; przyczyny bywają zagnieżdżone (`NSUnderlyingError`).
    public nonisolated static func streamError(_ error: any Error) -> StreamError {
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 5 {
            if ns.domain == NSURLErrorDomain {
                switch ns.code {
                case NSURLErrorAppTransportSecurityRequiresSecureConnection: return .insecureOnly
                case NSURLErrorFileDoesNotExist, NSURLErrorResourceUnavailable, NSURLErrorBadServerResponse: return .notFound
                case NSURLErrorTimedOut: return .timedOut
                default: break
                }
            }
            if ns.domain == AVFoundationErrorDomain, ns.code == AVError.Code.serverIncorrectlyConfigured.rawValue { return .noRangeSupport }
            if ns.domain == "CoreMediaErrorDomain", ns.code == -12938 || ns.code == -16845 { return .notFound }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return .other(error.localizedDescription)
    }

    /// Zatrzymuje odtwarzanie i zamyka książkę (pozycja zostaje na serwerze).
    public func stop() async {
        guard player.book != nil else { return }
        player.pause()
        let end = beginBackgroundWork?("Zamknięcie sesji")
        await closeSession()
        end?()
        player.stop()
        redirected = [:]
        redirectedDurations = [:]
    }

    /// Oznacza bieżącą książkę jako ukończoną.
    public func markFinished() async {
        guard let book = player.book else { return }
        player.pause()
        player.isDirty = false
        await finish(book)
        player.stop()
        endSyncLoop()
    }

    /// Połączenie z serwerem wróciło albo zmienił się jego adres.
    public func connectionChanged(baseURLChanged: Bool) async {
        if baseURLChanged, let book = player.book, !player.isPlaying || player.isStalled,
           book.tracks.contains(where: { $0.source.isServer }) {
            // Zatrzymany albo czekający na dane element trzyma stary adres — budujemy go od nowa
            // (razem z dołożonym następnym plikiem). Grający dalej zostaje: przejście na sieć
            // lokalną w domu nie przerywa słuchania, a nieudany plik i tak odbuduje `remoteFailed`.
            player.reload(fresh: false)
        }
        await flushPending()
        if player.isDirty, !player.isPlaying { await sync() }
    }

    private enum PlaybackError: LocalizedError {
        case noAudio
        case noSession
        var errorDescription: String? {
            switch self {
            case .noAudio: "Ta pozycja nie ma plików audio."
            case .noSession: "Serwer nie otworzył sesji odtwarzania."
            }
        }
    }

    // MARK: - Pliki

    private func asset(for track: PlaybackTrack, fresh: Bool) async throws -> AVURLAsset {
        switch track.source {
        case .file(let url), .remote(let url): return AVURLAsset(url: url)
        case .sessionTrack, .sessionStream: break
        }
        guard let auth = authProvider() else { throw AudiobookshelfClient.APIError.unauthorized }
        if fresh || session?.key != player.book?.key {
            try await reopenSession()
        }
        guard let session else { throw PlaybackError.noSession }
        let path: String
        switch track.source {
        case .sessionTrack(let index):
            path = "public/session/\(session.id)/track/\(index)"
        case .sessionStream, .file, .remote:
            path = "hls/\(session.id)/output.m3u8"
        }
        return AVURLAsset(url: auth.baseURL.appending(path: path))
    }

    /// Nowa sesja dla bieżącej książki: serwer zapomina sesje po ponownym uruchomieniu i po 36 h
    /// bez synchronizacji, a nowa sesja tego samego urządzenia zamyka poprzednią. Pozycji z nowej
    /// sesji nie bierzemy — odtwarzacz wie lepiej, gdzie jest.
    private func reopenSession() async throws {
        if let reopenTask { return try await reopenTask.value }
        guard let book = player.book, let auth = authProvider() else { throw PlaybackError.noSession }
        let transcode = book.tracks.first?.source == .sessionStream
        let device = device
        let task = Task { @MainActor in
            let playback = try await auth.perform {
                try await $0.startPlayback(itemID: book.itemID, episodeID: book.episodeID, device: device, transcode: transcode, token: $1)
            }
            guard player.book?.key == book.key else { return }
            session = (playback.id, book.key)
            logger.notice("Nowa sesja odtwarzania dla bieżącej książki")
        }
        reopenTask = task
        defer { reopenTask = nil }
        do {
            try await task.value
        } catch {
            reportIfConnection(error)
            throw error
        }
    }

    private func loadArtwork(_ book: PlaybackBook) {
        guard let coverLoader else { return }
        Task {
            let image = await coverLoader(book.itemID, book.coverPath)
            guard player.book?.key == book.key else { return }
            player.artwork = image
        }
    }

    private func handle(_ event: AudiobookPlayer.Event) {
        switch event {
        case .paused:
            // Pauza z ekranu blokady: system może zaraz uśpić aplikację — prosimy o chwilę.
            if player.isDirty {
                let end = beginBackgroundWork?("Zapis pozycji")
                Task {
                    await sync()
                    end?()
                }
            }
        case .finished:
            guard let book = player.book else { return }
            let end = beginBackgroundWork?("Koniec książki")
            Task {
                await finish(book)
                end?()
            }
        case .remoteFailed:
            player.reload(fresh: true)
        }
    }

    /// Czeka (do ok. 20 s), aż serwer przygotuje segment HLS z danym czasem. Serwer tnie strumień
    /// na segmenty po 6 s (`output-<n>.ts`); brakujący segment każe mu transkodować od tego miejsca.
    private func waitForSegment(at local: Double) async {
        guard let auth = authProvider(), let session else { return }
        let segment = "hls/\(session.id)/output-\(Int(local / 6)).ts"
        for _ in 0..<40 {
            if (try? await auth.perform({ try await $0.streamFileExists(path: segment, token: $1) })) == true { return }
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
        }
        logger.error("Segment strumienia nie pojawił się na czas")
    }

    /// Przed wznowieniem: pozycja z serwera, jeśli ktoś (Mac) zmienił ją od naszej ostatniej.
    private func serverPositionIfChanged() async -> Double? {
        guard let book = player.book, case .server(let itemID, let episodeID) = target(for: book), let auth = authProvider() else { return nil }
        guard let server = try? await auth.perform({ try await $0.progress(itemID: itemID, episodeID: episodeID, token: $1) }),
              !server.isFinished
        else { return nil }
        if let unsent = pending[book.key], unsent.isNewer(thanServer: server.lastUpdate) { return nil }
        let serverTime = server.currentTime ?? 0
        if let lastAgreed, abs(serverTime - lastAgreed) < 1 { return nil }
        logger.notice("Pozycja zmieniła się na serwerze — przejmuję ją przed wznowieniem")
        lastAgreed = serverTime
        pending[book.key] = nil
        return serverTime
    }

    // MARK: - Synchronizacja

    private func startSyncLoop() {
        endSyncLoop()
        syncLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.syncInterval)
                guard let self, !Task.isCancelled else { return }
                if player.isDirty { await sync() }
                if !pending.isEmpty { await flushPending() }
            }
        }
    }

    private func endSyncLoop() {
        syncLoop?.cancel()
        syncLoop = nil
    }

    /// Wysyła bieżącą pozycję, jeśli ją wytworzył ten odtwarzacz. Jedna wysyłka naraz.
    public func sync() async {
        if let syncInFlight { await syncInFlight.value }
        guard player.isDirty, let book = player.book else { return }
        if case .local(let record) = target(for: book) {
            player.isDirty = false
            _ = player.takeListenedTime()
            saveLocal(record, book: book, time: player.currentTime)
            return
        }
        guard let auth = authProvider() else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            let (time, duration) = serverPosition(book, time: player.currentTime)
            let data = AudiobookshelfClient.SyncData(currentTime: time, timeListened: player.takeListenedTime(), duration: duration)
            player.isDirty = false
            do {
                if let session, session.key == book.key {
                    do {
                        try await auth.perform { try await $0.syncSession(id: session.id, data, token: $1) }
                    } catch AudiobookshelfClient.APIError.http(status: 404, _) {
                        // Serwer nie zna już sesji (uruchomiony ponownie) — sam postęp.
                        self.session = nil
                        try await saveProgress(book, time: data.currentTime, auth: auth)
                    }
                } else {
                    try await saveProgress(book, time: data.currentTime, auth: auth)
                }
                lastAgreed = data.currentTime
                pending[book.key] = nil
                // Postęp odcinka z kanału doszedł do odcinka na serwerze — lokalny wpis zbędny.
                if let feedKey = book.feedKey { localEpisodes?.remove(itemID: book.itemID, feedKey: feedKey) }
                progressRevision += 1
                onServerReached?()
            } catch {
                logger.error("Synchronizacja postępu: \(error.localizedDescription, privacy: .public)")
                if player.book?.key == book.key { player.isDirty = true }
                player.returnListenedTime(data.timeListened)
                remember(book, time: data.currentTime)
                reportIfConnection(error)
            }
        }
        syncInFlight = task
        await task.value
        syncInFlight = nil
    }

    private func saveProgress(_ book: PlaybackBook, time: Double, auth: ListeningAuth) async throws {
        guard case .server(let itemID, let episodeID) = target(for: book) else { return }
        let duration = redirectedDurations[book.key] ?? book.duration
        try await auth.perform {
            try await $0.updateProgress(itemID: itemID, episodeID: episodeID, currentTime: time, duration: duration, token: $1)
        }
    }

    /// Pozycja i długość do wysłania na serwer: dla odcinka ze strumienia, który serwer pobrał,
    /// przeliczone na plik serwera (`EpisodeHandover.serverTime`); dla reszty — bez zmian.
    private func serverPosition(_ book: PlaybackBook, time: Double) -> (Double, Double) {
        guard let serverDuration = redirectedDurations[book.key] else { return (time, book.duration) }
        return (EpisodeHandover.serverTime(time, streamDuration: book.duration, serverDuration: serverDuration), serverDuration)
    }

    private func remember(_ book: PlaybackBook, time: Double) {
        switch target(for: book) {
        case .server(let itemID, let episodeID):
            pending[book.key] = PendingPosition(itemID: itemID, episodeID: episodeID, currentTime: time, duration: redirectedDurations[book.key] ?? book.duration, savedAt: .now)
        case .local(let record):
            saveLocal(record, book: book, time: time)
        }
    }

    /// Zamyka sesję; pozycję dosyła tylko wtedy, gdy zmieniła się tutaj.
    private func closeSession() async {
        if let syncInFlight { await syncInFlight.value }
        endSyncLoop()
        guard let book = player.book else { return }
        let dirty = player.isDirty
        let (closeTime, closeDuration) = serverPosition(book, time: player.currentTime)
        let data = AudiobookshelfClient.SyncData(currentTime: closeTime, timeListened: player.takeListenedTime(), duration: closeDuration)
        player.isDirty = false
        defer { session = nil; lastAgreed = nil }
        if case .local(let record) = target(for: book) {
            if dirty { saveLocal(record, book: book, time: data.currentTime) }
            return
        }
        guard let auth = authProvider() else {
            if dirty { remember(book, time: data.currentTime) }
            return
        }
        do {
            if let session, session.key == book.key {
                try await auth.perform { try await $0.closeSession(id: session.id, dirty ? data : nil, token: $1) }
            } else if dirty {
                try await saveProgress(book, time: data.currentTime, auth: auth)
            }
            if dirty {
                pending[book.key] = nil
                if let feedKey = book.feedKey { localEpisodes?.remove(itemID: book.itemID, feedKey: feedKey) }
                progressRevision += 1
            }
        } catch {
            logger.error("Zamknięcie sesji: \(error.localizedDescription, privacy: .public)")
            if dirty { remember(book, time: data.currentTime) }
            reportIfConnection(error)
        }
    }

    /// Książka dobiegła końca: ukończona na serwerze, sesja zamknięta bez pozycji
    /// (późniejsza synchronizacja z wcześniejszą pozycją cofnęłaby „ukończone”).
    private func finish(_ book: PlaybackBook) async {
        if let syncInFlight { await syncInFlight.value }
        endSyncLoop()
        player.isDirty = false
        _ = player.takeListenedTime()
        pending[book.key] = nil
        defer {
            session = nil
            lastAgreed = nil
        }
        let itemID: String
        let episodeID: String?
        switch target(for: book) {
        case .local(let record):
            saveLocal(record, book: book, time: book.duration, finished: true)
            if player.book?.key == book.key { startSyncLoop() }
            return
        case .server(let item, let episode):
            itemID = item
            episodeID = episode
        }
        let finalDuration = redirectedDurations[book.key] ?? book.duration
        guard let auth = authProvider() else { return }
        do {
            try await auth.perform {
                try await $0.updateProgress(itemID: itemID, episodeID: episodeID, currentTime: finalDuration, duration: finalDuration, isFinished: true, token: $1)
            }
            if let feedKey = book.feedKey { localEpisodes?.remove(itemID: book.itemID, feedKey: feedKey) }
            if let session, session.key == book.key {
                try? await auth.perform { try await $0.closeSession(id: session.id, nil, token: $1) }
            }
            progressRevision += 1
        } catch {
            logger.error("Oznaczenie jako ukończone: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
            reportIfConnection(error)
        }
        // Książka zostaje załadowana od początku: ponowne „Odtwarzaj” otworzy nową sesję.
        if player.book?.key == book.key { startSyncLoop() }
    }

    /// Niewysłane pozycje trafiają na serwer, o ile są nowsze niż jego postęp.
    public func flushPending() async {
        guard let auth = authProvider(), !pending.isEmpty else { return }
        for (key, entry) in pending {
            // Bieżąca książka idzie zwykłą synchronizacją (z sesją).
            if key == player.book?.key, player.isDirty { continue }
            do {
                let server = try await auth.perform { try await $0.progress(itemID: entry.itemID, episodeID: entry.episodeID, token: $1) }
                if entry.isNewer(thanServer: server?.lastUpdate) {
                    try await auth.perform {
                        try await $0.updateProgress(itemID: entry.itemID, episodeID: entry.episodeID, currentTime: entry.currentTime, duration: entry.duration, token: $1)
                    }
                    logger.notice("Wysłano zaległą pozycję słuchania")
                    if key == player.book?.key { lastAgreed = entry.currentTime }
                    progressRevision += 1
                }
                if pending[key] == entry { pending[key] = nil }
            } catch AudiobookshelfClient.APIError.http(status: 404, _) {
                pending[key] = nil
            } catch {
                logger.error("Zaległa pozycja: \(error.localizedDescription, privacy: .public)")
                reportIfConnection(error)
                return
            }
        }
    }

    private func reportIfConnection(_ error: any Error) {
        if AddressSelection.isConnectionError(error) { onConnectionError?() }
    }
}
