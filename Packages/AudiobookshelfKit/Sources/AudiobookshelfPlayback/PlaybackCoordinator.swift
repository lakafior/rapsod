// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu — reguły synchronizacji z `ListeningController.swift` aplikacji
// na Maca (etap 9a: wysyłanie tylko pozycji wytworzonej tutaj, „ostatnio uzgodniona” pozycja przed
// wznowieniem, nic po ukończeniu, ponowienie bez sesji po 404), przepisane dla klienta, który
// gra strumień z serwera przez sieć. Kształty zapytań — z kodu serwera audiobookshelf
// (`SessionController.js`, `PlaybackSessionManager.js`), bez przenoszenia jego kodu.
// Odcinki prosto z kanału RSS (etap 10e), pliki pobrane na telefon i trwała kolejka postępu
// (etap 10f): kod własny projektu.

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
/// Nieudana wysyłka zostaje w dzienniku (`journal`, na dysku) i idzie przy następnej okazji —
/// tylko jeśli serwer nie ma nowszego zapisu; przed wznowieniem po pauzie odtwarzacz przejmuje
/// pozycję z serwera, jeśli zmieniła się gdzie indziej.
///
/// **Pozycja pobrana na telefon** (`offlineBook`) gra zawsze z plików, także przy dostępnej sieci,
/// bez sesji na serwerze: słuchanie zapisuje się jako sesja lokalna w dzienniku i idzie na serwer
/// przez `POST /api/session/local-all` (statystyki słuchania; serwer sam odrzuca pozycję starszą
/// niż jego zapis). Bez sieci start bierze pozycję z dziennika.
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
    public var pending: [String: PositionRecord] {
        Dictionary(journal.unsentPositions.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }
    /// Rośnie po każdym zapisie postępu na serwerze — strony pozycji odświeżają wtedy postęp.
    public private(set) var progressRevision = 0
    /// Odcinki z kanału, których postęp idzie już do odcinka na serwerze: klucz odtwarzacza → id odcinka.
    public private(set) var redirected: [String: String] = [:]
    /// Długość pliku na serwerze dla przekierowanych odcinków (pozycja przeliczana proporcjonalnie).
    @ObservationIgnored private var redirectedDurations: [String: Double] = [:]

    /// Trwały postęp na telefonie: niewysłane pozycje, sesje lokalne, odcinki z kanału (jeden na serwer).
    @ObservationIgnored public var journal = ProgressJournal(fileURL: nil)
    /// Pozycja pobrana na telefon, gotowa do grania z plików (`nil` — nie ma jej w całości).
    @ObservationIgnored public var offlineBook: (@MainActor (_ itemID: String, _ episodeID: String?) -> PlaybackBook?)?
    /// Czy jest połączenie z serwerem (bez niego nie ma po co czekać na zapytania).
    @ObservationIgnored public var isReachable: @MainActor () -> Bool = { true }
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
    @ObservationIgnored private var uploadInFlight: Task<Void, Never>?
    /// Sesja lokalna bieżącej pozycji pobranej na telefon.
    @ObservationIgnored private var localSessionID: String?

    /// Komunikat, gdy pozycji nie ma na telefonie, a serwer jest nieosiągalny.
    public static let offlineMessage = "Brak połączenia z serwerem, a tej pozycji nie ma na telefonie. Pobierz ją, gdy połączenie wróci, żeby słuchać bez sieci."

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
        if let stored = journal.record(itemID: book.itemID, feedKey: feedKey) { return .local(stored) }
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
        journal.save(record)
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
        guard startingKey == nil else { return }
        if let downloaded = offlineBook?(itemID, episodeID) {
            await playDownloaded(downloaded, from: position)
            return
        }
        guard isReachable() else {
            loadError = Self.offlineMessage
            return
        }
        guard let auth = authProvider() else { return }
        startingKey = key
        defer { startingKey = nil }
        loadError = nil

        await unloadCurrent()

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
            if let unsent = journal.position(itemID: itemID, episodeID: episodeID), unsent.isUnsent {
                let server = try? await auth.perform { try await $0.progress(itemID: itemID, episodeID: episodeID, token: $1) }
                let resolved = ProgressMerge.start(local: unsent, server: server.map { .some($0) } ?? .none)
                if let resolved, resolved.fromDevice {
                    start = resolved.isFinished ? 0 : resolved.time
                    adoptedLocal = true
                } else {
                    journal.discardUnsent(itemID: itemID, episodeID: episodeID)
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
            loadError = AddressSelection.isConnectionError(error) ? Self.offlineMessage : error.localizedDescription
            reportIfConnection(error)
        }
    }

    /// Poprzednia książka: pozycja na serwer (albo do dziennika), sesja zamknięta.
    private func unloadCurrent() async {
        if player.book != nil {
            player.pause()
            await closeSession()
            player.stop()
        }
        redirected = [:]
        redirectedDurations = [:]
        externalTemplate = nil
    }

    // MARK: - Pozycja pobrana na telefon

    /// Gra z plików na telefonie, bez sesji serwera. Pozycja startowa: nowszy z zapisów — serwera
    /// (gdy odpowie w kilka sekund) albo dziennika na telefonie.
    private func playDownloaded(_ book: PlaybackBook, from position: Double?) async {
        startingKey = book.key
        defer { startingKey = nil }
        loadError = nil
        await unloadCurrent()

        let local = journal.position(itemID: book.itemID, episodeID: book.episodeID)
        var lookup = ServerProgressLookup.unreachable
        if isReachable(), let auth = authProvider() {
            lookup = await lookupProgress(itemID: book.itemID, episodeID: book.episodeID, auth: auth, timeout: .seconds(4))
        }
        if case .some(let remote) = lookup { journal.recordServer(remote) }
        let point = ProgressMerge.start(local: local, server: lookup)
        var start = point.map { $0.isFinished ? 0 : PlaybackTimeline.rewoundStart($0.time) } ?? 0
        if let position { start = position }
        let chosen = point?.fromDevice == true || position != nil

        session = nil
        lastAgreed = point.flatMap { $0.fromDevice ? nil : $0.time }
        player.start(book, at: start)
        openLocalSession(for: book, startTime: start)
        if chosen { player.isDirty = true }
        startSyncLoop()
        loadArtwork(book)
        if chosen || journal.unsentCount > 0 { Task { await uploadJournal() } }
    }

    private func openLocalSession(for book: PlaybackBook, startTime: Double) {
        let session = LocalListeningSession(
            itemID: book.itemID, episodeID: book.episodeID, libraryID: nil,
            mediaType: book.episodeID == nil ? "book" : "podcast",
            displayTitle: book.title, displayAuthor: book.author, duration: book.duration, startTime: startTime
        )
        journal.openSession(session)
        localSessionID = session.id
    }

    /// Bieżąca książka gra z plików na telefonie (sesja lokalna zamiast sesji serwera).
    private func isDownloadedBook(_ book: PlaybackBook) -> Bool {
        book.feedKey == nil && !book.tracks.isEmpty && book.tracks.allSatisfy { if case .file = $0.source { true } else { false } }
    }

    /// Postęp z serwera, ale nie dłużej niż `timeout` — słaba sieć nie może opóźniać startu.
    private func lookupProgress(itemID: String, episodeID: String?, auth: ListeningAuth, timeout: Duration) async -> ServerProgressLookup {
        // Zapytanie przerwane po czasie (anulowanie przerywa też `URLSession`).
        let fetch = Task { @MainActor () -> ServerProgressLookup in
            do {
                let progress = try await auth.perform { try await $0.progress(itemID: itemID, episodeID: episodeID, token: $1) }
                return progress.map { .some($0) } ?? ServerProgressLookup.none
            } catch {
                if !Task.isCancelled { self.reportIfConnection(error) }
                return .unreachable
            }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            fetch.cancel()
        }
        let result = await fetch.value
        timer.cancel()
        return result
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
        await unloadCurrent()
        do {
            guard let original = URL(string: episode.enclosureURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["http", "https"].contains(original.scheme?.lowercased() ?? "") else { throw StreamError.invalidURL }
            let (url, probed) = try await (streamProbe ?? { try await Self.probe($0) })(original)
            guard let duration = probed ?? episode.feedDuration, duration > 1 else { throw StreamError.unknownDuration }

            let stored = journal.record(itemID: episode.itemID, feedKey: episode.feedKey)
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
            if stored == nil { journal.save(record) }
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
        await uploadJournal()
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
    /// Bez sieci od razu `nil`, a z siecią — najwyżej po kilku sekundach.
    private func serverPositionIfChanged() async -> Double? {
        guard let book = player.book, case .server(let itemID, let episodeID) = target(for: book), isReachable(), let auth = authProvider() else { return nil }
        guard case .some(let server) = await lookupProgress(itemID: itemID, episodeID: episodeID, auth: auth, timeout: .seconds(3)),
              !server.isFinished
        else { return nil }
        if let unsent = journal.position(itemID: itemID, episodeID: episodeID), unsent.isUnsent,
           ProgressMerge.isNewer(unsent, thanServer: server.lastUpdate) { return nil }
        let serverTime = server.currentTime ?? 0
        if let lastAgreed, abs(serverTime - lastAgreed) < 1 { return nil }
        logger.notice("Pozycja zmieniła się na serwerze — przejmuję ją przed wznowieniem")
        lastAgreed = serverTime
        journal.recordServer(server)
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
                if journal.unsentCount > 0 { await uploadJournal() }
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
        if isDownloadedBook(book) {
            player.isDirty = false
            recordLocalListening(book, time: player.currentTime)
            await uploadJournal()
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
                confirmSent(book, time: data.currentTime, duration: data.duration)
                // Postęp odcinka z kanału doszedł do odcinka na serwerze — lokalny wpis zbędny.
                if let feedKey = book.feedKey { journal.remove(itemID: book.itemID, feedKey: feedKey) }
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

    /// Słuchanie pobranej pozycji: sesja lokalna (czas słuchania) i pozycja — do dziennika.
    /// Po ukończeniu i ponownym „Odtwarzaj” zaczyna się nowa sesja.
    private func recordLocalListening(_ book: PlaybackBook, time: Double, finished: Bool = false) {
        if localSessionID.flatMap({ journal.session(id: $0) }) == nil { openLocalSession(for: book, startTime: time) }
        let now = Date.now
        if let id = localSessionID {
            journal.updateSession(id: id, currentTime: finished ? book.duration : time, listened: player.takeListenedTime(), at: now)
        }
        journal.recordLocal(itemID: book.itemID, episodeID: book.episodeID, currentTime: time, duration: book.duration, isFinished: finished, at: now)
        progressRevision += 1
    }

    /// Serwer przyjął pozycję bieżącej książki — dziennik pamięta ją jako uzgodnioną.
    private func confirmSent(_ book: PlaybackBook, time: Double, duration: Double, finished: Bool = false) {
        guard case .server(let itemID, let episodeID) = target(for: book) else { return }
        let now = Date.now
        journal.recordLocal(itemID: itemID, episodeID: episodeID, currentTime: time, duration: duration, isFinished: finished, at: now)
        journal.markSent(itemID: itemID, episodeID: episodeID, upTo: now)
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

    /// Nieudana wysyłka: pozycja czeka w dzienniku (na dysku) na powrót połączenia.
    private func remember(_ book: PlaybackBook, time: Double) {
        switch target(for: book) {
        case .server(let itemID, let episodeID):
            journal.recordLocal(itemID: itemID, episodeID: episodeID, currentTime: time, duration: redirectedDurations[book.key] ?? book.duration)
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
        if isDownloadedBook(book) {
            player.isDirty = false
            if dirty { recordLocalListening(book, time: player.currentTime) }
            if let id = localSessionID { journal.closeSession(id: id) }
            localSessionID = nil
            lastAgreed = nil
            await uploadJournal()
            return
        }
        let (closeTime, closeDuration) = serverPosition(book, time: player.currentTime)
        let data = AudiobookshelfClient.SyncData(currentTime: closeTime, timeListened: player.takeListenedTime(), duration: closeDuration)
        player.isDirty = false
        defer { session = nil; lastAgreed = nil }
        if case .local(let record) = target(for: book) {
            if dirty { saveLocal(record, book: book, time: data.currentTime) }
            return
        }
        guard isReachable(), let auth = authProvider() else {
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
                confirmSent(book, time: data.currentTime, duration: data.duration)
                if let feedKey = book.feedKey { journal.remove(itemID: book.itemID, feedKey: feedKey) }
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
        if isDownloadedBook(book) {
            // Bez sieci „ukończone” czeka w dzienniku razem z sesją.
            recordLocalListening(book, time: book.duration, finished: true)
            if let id = localSessionID { journal.closeSession(id: id) }
            localSessionID = nil
            lastAgreed = nil
            await uploadJournal()
            if player.book?.key == book.key { startSyncLoop() }
            return
        }
        _ = player.takeListenedTime()
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
        guard isReachable(), let auth = authProvider() else {
            journal.recordLocal(itemID: itemID, episodeID: episodeID, currentTime: finalDuration, duration: finalDuration, isFinished: true)
            if player.book?.key == book.key { startSyncLoop() }
            return
        }
        do {
            try await auth.perform {
                try await $0.updateProgress(itemID: itemID, episodeID: episodeID, currentTime: finalDuration, duration: finalDuration, isFinished: true, token: $1)
            }
            confirmSent(book, time: finalDuration, duration: finalDuration, finished: true)
            if let feedKey = book.feedKey { journal.remove(itemID: book.itemID, feedKey: feedKey) }
            if let session, session.key == book.key {
                try? await auth.perform { try await $0.closeSession(id: session.id, nil, token: $1) }
            }
            progressRevision += 1
        } catch {
            logger.error("Oznaczenie jako ukończone: \(error.localizedDescription, privacy: .public)")
            journal.recordLocal(itemID: itemID, episodeID: episodeID, currentTime: finalDuration, duration: finalDuration, isFinished: true)
            if !AddressSelection.isConnectionError(error) { loadError = error.localizedDescription }
            reportIfConnection(error)
        }
        // Książka zostaje załadowana od początku: ponowne „Odtwarzaj” otworzy nową sesję.
        if player.book?.key == book.key { startSyncLoop() }
    }

    /// Dawna nazwa wysyłki zaległych pozycji (aplikacja woła ją po powrocie połączenia).
    public func flushPending() async {
        await uploadJournal()
    }

    /// Wysyła dziennik: najpierw sesje lokalne (serwer sam odrzuca pozycję starszą niż jego zapis
    /// i liczy czas słuchania), potem pojedyncze niewysłane pozycje — tylko te nowsze niż serwer.
    /// Jedna wysyłka naraz; bez połączenia nic nie robi.
    public func uploadJournal() async {
        if let uploadInFlight { await uploadInFlight.value }
        guard isReachable(), journal.unsentCount > 0, let auth = authProvider() else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            var sent = false
            defer {
                if sent {
                    progressRevision += 1
                    onServerReached?()
                }
            }
            // 1. Sesje lokalne.
            let sessions = journal.sessionsToUpload
            var sessionKeys: Set<String> = []
            if !sessions.isEmpty {
                let device = device
                let results: [AudiobookshelfClient.LocalSessionResult]
                do {
                    results = try await auth.perform { try await $0.syncLocalSessions(sessions, device: device, token: $1) }
                } catch {
                    logger.error("Wysyłka sesji lokalnych: \(error.localizedDescription, privacy: .public)")
                    reportIfConnection(error)
                    return
                }
                for local in sessions {
                    guard let result = results.first(where: { $0.id == local.id }) else { continue }
                    sessionKeys.insert(local.key)
                    guard result.success else {
                        // Pozycji nie ma już na serwerze — sesja i pozycja nie mają dokąd iść.
                        if result.error?.localizedCaseInsensitiveContains("not found") == true {
                            journal.removeSession(id: local.id)
                            journal.discardUnsent(itemID: local.itemID, episodeID: local.episodeID)
                        }
                        continue
                    }
                    sent = true
                    journal.markUploaded(id: local.id, upTo: local.updatedAt)
                    let position = journal.position(itemID: local.itemID, episodeID: local.episodeID)
                    if result.progressSynced == true {
                        // Sesja nie niesie „ukończone” (nowy postęp z niej nie jest oznaczany) — osobno.
                        if let position, position.isUnsent, position.isFinished, position.updatedAt <= local.updatedAt {
                            do {
                                try await auth.perform {
                                    try await $0.updateProgress(itemID: local.itemID, episodeID: local.episodeID, currentTime: position.duration, duration: position.duration, isFinished: true, token: $1)
                                }
                            } catch {
                                reportIfConnection(error)
                                continue
                            }
                        }
                        journal.markSent(itemID: local.itemID, episodeID: local.episodeID, upTo: local.updatedAt)
                        if local.key == player.book?.key { lastAgreed = local.currentTime }
                    } else if let position, position.isUnsent, position.updatedAt <= local.updatedAt {
                        // Serwer ma nowszy zapis (z innego urządzenia) — on wygrywa.
                        logger.notice("Serwer ma nowszą pozycję niż sesja z telefonu — zostaje serwerowa")
                        journal.discardUnsent(itemID: local.itemID, episodeID: local.episodeID)
                        if let server = try? await auth.perform({ try await $0.progress(itemID: local.itemID, episodeID: local.episodeID, token: $1) }) {
                            journal.recordServer(server)
                        }
                    }
                }
            }
            // 2. Pojedyncze pozycje (ze strumienia, ukończenia) — bez sesji do wysłania.
            for entry in journal.unsentPositions {
                if sessionKeys.contains(entry.key) || journal.sessionsToUpload.contains(where: { $0.key == entry.key }) { continue }
                // Bieżąca książka ze strumienia idzie zwykłą synchronizacją (z sesją).
                if entry.key == player.book?.key, player.isDirty, session != nil { continue }
                do {
                    let server = try await auth.perform { try await $0.progress(itemID: entry.itemID, episodeID: entry.episodeID, token: $1) }
                    switch ProgressMerge.upload(entry, serverLastUpdate: server?.lastUpdate) {
                    case .send:
                        try await auth.perform {
                            try await $0.updateProgress(itemID: entry.itemID, episodeID: entry.episodeID, currentTime: entry.currentTime, duration: entry.duration, isFinished: entry.isFinished ? true : nil, token: $1)
                        }
                        logger.notice("Wysłano zaległą pozycję słuchania")
                        journal.markSent(itemID: entry.itemID, episodeID: entry.episodeID, upTo: entry.updatedAt)
                        if entry.key == player.book?.key { lastAgreed = entry.currentTime }
                        sent = true
                    case .serverIsNewer:
                        journal.discardUnsent(itemID: entry.itemID, episodeID: entry.episodeID)
                        if let server { journal.recordServer(server) }
                        sent = true
                    }
                } catch AudiobookshelfClient.APIError.http(status: 404, _) {
                    journal.removePosition(itemID: entry.itemID, episodeID: entry.episodeID)
                } catch {
                    logger.error("Zaległa pozycja: \(error.localizedDescription, privacy: .public)")
                    reportIfConnection(error)
                    return
                }
            }
        }
        uploadInFlight = task
        await task.value
        uploadInFlight = nil
    }

    private func reportIfConnection(_ error: any Error) {
        if AddressSelection.isConnectionError(error) { onConnectionError?() }
    }
}
