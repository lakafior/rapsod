// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu — reguły synchronizacji z `ListeningController.swift` aplikacji
// na Maca (etap 9a: wysyłanie tylko pozycji wytworzonej tutaj, „ostatnio uzgodniona” pozycja przed
// wznowieniem, nic po ukończeniu, ponowienie bez sesji po 404), przepisane dla klienta, który
// gra strumień z serwera przez sieć. Kształty zapytań — z kodu serwera audiobookshelf
// (`SessionController.js`, `PlaybackSessionManager.js`), bez przenoszenia jego kodu.

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

    /// Bieżące połączenie z serwerem (zmienia się przy przejściu sieć lokalna ↔ tunel).
    @ObservationIgnored public var authProvider: @MainActor () -> ListeningAuth?
    /// Okładka do „Teraz odtwarzane”.
    @ObservationIgnored public var coverLoader: (@MainActor (_ itemID: String, _ coverPath: String?) async -> PlatformImage?)?
    /// Prosi system o chwilę pracy w tle (iOS: `beginBackgroundTask`); zwraca zakończenie.
    @ObservationIgnored public var beginBackgroundWork: (@MainActor (_ name: String) -> (@MainActor () -> Void))?
    /// Zapytanie nie doszło do serwera — warto sprawdzić adres od nowa.
    @ObservationIgnored public var onConnectionError: (@MainActor () -> Void)?

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
        player.book?.key == PlaybackTimeline.key(itemID, episodeID)
    }

    // MARK: - Odtwarzanie

    /// Zaczyna słuchać pozycji (albo odcinka) od miejsca zapisanego na serwerze.
    /// Gdy to już bieżąca książka — wznawia albo zatrzymuje.
    public func play(itemID: String, episodeID: String? = nil) async {
        let key = PlaybackTimeline.key(itemID, episodeID)
        if player.book?.key == key {
            player.togglePlayPause()
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
            session = (playback.id, key)
            lastAgreed = adoptedLocal ? nil : playback.currentTime
            player.start(book, at: start)
            if adoptedLocal { player.isDirty = true }
            startSyncLoop()
            loadArtwork(book)
        } catch {
            logger.error("Start odtwarzania: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
            reportIfConnection(error)
        }
    }

    /// Zatrzymuje odtwarzanie i zamyka książkę (pozycja zostaje na serwerze).
    public func stop() async {
        guard player.book != nil else { return }
        player.pause()
        let end = beginBackgroundWork?("Zamknięcie sesji")
        await closeSession()
        end?()
        player.stop()
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
        if baseURLChanged, let book = player.book, !player.isPlaying,
           book.tracks.contains(where: { if case .file = $0.source { false } else { true } }) {
            // Zatrzymany element trzyma stary adres — przy wznowieniu zbudujemy go od nowa.
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
        if case .file(let url) = track.source { return AVURLAsset(url: url) }
        guard let auth = authProvider() else { throw AudiobookshelfClient.APIError.unauthorized }
        if fresh || session?.key != player.book?.key {
            try await reopenSession()
        }
        guard let session else { throw PlaybackError.noSession }
        let path: String
        switch track.source {
        case .file:
            fatalError("obsłużone wyżej")
        case .sessionTrack(let index):
            path = "public/session/\(session.id)/track/\(index)"
        case .sessionStream:
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
        guard let book = player.book, let auth = authProvider() else { return nil }
        guard let server = try? await auth.perform({ try await $0.progress(itemID: book.itemID, episodeID: book.episodeID, token: $1) }),
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
        guard player.isDirty, let book = player.book, let auth = authProvider() else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            let data = AudiobookshelfClient.SyncData(currentTime: player.currentTime, timeListened: player.takeListenedTime(), duration: book.duration)
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
                progressRevision += 1
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
        try await auth.perform {
            try await $0.updateProgress(itemID: book.itemID, episodeID: book.episodeID, currentTime: time, duration: book.duration, token: $1)
        }
    }

    private func remember(_ book: PlaybackBook, time: Double) {
        pending[book.key] = PendingPosition(itemID: book.itemID, episodeID: book.episodeID, currentTime: time, duration: book.duration, savedAt: .now)
    }

    /// Zamyka sesję; pozycję dosyła tylko wtedy, gdy zmieniła się tutaj.
    private func closeSession() async {
        if let syncInFlight { await syncInFlight.value }
        endSyncLoop()
        guard let book = player.book else { return }
        let dirty = player.isDirty
        let data = AudiobookshelfClient.SyncData(currentTime: player.currentTime, timeListened: player.takeListenedTime(), duration: book.duration)
        player.isDirty = false
        defer { session = nil; lastAgreed = nil }
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
        guard let auth = authProvider() else { return }
        do {
            try await auth.perform {
                try await $0.updateProgress(itemID: book.itemID, episodeID: book.episodeID, currentTime: book.duration, duration: book.duration, isFinished: true, token: $1)
            }
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
