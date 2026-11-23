import AudiobookshelfKit
import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "TextSync")

/// Synchronizacja e-booka z nagraniem (etap 11a): rozpoznawanie mowy, wyrównanie ze zdaniami
/// EPUB-a i zapis mapy `<e-book>.sync.json` w folderze pozycji, potem ponowny skan pozycji,
/// żeby mapa trafiła do plików pozycji na serwerze (i na telefon).
///
/// Żyje w `ListeningController`, nie w oknie: zamknięcie okna biblioteki albo ⌘Q nie przerywa
/// pracy. Jedna synchronizacja naraz (rozpoznawanie i tak zajmuje cały silnik mowy). Plik mapy
/// powstaje dopiero na końcu, więc przerwanie niczego nie zostawia w folderze książki.
@MainActor
@Observable
final class TextSyncController {
    enum Step: Int, CaseIterable, Comparable {
        case prepare, transcribe, align, save

        var title: String {
            switch self {
            case .prepare: "Przygotowanie"
            case .transcribe: "Rozpoznawanie mowy"
            case .align: "Dopasowanie tekstu"
            case .save: "Zapis"
            }
        }

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    enum Phase: Equatable {
        case running(Step)
        case finished(TextSyncMap.Stats)
        case failed(String)
        case canceled
    }

    struct Job: Equatable {
        let itemID: String
        let title: String
        var phase: Phase
        /// Ułamek całej pracy 0…1 (rozpoznawanie to prawie cały czas).
        var progress: Double = 0
        var detail: String?
        var language: String?
        var startedAt = Date.now
        /// Szacowany czas do końca, gdy rozpoznawanie trwa dość długo, by go policzyć.
        var remaining: TimeInterval?
        /// Uwaga po zakończeniu (np. że plik czeka na skan serwera).
        var note: String?

        var isActive: Bool { if case .running = phase { true } else { false } }
        var step: Step? { if case .running(let s) = phase { s } else { nil } }
    }

    private(set) var jobs: [String: Job] = [:]
    /// Zmienia się po zapisie mapy — strona książki wczytuje wtedy mapę od nowa.
    private(set) var mapRevision: [String: Int] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    var activeJob: Job? { jobs.values.first(where: \.isActive) }

    func job(_ itemID: String) -> Job? { jobs[itemID] }

    func clear(itemID: String) {
        if jobs[itemID]?.isActive == false { jobs[itemID] = nil }
    }

    func cancel(itemID: String) {
        tasks[itemID]?.cancel()
    }

    /// Kończy pracę przy wyjściu z aplikacji (bez zapisu niedokończonej mapy).
    func cancelAll() {
        for task in tasks.values { task.cancel() }
    }

    // MARK: - Pliki

    struct Input: Sendable {
        struct Track: Sendable {
            let url: URL
            let ino: String
            let size: Double
            let offset: Double
            let duration: Double
            let filename: String
        }
        let tracks: [Track]
        let ebook: URL
        let ebookFingerprint: TextSyncMap.FileFingerprint
        let folder: URL
        let language: String?
    }

    /// Dlaczego pozycji nie da się zsynchronizować (albo `nil`, gdy się da).
    static func unavailableReason(_ item: AudiobookshelfClient.ItemDetail) -> String? {
        switch input(for: item) {
        case .success: nil
        case .failure(let failure): failure.message
        }
    }

    static func input(for item: AudiobookshelfClient.ItemDetail) -> Result<Input, SpeechTranscription.Failure> {
        guard !item.isPodcast else { return .failure(.init(message: "Synchronizacja dotyczy książek.")) }
        guard let ebook = item.media.ebookFile, let ebookPath = ebook.metadata?.path else {
            return .failure(.init(message: "Książka nie ma e-booka."))
        }
        guard (ebook.ebookFormat ?? (ebookPath as NSString).pathExtension).lowercased() == "epub" else {
            return .failure(.init(message: "Synchronizować da się tylko e-book EPUB."))
        }
        let tracks = item.media.tracks?.elements ?? []
        guard !tracks.isEmpty else { return .failure(.init(message: "Książka nie ma nagrania.")) }
        guard item.isFile != true, let path = item.path else {
            return .failure(.init(message: "Pozycja nie ma własnego folderu, więc mapy nie ma gdzie zapisać."))
        }
        var result: [Input.Track] = []
        for track in tracks {
            guard let p = track.metadata?.path, FileManager.default.isReadableFile(atPath: p) else {
                return .failure(.init(message: "Nie ma dostępu do pliku audio „\(track.metadata?.filename ?? "?")” na tym Macu."))
            }
            result.append(.init(url: URL(filePath: p), ino: track.ino ?? track.metadata?.filename ?? "\(track.index)",
                                size: track.metadata?.size ?? 0, offset: track.startOffset ?? 0,
                                duration: track.duration ?? 0, filename: track.metadata?.filename ?? ""))
        }
        guard FileManager.default.isReadableFile(atPath: ebookPath) else {
            return .failure(.init(message: "Nie ma dostępu do pliku e-booka na tym Macu."))
        }
        return .success(Input(
            tracks: result, ebook: URL(filePath: ebookPath),
            ebookFingerprint: .init(ino: ebook.ino, filename: ebook.metadata?.filename, size: ebook.metadata?.size),
            folder: URL(filePath: path, directoryHint: .isDirectory), language: item.media.metadata.language))
    }

    /// Plik mapy dla obecnego e-booka pozycji (może jeszcze nie istnieć).
    static func mapURL(for item: AudiobookshelfClient.ItemDetail) -> URL? {
        guard item.isFile != true, let path = item.path, let name = item.media.ebookFile?.metadata?.filename else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory).appending(path: TextSyncMap.fileName(forEbook: name))
    }

    static func loadMap(for item: AudiobookshelfClient.ItemDetail) async -> TextSyncMap? {
        guard let url = mapURL(for: item) else { return nil }
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? TextSyncMap.decode(data)
        }.value
    }

    /// Czy mapa powstała z innych plików niż obecne (nowe nagranie albo inny e-book).
    static func isStale(_ map: TextSyncMap, item: AudiobookshelfClient.ItemDetail) -> Bool {
        map.isStale(for: item)
    }

    // MARK: - Praca

    /// `rescan` zgłasza nowy plik serwerowi; zwraca uwagę dla użytkownika, gdy skan się nie odbył.
    func start(item: AudiobookshelfClient.ItemDetail, rescan: @escaping @MainActor () async -> String?) {
        guard activeJob == nil else { return }
        let itemID = item.id
        jobs[itemID] = Job(itemID: itemID, title: item.title, phase: .running(.prepare), detail: "Czytanie e-booka…")
        let input: Input
        switch Self.input(for: item) {
        case .success(let value): input = value
        case .failure(let failure): jobs[itemID]?.phase = .failed(failure.message); return
        }
        tasks[itemID] = Task { [weak self] in
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Synchronizacja tekstu z nagraniem")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                try await self?.run(itemID: itemID, input: input, rescan: rescan)
            } catch is CancellationError {
                self?.jobs[itemID]?.phase = .canceled
            } catch {
                logger.error("Synchronizacja \(itemID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self?.jobs[itemID]?.phase = Task.isCancelled ? .canceled : .failed(error.localizedDescription)
            }
            self?.tasks[itemID] = nil
        }
    }

    private func update(_ itemID: String, _ change: (inout Job) -> Void) {
        guard var job = jobs[itemID] else { return }
        change(&job)
        jobs[itemID] = job
    }

    private func run(itemID: String, input: Input, rescan: @MainActor () async -> String?) async throws {
        // 1. E-book i język.
        let source = try await EpubSource.load(input.ebook)
        // Zdania i rodzaje bloków (nagłówki, cytaty…) — od wersji 2 mapy, do tekstu w odtwarzaczu.
        let document = await Task.detached(priority: .userInitiated) { TextSync.document(spine: source.spine) }.value
        let sentences = document.sentences
        guard !sentences.isEmpty else { throw SpeechTranscription.Failure(message: "W e-booku nie ma tekstu do zsynchronizowania.") }
        guard let locale = await SpeechTranscription.locale(for: [source.language, input.language]) else {
            let lang = source.language ?? input.language ?? "nieznany"
            throw SpeechTranscription.Failure(message: "Rozpoznawanie mowy w tym Macu nie obsługuje języka książki (\(lang)).")
        }
        update(itemID) { $0.language = SpeechTranscription.displayName(locale); $0.detail = "Przygotowanie rozpoznawania mowy…"; $0.progress = 0.01 }
        try Task.checkCancellation()
        update(itemID) { $0.detail = "Sprawdzanie modelu mowy (pierwszy raz system go pobiera)…" }
        try await SpeechTranscription.installAssets(locale: locale)
        try Task.checkCancellation()

        // 2. Rozpoznawanie, plik po pliku; z pamięci podręcznej, gdy plik już był słuchany.
        let total = max(1, input.tracks.reduce(0) { $0 + $1.duration })
        var done = 0.0
        var words: [TextSync.Word] = []
        let started = Date.now
        var heard = 0.0  // tylko nagranie przetwarzane teraz (bez pamięci podręcznej) — do szacowania czasu
        update(itemID) { $0.phase = .running(.transcribe); $0.detail = nil }
        for (index, track) in input.tracks.enumerated() {
            let label = input.tracks.count > 1 ? "Plik \(index + 1) z \(input.tracks.count)" : nil
            if let cached = TranscriptCache.load(locale: locale, ino: track.ino, size: track.size, offset: track.offset) {
                words += cached
                done += track.duration
                update(itemID) { $0.progress = 0.02 + 0.93 * done / total; $0.detail = label.map { "\($0) — z pamięci podręcznej" } }
                continue
            }
            update(itemID) { $0.detail = label }
            let base = done
            let heardSeconds = heard
            let trackWords = try await SpeechTranscription.transcribe(file: track.url, locale: locale, offset: track.offset, duration: track.duration) { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    let heard = heardSeconds + fraction * track.duration
                    let elapsed = Date.now.timeIntervalSince(started)
                    let left = total - base - fraction * track.duration
                    self.update(itemID) {
                        $0.progress = 0.02 + 0.93 * (base + fraction * track.duration) / total
                        // Szacunek dopiero po kilku sekundach pracy, żeby nie skakał.
                        $0.remaining = elapsed > 8 && heard > 0 ? elapsed / heard * left + 2 : nil
                    }
                }
            }
            TranscriptCache.save(trackWords, locale: locale, ino: track.ino, size: track.size, offset: track.offset)
            words += trackWords
            done += track.duration
            heard += track.duration
        }
        try Task.checkCancellation()
        guard words.count > 20 else { throw SpeechTranscription.Failure(message: "W nagraniu nie rozpoznano mowy (\(words.count) słów).") }

        // 3. Wyrównanie.
        update(itemID) { $0.phase = .running(.align); $0.progress = 0.96; $0.remaining = nil; $0.detail = nil }
        let aligned = await Task.detached(priority: .userInitiated) { TextSync.align(sentences: sentences, words: words) }.value
        try Task.checkCancellation()

        // 4. Zapis i skan.
        update(itemID) { $0.phase = .running(.save); $0.progress = 0.98 }
        let map = TextSyncMap(
            engine: SpeechTranscription.engine, locale: locale.identifier(.bcp47),
            audio: input.tracks.map { .init(ino: $0.ino, filename: $0.filename, size: $0.size) },
            ebook: input.ebookFingerprint, stats: aligned.stats, sentences: aligned.sentences, blocks: document.blocks)
        let url = input.folder.appending(path: TextSyncMap.fileName(forEbook: input.ebookFingerprint.filename ?? input.ebook.lastPathComponent))
        let data = try map.encoded()
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
        logger.info("Mapa \(url.lastPathComponent, privacy: .public): \(aligned.stats.direct + aligned.stats.interpolated)/\(aligned.stats.sentences) zdań z czasem")
        mapRevision[itemID, default: 0] += 1
        update(itemID) { $0.detail = "Zgłaszanie pliku serwerowi…" }
        let note = await rescan()
        update(itemID) { $0.phase = .finished(aligned.stats); $0.progress = 1; $0.detail = nil; $0.note = note }
    }
}
