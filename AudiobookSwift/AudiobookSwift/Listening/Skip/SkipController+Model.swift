// Pochodzenie: kod własny projektu (etap 13b).

import AudiobookshelfKit
import AudiobookshelfPlayback
import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Skip")

/// Zadanie modelu dla jednego odcinka.
struct ModelJob: Codable, Hashable, Sendable {
    let itemID: String
    let episodeID: String
    /// Wskazane przyciskiem (liczy od nowa, nawet gdy model już liczył).
    var requested: Bool
    var key: String { itemID + "/" + episodeID }
}

/// Ostatni błąd modelu dla odcinka — przegląd nie ponawia go automatycznie przez `SkipController.failureBackoff`.
struct ModelFailure: Codable, Sendable {
    let date: Date
    let message: String
}

/// Plik kolejki modelu w folderze danych serwera.
private struct ModelQueueFile: Codable {
    var jobs: [ModelJob] = []
    var failures: [String: ModelFailure] = [:]
}

@MainActor
private final class CheckpointBox {
    var value: ModelCheckpoint
    init(_ value: ModelCheckpoint) { self.value = value }
}

/// Wyniki okien przerwanego zadania (pamięć podręczna; klucz: plik, model i wersja promptu).
private struct ModelCheckpoint: Codable {
    let size: Int64?
    let headSHA256: String?
    let model: String
    let version: String
    var windows: [Int: [SponsorClassification.Finding]]
}

extension SkipController {
    static let failureBackoff: TimeInterval = 12 * 3600

    private var store: SponsorDetectionStore { .shared }

    /// Wykrywanie z modelem jest skonfigurowane i włączone (bez odczytu klucza z pęku kluczy).
    var modelEnabled: Bool {
        store.settings.requestConfiguration(apiKey: nil) != nil
    }

    // MARK: - Folder danych i plik kolejki

    /// Folder danych serwera: ustawienia, kolejka z poprzedniego uruchomienia.
    func open(dataRoot: URL) {
        store.open(dataRoot: dataRoot)
        guard self.dataRoot != dataRoot else { return }
        self.dataRoot = dataRoot
        let file = loadQueueFile()
        modelJobs = file.jobs
        modelFailures = file.failures
        for job in modelJobs { setPhase(job.key, .queued) }
        if !modelJobs.isEmpty { logger.notice("Kolejka modelu: \(self.modelJobs.count) zadań z poprzedniego uruchomienia") }
    }

    private var queueURL: URL? { dataRoot?.appending(path: "sponsor-queue.json") }

    private func loadQueueFile() -> ModelQueueFile {
        guard let url = queueURL, let data = try? Data(contentsOf: url) else { return .init() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ModelQueueFile.self, from: data)) ?? .init()
    }

    /// Stan kolejki dla strony ustawień.
    func publishModelStatus() {
        store.queueCount = modelJobs.count
        store.queuePause = modelPause
        store.queueActivity = runningModelKey.flatMap { phases[$0] }.flatMap { phase in
            switch phase {
            case .transcribing(let f): "transkrypcja \(Int((f * 100).rounded())) %"
            case .classifying(let done, let total): "klasyfikacja \(done)/\(total)"
            case .running: "przygotowanie"
            default: nil
            }
        }
        store.resumeQueue = { [weak self] in
            guard let self else { return }
            modelPause = nil
            publishModelStatus()
            startWorker()
        }
    }

    private func saveQueueFile() {
        publishModelStatus()
        guard let url = queueURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Stare błędy (powyżej tygodnia) nie rosną bez końca.
        let cutoff = Date.now.addingTimeInterval(-7 * 24 * 3600)
        let file = ModelQueueFile(jobs: modelJobs, failures: modelFailures.filter { $0.value.date > cutoff })
        try? encoder.encode(file).write(to: url, options: .atomic)
    }

    // MARK: - Kolejka

    func recentlyFailed(_ key: String) -> Bool {
        guard let failure = modelFailures[key] else { return false }
        return Date.now.timeIntervalSince(failure.date) < Self.failureBackoff
    }

    /// Odcinek z przeglądu: model włączony, a w pliku znaczników nie ma jego przebiegu dla tego pliku.
    func needsModel(itemID: String, episodeID: String, audio: URL) -> Bool {
        guard modelEnabled else { return false }
        let key = ListeningController.key(itemID, episodeID)
        guard !recentlyFailed(key), !modelJobs.contains(where: { $0.key == key }) else { return false }
        return Self.map(forAudio: audio)?.modelRun == nil
    }

    func enqueueModel(_ job: ModelJob) {
        guard modelEnabled else { return }
        if let index = modelJobs.firstIndex(where: { $0.key == job.key }) {
            if job.requested { modelJobs[index].requested = true }
        } else {
            modelJobs.append(job)
        }
        if runningModelKey != job.key { setPhase(job.key, .queued) }
        // Przycisk po wstrzymaniu (np. po poprawie klucza) wznawia kolejkę.
        if job.requested { modelPause = nil }
        saveQueueFile()
        startWorker()
    }

    /// Analiza z modelem na żądanie (przycisk w wierszu odcinka).
    func analyzeWithModel(itemID: String, episodeID: String) {
        enqueueModel(ModelJob(itemID: itemID, episodeID: episodeID, requested: true))
    }

    func isModelQueued(itemID: String, episodeID: String) -> Bool {
        modelJobs.contains { $0.key == ListeningController.key(itemID, episodeID) }
    }

    /// „Przerwij”: zadanie wypada z kolejki (bieżące zostaje zatrzymane, punkt kontrolny zostaje).
    func cancelModel(itemID: String, episodeID: String) {
        let key = ListeningController.key(itemID, episodeID)
        modelJobs.removeAll { $0.key == key }
        saveQueueFile()
        if runningModelKey == key {
            userCancelled.insert(key)
            modelTask?.cancel()
        } else {
            phases[key] = nil
        }
    }

    /// Następne zadanie, jeśli kolejka nie stoi. Wstrzymanie mija po zmianie ustawień.
    func nextModelJob() -> SkipController.ModelJobSlot? {
        if modelPause != nil, modelPauseRevision != store.revision { modelPause = nil }
        guard modelPause == nil, dataRoot != nil else { return nil }
        guard modelEnabled else {
            // Wykrywanie wyłączone albo bez zgody — zadania znikają, nic nie zostanie wysłane.
            if !modelJobs.isEmpty {
                for job in modelJobs { phases[job.key] = nil }
                modelJobs = []
                saveQueueFile()
            }
            return nil
        }
        return modelJobs.first.map { ModelJobSlot(job: $0) }
    }

    struct ModelJobSlot { let job: ModelJob }

    // MARK: - Zadanie

    func runModel(_ slot: ModelJobSlot) async {
        let job = slot.job
        let key = job.key
        runningModelKey = key
        let task = Task { [weak self] in _ = await self?.performModel(job) }
        modelTask = task
        await task.value
        modelTask = nil
        runningModelKey = nil
        publishModelStatus()
    }

    private func finish(_ job: ModelJob) {
        modelJobs.removeAll { $0.key == job.key }
        saveQueueFile()
    }

    private func performModel(_ job: ModelJob) async {
        let key = job.key
        guard let configuration = store.requestConfiguration() else { return }
        setPhase(key, .running)
        do {
            let outcome = try await analyzeEpisode(job, configuration: configuration)
            modelFailures[key] = nil
            finish(job)
            phases[key] = .done(outcome)
        } catch {
            if Task.isCancelled || error is CancellationError {
                if userCancelled.remove(key) != nil {
                    phases[key] = .failed("Przerwano.")
                } else {
                    // Zatrzymanie serwera albo aplikacji: zadanie zostaje w pliku kolejki.
                    phases[key] = .queued
                }
                return
            }
            let message = error.localizedDescription
            logger.error("Model \(key, privacy: .public): \(message, privacy: .public)")
            phases[key] = .failed(message)
            if let api = error as? SponsorAPIError, api.needsSettingsChange {
                // Każdy kolejny odcinek skończyłby się tak samo — kolejka czeka na poprawkę ustawień.
                modelPause = message
                modelPauseRevision = store.revision
                publishModelStatus()
                return
            }
            modelFailures[key] = ModelFailure(date: .now, message: message)
            finish(job)
        }
    }

    /// Transkrypcja, klasyfikacja i zapis; zwraca podsumowanie do wiersza odcinka.
    private func analyzeEpisode(_ job: ModelJob, configuration: SponsorAPIConfiguration) async throws -> String {
        let key = job.key
        guard let fetchItem else { throw SpeechTranscription.Failure(message: "Serwer nie odpowiada.") }
        let item = try await fetchItem(job.itemID)
        guard let episode = item.media.episodes?.elements.first(where: { $0.id == job.episodeID }), let audio = Self.audioURL(episode) else {
            throw SpeechTranscription.Failure(message: "Pliku odcinka nie ma na tym Macu.")
        }
        // Znaczniki bez modelu muszą być (odcisk pliku, zakresy z opisu) — gdy ich nie ma, najpierw one.
        let feed = await feed(for: item)
        var base = Self.map(forAudio: audio)
        if base == nil {
            let map = try await SkipAnalyzer.analyze(serverEpisode: episode, podcastID: job.itemID, feed: feed, audioFile: audio, previous: nil, session: session)
            try map.encoded().write(to: Self.skipURL(forAudio: audio), options: .atomic)
            base = map
        }
        guard let base else { throw SpeechTranscription.Failure(message: "Nie udało się zapisać znaczników odcinka.") }
        let duration = episode.audioFile?.duration ?? episode.duration ?? base.audio.duration

        // 1. Transkrypcja (z pamięci podręcznej, jeśli plik był już słuchany).
        guard let locale = await SpeechTranscription.locale(for: [item.media.metadata.language, feed?.language]) else {
            let language = item.media.metadata.language ?? feed?.language ?? "nieznany"
            throw SpeechTranscription.Failure(message: "Rozpoznawanie mowy na tym Macu nie obsługuje języka podcastu (\(language)). Ustaw język w szczegółach podcastu.")
        }
        let ino = episode.audioFile?.ino ?? audio.lastPathComponent
        let size = Double(base.audio.size ?? 0)
        let words: [TextSync.Word]
        if let cached = TranscriptCache.load(locale: locale, ino: ino, size: size, offset: 0) {
            words = cached
        } else {
            setPhase(key, .transcribing(0))
            try await SpeechTranscription.installAssets(locale: locale)
            try Task.checkCancellation()
            let started = Date.now
            words = try await SpeechTranscription.transcribe(file: audio, locale: locale, offset: 0, duration: duration) { [weak self] fraction in
                Task { @MainActor in self?.setPhase(key, .transcribing(fraction)) }
            }
            try Task.checkCancellation()
            TranscriptCache.save(words, locale: locale, ino: ino, size: size, offset: 0)
            logger.info("Transkrypcja \(audio.lastPathComponent, privacy: .public): \(words.count) słów, \(Int(Date.now.timeIntervalSince(started))) s na \(Int(duration)) s nagrania")
        }

        // 2. Klasyfikacja okno po oknie, z punktem kontrolnym.
        let lines = SponsorClassification.lines(from: words)
        var findings: [SponsorClassification.Finding] = []
        var detail = "\(SponsorClassification.version) · \(configuration.model)"
        if lines.count >= 3 {
            let checkpointURL = Self.checkpointURL(episodeID: job.episodeID)
            let checkpoint = CheckpointBox(Self.loadCheckpoint(checkpointURL, audio: base.audio, model: configuration.model))
            let windows = SponsorClassification.windows(lines)
            setPhase(key, .classifying(checkpoint.value.windows.count, windows.count))
            let classifier = SponsorClassifier(client: SponsorAPIClient(configuration: configuration))
            let result = try await classifier.classify(lines: lines, duration: duration, done: checkpoint.value.windows) { [weak self] index, total, windowFindings in
                await MainActor.run {
                    checkpoint.value.windows[index] = windowFindings
                    Self.saveCheckpoint(checkpoint.value, to: checkpointURL)
                    self?.setPhase(key, .classifying(checkpoint.value.windows.count, total))
                }
            }
            findings = result.findings
            let tokens = result.promptTokens + result.completionTokens
            detail += " · \(result.requests) zapyt." + (tokens > 0 ? " · \(tokens) tokenów" : "")
            try? FileManager.default.removeItem(at: checkpointURL)
        } else {
            detail += " · bez mowy"
        }

        // 3. Scalenie i docięcie granic do przerw (cisza w nagraniu, odstępy między słowami).
        let candidates = SponsorClassification.merge(findings, lines: lines)
        let times = candidates.flatMap { [$0.start, $0.end] }
        let silences = times.isEmpty ? [] : ((try? await Task.detached(priority: .utility) { try AudioLevels.silences(in: audio, around: times) }.value) ?? [])
        let gaps = SponsorClassification.wordGaps(words)
        let refined = candidates.map { SponsorClassification.refine($0, silences: silences, gaps: gaps, duration: duration) }
        let segments = SponsorClassification.segments(refined, model: configuration.model)

        // 4. Zapis: plik czytany od nowa tuż przed zapisem (poprawki użytkownika z czasu analizy zostają),
        // bez `await` między odczytem a zapisem; inny plik audio niż na początku — bez zapisu.
        try Task.checkCancellation()
        let actual = try SkipAudioFingerprint.of(fileAt: audio, duration: base.audio.duration)
        guard base.audio.match(actual) == .exact else {
            throw SpeechTranscription.Failure(message: "Plik odcinka zmienił się w trakcie analizy — spróbuj ponownie.")
        }
        var map = (Self.map(forAudio: audio).flatMap { $0.audio.match(actual) == .exact ? $0 : nil }) ?? base
        map = map.replacingSegments(from: .model, with: segments)
        map.runs = map.runs.filter { $0.source != .model } + [SkipRun(source: .model, detail: detail)]
        map.generatedAt = .now
        try map.encoded().write(to: Self.skipURL(forAudio: audio), options: .atomic)
        logger.info("Model \(audio.lastPathComponent, privacy: .public): \(segments.count) segm. (\(detail, privacy: .public))")
        revision[job.itemID, default: 0] += 1
        onChanged?(job.itemID, job.episodeID)
        await rescan?(job.itemID)
        let auto = segments.filter(\.autoSkip).count
        return segments.isEmpty ? "model: nic nie znalazł" : "model: \(SkipText.segments(segments.count))" + (auto < segments.count ? " (\(segments.count - auto) tylko znacznik)" : "")
    }

    // MARK: - Punkt kontrolny

    private static var checkpointFolder: URL {
        URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "AudiobookSwift").appending(path: "Sponsor", directoryHint: .isDirectory)
    }

    private static func checkpointURL(episodeID: String) -> URL {
        checkpointFolder.appending(path: "\(episodeID).json")
    }

    private static func loadCheckpoint(_ url: URL, audio: SkipAudioFingerprint, model: String) -> ModelCheckpoint {
        let fresh = ModelCheckpoint(size: audio.size, headSHA256: audio.headSHA256, model: model, version: SponsorClassification.version, windows: [:])
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(ModelCheckpoint.self, from: data),
              saved.size == audio.size, saved.headSHA256 == audio.headSHA256, saved.model == model, saved.version == SponsorClassification.version else {
            return fresh
        }
        return saved
    }

    private static func saveCheckpoint(_ checkpoint: ModelCheckpoint, to url: URL) {
        try? FileManager.default.createDirectory(at: checkpointFolder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(checkpoint).write(to: url, options: .atomic)
    }
}
