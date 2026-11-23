import AudiobookshelfKit
import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Rozpoznawanie mowy z czasami słów na tym Macu (etap 11): `DictationTranscriber` z ustawieniem
/// do długich nagrań. `SpeechTranscriber` nie ma polskiego (macOS 27), dyktowanie ma i podaje
/// czas każdego słowa. Działa w całości na urządzeniu; zasoby języka instaluje system
/// (`AssetInventory`), raz. Próba: 13 h nagrania w niecałe 10 minut.
enum SpeechTranscription {
    static let engine = "apple-dictation"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Język rozpoznawania dla książki: pierwszy rozpoznany z kolejnych kandydatów (język
    /// z EPUB-a, pole „Język” pozycji), dopasowany do języków dyktowania.
    static func locale(for candidates: [String?]) async -> Locale? {
        let supported = await DictationTranscriber.supportedLocales
        for raw in candidates.compactMap({ $0?.trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty {
            guard let code = languageCode(raw) else { continue }
            let matching = supported.filter { $0.language.languageCode?.identifier == code }
            if matching.isEmpty { continue }
            // Wariant „rodzimy” (pl-PL, de-DE), z regionem tego Maca, najczęstszy dla języka (en-US,
            // a nie pierwszy z listy, np. en-ZA), w ostateczności pierwszy.
            let native = matching.first { $0.region?.identifier.lowercased() == code }
            let local = matching.first { $0.region == Locale.current.region }
            let common = defaultRegions[code].flatMap { region in matching.first { $0.region?.identifier == region } }
            return native ?? local ?? common ?? matching[0]
        }
        return nil
    }

    private static let defaultRegions: [String: String] = [
        "en": "US", "pt": "PT", "es": "ES", "zh": "CN", "ar": "SA", "sv": "SE", "cs": "CZ", "uk": "UA", "da": "DK", "ja": "JP", "ko": "KR",
    ]

    private static let names: [String: String] = [
        "polski": "pl", "polish": "pl", "pol": "pl", "english": "en", "angielski": "en", "eng": "en",
        "german": "de", "deutsch": "de", "niemiecki": "de", "deu": "de", "ger": "de",
        "french": "fr", "français": "fr", "francuski": "fr", "fra": "fr", "fre": "fr",
        "spanish": "es", "español": "es", "hiszpański": "es", "spa": "es",
        "italian": "it", "italiano": "it", "włoski": "it", "ita": "it",
        "russian": "ru", "rosyjski": "ru", "rus": "ru", "ukrainian": "uk", "ukraiński": "uk", "ukr": "uk",
        "czech": "cs", "czeski": "cs", "ces": "cs", "cze": "cs", "portuguese": "pt", "portugalski": "pt", "por": "pt",
        "dutch": "nl", "niderlandzki": "nl", "nld": "nl", "swedish": "sv", "szwedzki": "sv", "swe": "sv",
    ]

    private static func languageCode(_ raw: String) -> String? {
        let lower = raw.lowercased()
        if let code = names[lower] { return code }
        let code = Locale(identifier: lower.replacingOccurrences(of: "_", with: "-")).language.languageCode?.identifier
        return code.flatMap { $0.count == 2 ? $0 : names[$0] }
    }

    static func displayName(_ locale: Locale) -> String {
        Locale(identifier: "pl").localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// Zasoby języka (model systemowy). `true`, gdy trzeba było je pobrać.
    @discardableResult
    static func installAssets(locale: Locale) async throws -> Bool {
        let transcriber = DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return false }
        try await request.downloadAndInstall()
        return true
    }

    /// Słowa jednego pliku z czasem przesuniętym o `offset` (początek pliku w książce).
    /// `progress` dostaje ułamek pliku 0…1.
    static func transcribe(file url: URL, locale: Locale, offset: Double, duration: Double,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [TextSync.Word] {
        let transcriber = DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw Failure(message: "System nie odczyta pliku „\(url.lastPathComponent)” (\(url.pathExtension.uppercased())). Rozpoznawanie mowy obsługuje formaty AVFoundation: M4B, M4A, MP3, AAC, FLAC, WAV, AIFF.")
        }
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
        return try await withTaskCancellationHandler {
            var words: [TextSync.Word] = []
            for try await result in transcriber.results where result.isFinal {
                try Task.checkCancellation()
                var last = 0.0
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespaces)
                    if text.isEmpty { continue }
                    words.append(.init(text: text, start: offset + range.start.seconds, end: offset + range.end.seconds))
                    last = range.end.seconds
                }
                if duration > 0, last > 0 { progress(min(1, last / duration)) }
            }
            try Task.checkCancellation()
            return words
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}

/// Transkrypcje plików audio w pamięci podręcznej aplikacji — to 99% czasu synchronizacji,
/// a wyrównanie trwa sekundę, więc ponowna synchronizacja (np. po wymianie e-booka albo nowej
/// wersji wyrównania) nie słucha nagrania od nowa. Klucz: język, `ino` i rozmiar pliku.
enum TranscriptCache {
    private static var folder: URL {
        URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "AudiobookSwift").appending(path: "TextSync", directoryHint: .isDirectory)
    }

    private static func url(locale: Locale, ino: String, size: Double) -> URL {
        folder.appending(path: "\(locale.identifier)-\(ino)-\(Int(size)).tsv")
    }

    /// Słowa zapisane z czasem względem początku pliku.
    static func load(locale: Locale, ino: String, size: Double, offset: Double) -> [TextSync.Word]? {
        guard let text = try? String(contentsOf: url(locale: locale, ino: ino, size: size), encoding: .utf8) else { return nil }
        var words: [TextSync.Word] = []
        for line in text.split(separator: "\n") {
            let p = line.split(separator: "\t", maxSplits: 2)
            guard p.count == 3, let a = Double(p[0]), let b = Double(p[1]) else { return nil }
            words.append(.init(text: String(p[2]), start: offset + a, end: offset + b))
        }
        return words
    }

    static func save(_ words: [TextSync.Word], locale: Locale, ino: String, size: Double, offset: Double) {
        let text = words.map { String(format: "%.3f\t%.3f\t", $0.start - offset, $0.end - offset) + $0.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? text.write(to: url(locale: locale, ino: ino, size: size), atomically: true, encoding: .utf8)
    }
}
