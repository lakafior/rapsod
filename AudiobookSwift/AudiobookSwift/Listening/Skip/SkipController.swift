// Pochodzenie: kod własny projektu (etap 13a, kolejka modelu — 13b).

import AudiobookshelfKit
import AudiobookshelfPlayback
import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Skip")

/// Znaczniki segmentów sponsorowanych na Macu (etap 13a): wykrywanie bez modelu (opis, rozdziały,
/// nagłówek Megaphone, różnica długości) i zapis pliku `<odcinek>.skip.json` obok odcinka
/// w folderze podcastu — serwer podaje go klientom jak każdy plik pozycji.
///
/// **Kiedy liczy.** Po pobraniu odcinka na serwer (zdarzenie serwera przy otwartym oknie i przegląd
/// najnowszych odcinków przy starcie i co pół godziny — serwer pobiera też przy zamkniętym oknie),
/// oraz przyciskiem na stronie podcastu. Jedno zadanie naraz, z niskim priorytetem: odcinek to dwa
/// fragmenty pliku po 64 KiB, kanał RSS (raz na podcast na pół godziny) i — dla Megaphone —
/// zapytanie o jeden bajt.
///
/// **Model (13b).** Gdy w ustawieniach jest włączone „Wykrywaj fragmenty sponsorowane” (adres, model,
/// zgoda dla tej usługi), po wykrywaniu bez modelu odcinek trafia do drugiej kolejki: transkrypcja na
/// tym Macu (`DictationTranscriber`, pamięć podręczna z 11a), okna transkrypcji do usługi, scalenie,
/// docięcie do ciszy i zapis segmentów `model` w tym samym pliku. Jedno zadanie naraz; kolejka jest
/// w pliku `sponsor-queue.json` w folderze danych serwera, a wyniki okien w punkcie kontrolnym, więc po
/// ponownym uruchomieniu aplikacja kończy przerwane zadanie bez wysyłania drugi raz policzonych okien.
/// Bez tej konfiguracji nic z tej części się nie dzieje i nic nie jest wysyłane.
@MainActor
@Observable
final class SkipController {
    enum Phase: Equatable {
        case queued
        case running
        /// Transkrypcja na tym Macu (ułamek nagrania).
        case transcribing(Double)
        /// Okna wysłane do modelu: gotowe z wszystkich.
        case classifying(Int, Int)
        case done(String)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .queued, .running, .transcribing, .classifying: true
            case .done, .failed: false
            }
        }
    }

    /// Stan wykrywania według klucza odcinka (`ListeningController.key`).
    var phases: [String: Phase] = [:]
    /// Rośnie po zapisie znaczników pozycji — strona podcastu odświeża wtedy podsumowania.
    var revision: [String: Int] = [:]

    /// Pełna pozycja z serwera (konto do słuchania).
    @ObservationIgnored var fetchItem: (@MainActor (_ itemID: String) async throws -> AudiobookshelfClient.ItemDetail)?
    /// Najnowsze odcinki bibliotek podcastów (do przeglądu po pobraniach przy zamkniętym oknie).
    @ObservationIgnored var recentEpisodes: (@MainActor () async throws -> [AudiobookshelfClient.PodcastEpisode])?
    /// Skan pozycji, żeby serwer dopisał nowy plik do plików pozycji (konto administratora).
    @ObservationIgnored var rescan: (@MainActor (_ itemID: String) async -> Void)?
    /// Znaczniki odcinka zmieniły się na dysku (np. gra właśnie ten odcinek).
    @ObservationIgnored var onChanged: (@MainActor (_ itemID: String, _ episodeID: String) -> Void)?

    /// Kolejka modelu (13b) — zapisana w folderze danych, przeżywa ponowne uruchomienie.
    var modelJobs: [ModelJob] = []
    /// Kolejka modelu stoi, dopóki użytkownik nie poprawi ustawień (np. odrzucony klucz).
    var modelPause: String?
    @ObservationIgnored var modelPauseRevision = 0
    @ObservationIgnored var modelFailures: [String: ModelFailure] = [:]
    @ObservationIgnored var modelTask: Task<Void, Never>?
    @ObservationIgnored var runningModelKey: String?
    @ObservationIgnored var userCancelled: Set<String> = []
    @ObservationIgnored var dataRoot: URL?

    @ObservationIgnored private var queue: [(itemID: String, episodeID: String?, force: Bool)] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var sweeper: Task<Void, Never>?
    @ObservationIgnored private var feeds: [String: (date: Date, podcast: RSSPodcast)] = [:]
    @ObservationIgnored let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": "AudiobookSwift (podcast reader)"]
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    /// Automatycznie liczymy tylko odcinki pobrane niedawno: nagłówek Megaphone opisuje bieżący
    /// zestaw reklam, a ten po kilku dniach zwykle nie odpowiada już plikowi na dysku.
    static let recentWindow: TimeInterval = 3 * 24 * 3600
    static let sweepInterval: Duration = .seconds(30 * 60)

    // MARK: - Pliki

    /// Plik znaczników obok pliku audio.
    nonisolated static func skipURL(forAudio audio: URL) -> URL {
        audio.deletingLastPathComponent().appending(path: SkipMap.fileName(forAudio: audio.lastPathComponent))
    }

    nonisolated static func audioURL(_ episode: AudiobookshelfClient.PodcastEpisode) -> URL? {
        guard let path = episode.audioFile?.metadata?.path, FileManager.default.isReadableFile(atPath: path) else { return nil }
        return URL(filePath: path)
    }

    /// Znaczniki odcinka z dysku (`nil` — jeszcze nie liczone albo uszkodzone).
    nonisolated static func map(forAudio audio: URL) -> SkipMap? {
        guard let data = try? Data(contentsOf: skipURL(forAudio: audio)) else { return nil }
        return try? SkipMap.decode(data)
    }

    func map(for episode: AudiobookshelfClient.PodcastEpisode) -> SkipMap? {
        Self.audioURL(episode).flatMap(Self.map(forAudio:))
    }

    @ObservationIgnored private var summaries: [String: (modified: Date, text: String?)] = [:]

    /// Podsumowanie znaczników do wiersza odcinka (z pamięci, dopóki plik się nie zmieni).
    func summary(itemID: String, episode: AudiobookshelfClient.PodcastEpisode) -> String? {
        _ = revision[itemID]
        guard let audio = Self.audioURL(episode) else { return nil }
        let url = Self.skipURL(forAudio: audio)
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        if let cached = summaries[url.path], cached.modified == modified { return cached.text }
        let text = Self.map(forAudio: audio).map(Self.summary)
        summaries[url.path] = (modified, text)
        return text
    }

    /// Zapis znaczników (np. poprawki użytkownika) i zgłoszenie pliku serwerowi.
    func save(_ map: SkipMap, audio: URL, itemID: String) async throws {
        let data = try map.encoded()
        try data.write(to: Self.skipURL(forAudio: audio), options: .atomic)
        revision[itemID, default: 0] += 1
        await rescan?(itemID)
    }

    // MARK: - Kontekst dla odtwarzacza

    /// Znaczniki odcinka, który gra z dysku (serwer na tym samym Macu).
    nonisolated static func context(for book: PlaybackBook) async -> PlaybackCoordinator.SkipContext? {
        guard book.episodeID != nil, book.tracks.count == 1 else { return nil }
        let url: URL
        switch book.tracks[0].source {
        case .serverFile(let file), .file(let file): url = file
        default: return nil
        }
        let duration = book.duration
        return await Task.detached(priority: .userInitiated) {
            guard let actual = try? SkipAudioFingerprint.of(fileAt: url, duration: duration) else { return nil }
            return PlaybackCoordinator.SkipContext(podcastID: book.itemID, map: map(forAudio: url), actual: actual, origin: .server, savesToServer: true)
        }.value
    }

    // MARK: - Kolejka

    func setPhase(_ key: String, _ phase: Phase) {
        guard phases[key] != phase else { return }
        phases[key] = phase
        if key == runningModelKey { publishModelStatus() }
    }

    func phase(itemID: String, episodeID: String) -> Phase? {
        phases[ListeningController.key(itemID, episodeID)]
    }

    var isBusy: Bool { worker != nil }

    /// Wykrywanie dla odcinka (albo wszystkich pobranych odcinków podcastu, `episodeID == nil`).
    /// `force` — także odcinki, które już mają znaczniki (przeliczenie; poprawki zostają).
    func analyze(itemID: String, episodeID: String? = nil, force: Bool = true) {
        if let episodeID { phases[ListeningController.key(itemID, episodeID)] = .queued }
        queue.append((itemID, episodeID, force))
        startWorker()
    }

    /// Przegląd najnowszych odcinków: liczy te pobrane w ostatnich dniach, które nie mają znaczników.
    func startSweeping() {
        guard sweeper == nil else { return }
        // Zadania modelu z poprzedniego uruchomienia (albo sprzed zatrzymania serwera).
        if !modelJobs.isEmpty { startWorker() }
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sweep()
                try? await Task.sleep(for: Self.sweepInterval)
            }
        }
    }

    /// Serwer przestał działać: przegląd i bieżące zadanie stają. Zadania modelu zostają w pliku kolejki
    /// i ruszają przy następnym starcie serwera (także po ponownym uruchomieniu aplikacji).
    func stopSweeping() {
        sweeper?.cancel()
        sweeper = nil
        modelTask?.cancel()
        worker?.cancel()
        worker = nil
        queue = []
    }

    /// Serwer skończył pobierać odcinek — po chwili (skan pozycji) przegląd najnowszych.
    func episodeDownloaded(itemID: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.queue.append((itemID, nil, false))
            self?.startWorker()
        }
    }

    func sweep() async {
        guard let recentEpisodes else { return }
        do {
            let episodes = try await recentEpisodes()
            let cutoff = Date.now.addingTimeInterval(-Self.recentWindow)
            var items: Set<String> = []
            for episode in episodes {
                guard let itemID = episode.libraryItemId, let audio = Self.audioURL(episode),
                      let modified = try? audio.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified > cutoff else { continue }
                if !FileManager.default.fileExists(atPath: Self.skipURL(forAudio: audio).path) {
                    items.insert(itemID)
                } else if needsModel(itemID: itemID, episodeID: episode.id, audio: audio) {
                    enqueueModel(ModelJob(itemID: itemID, episodeID: episode.id, requested: false))
                }
            }
            for itemID in items { queue.append((itemID, nil, false)) }
            if !items.isEmpty { startWorker() }
        } catch {
            logger.notice("Przegląd najnowszych odcinków: \(error.localizedDescription, privacy: .public)")
        }
    }

    func startWorker() {
        guard worker == nil else { return }
        worker = Task(priority: .utility) { [weak self] in
            while let self, !Task.isCancelled {
                if !self.queue.isEmpty {
                    let job = self.queue.removeFirst()
                    await self.run(itemID: job.itemID, episodeID: job.episodeID, force: job.force)
                } else if let job = self.nextModelJob() {
                    await self.runModel(job)
                } else {
                    break
                }
            }
            self?.worker = nil
        }
    }

    private func run(itemID: String, episodeID: String?, force: Bool) async {
        guard let fetchItem else { return }
        let item: AudiobookshelfClient.ItemDetail
        do {
            item = try await fetchItem(itemID)
        } catch {
            if let episodeID { phases[ListeningController.key(itemID, episodeID)] = .failed(error.localizedDescription) }
            return
        }
        let all = item.media.episodes?.elements ?? []
        let cutoff = Date.now.addingTimeInterval(-Self.recentWindow)
        let targets = all.filter { episode in
            guard let audio = Self.audioURL(episode) else { return false }
            if let episodeID { return episode.id == episodeID }
            if force { return true }
            let modified = try? audio.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            guard (modified ?? .distantPast) > cutoff else { return false }
            guard FileManager.default.fileExists(atPath: Self.skipURL(forAudio: audio).path) else { return true }
            if needsModel(itemID: itemID, episodeID: episode.id, audio: audio) {
                enqueueModel(ModelJob(itemID: itemID, episodeID: episode.id, requested: false))
            }
            return false
        }
        if let episodeID, targets.isEmpty {
            phases[ListeningController.key(itemID, episodeID)] = .failed("Pliku odcinka nie ma na tym Macu.")
            return
        }
        guard !targets.isEmpty else { return }
        let feed = await feed(for: item)
        var wrote = false
        for episode in targets {
            guard !Task.isCancelled, let audio = Self.audioURL(episode) else { break }
            let key = ListeningController.key(itemID, episode.id)
            phases[key] = .running
            do {
                let previous = Self.map(forAudio: audio)
                let map = try await SkipAnalyzer.analyze(serverEpisode: episode, podcastID: itemID, feed: feed, audioFile: audio,
                                                         previous: previous, session: session)
                let data = try map.encoded()
                try data.write(to: Self.skipURL(forAudio: audio), options: .atomic)
                wrote = true
                phases[key] = .done(Self.summary(map))
                logger.info("Znaczniki \(audio.lastPathComponent, privacy: .public): \(map.segments.count) segm.")
                onChanged?(itemID, episode.id)
                // Model: odcinek wskazany przyciskiem zawsze (od nowa), pozostałe — gdy model go jeszcze nie liczył.
                if modelEnabled, episodeID != nil || map.modelRun == nil, episodeID != nil || !recentlyFailed(key) {
                    enqueueModel(ModelJob(itemID: itemID, episodeID: episode.id, requested: episodeID != nil))
                }
            } catch {
                phases[key] = .failed(error.localizedDescription)
                logger.error("Znaczniki \(episode.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if wrote {
            revision[itemID, default: 0] += 1
            await rescan?(itemID)
        }
    }

    /// Kanał podcastu (w pamięci przez pół godziny); bez kanału wykrywanie działa na opisie z serwera.
    func feed(for item: AudiobookshelfClient.ItemDetail) async -> RSSPodcast? {
        guard let address = item.media.metadata.feedUrl, let url = RSSFeedParser.webURL(address) else { return nil }
        if let cached = feeds[address], Date.now.timeIntervalSince(cached.date) < 30 * 60 { return cached.podcast }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let podcast = try await Task.detached(priority: .utility) { try RSSFeedParser.parse(data) }.value
            feeds[address] = (.now, podcast)
            return podcast
        } catch {
            logger.notice("Kanał \(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Krótkie podsumowanie wyniku („2 segmenty”, „reklamy wstawione — położenie nieznane”).
    static func summary(_ map: SkipMap) -> String {
        var parts: [String] = []
        let count = map.effectiveSegments.count
        if count > 0 { parts.append(SkipText.segments(count)) }
        if let ads = map.insertedAds, !ads.located { parts.append("reklamy wstawione, położenie nieznane") }
        if parts.isEmpty { parts.append(map.notices.isEmpty ? "nic nie znaleziono" : "tylko wzmianka w opisie") }
        return parts.joined(separator: " · ")
    }
}

/// Napisy o segmentach wspólne dla widoków Maca.
enum SkipText {
    static func segments(_ count: Int) -> String {
        let mod10 = count % 10, mod100 = count % 100
        let word = count == 1 ? "segment" : (2...4).contains(mod10) && !(12...14).contains(mod100) ? "segmenty" : "segmentów"
        return "\(count) \(word)"
    }

    static func range(_ start: Double, _ end: Double) -> String {
        "\(PlaybackFormat.clock(start))–\(PlaybackFormat.clock(end))"
    }
}
