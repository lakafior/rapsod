// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import AudiobookshelfKit

/// Ocena wykrywania na zestawie publicznych odcinków (etap 13a; model z 13b — `modelEvaluation`,
/// a test regresji na zapisanych odpowiedziach modelu bez sieci — `SponsorRegressionTests`). Wyłączona domyślnie — nagrania i kanały nie są w repozytorium. Uruchomienie:
///
///     SKIP_EVAL_MANIFEST=/ścieżka/manifest.json SKIP_EVAL_OUT=/ścieżka/wyniki.jsonl swift test --filter SkipEvaluation
///
/// Manifest: `[{name, feed (plik XML kanału), title (fragment tytułu odcinka; pusty — pierwszy),
/// audio, duration, size, megaphone (nagłówek albo null), total (rozmiar z odpowiedzi), truth: [[start, end, opis]]}]`.
@Suite
struct SkipEvaluation {
    struct Entry: Decodable {
        let name: String
        let feed: String
        let title: String
        let duration: Double
        let size: Int64
        let audioBytes: Int64?
        let megaphone: String?
        let total: Int64?
        let truth: [[Value]]?
    }

    enum Value: Decodable {
        case number(Double), text(String)
        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Double.self) { self = .number(n) } else { self = .text(try c.decode(String.self)) }
        }
        var number: Double? { if case .number(let n) = self { n } else { nil } }
    }

    struct Report: Encodable {
        let name: String
        let truth: Int
        let found: Int
        let segments: [[String]]
        let boundaryErrors: [[Double]]
        let falseRegions: Int
        let contentWronglySkipped: Double
        let adSecondsCovered: Double
        let adSeconds: Double
        let insertedAds: String?
        let notices: [String]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SKIP_EVAL_MANIFEST"] != nil))
    func evaluate() throws {
        let env = ProcessInfo.processInfo.environment
        let manifest = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: URL(filePath: env["SKIP_EVAL_MANIFEST"]!)))
        var lines: [String] = []
        for entry in manifest {
            let feed = try RSSFeedParser.parse(Data(contentsOf: URL(filePath: entry.feed)))
            let rss = try #require(entry.title.isEmpty ? feed.episodes.first : feed.episodes.first { $0.title.contains(entry.title) }, "\(entry.name)")
            let chapters = RSSChapter.ranges(rss.chapters ?? [], duration: entry.duration)
            let input = SkipDetection.Input(description: rss.summary, chapters: chapters.count > 1 ? chapters : [], feedDuration: rss.durationSeconds,
                                            fileDuration: entry.duration, fileSize: entry.size, fileAudioBytes: entry.audioBytes,
                                            megaphone: entry.megaphone.flatMap(MegaphonePayload.parse), megaphoneTotalSize: entry.total)
            let result = SkipDetection.analyze(input)
            let truth = (entry.truth ?? []).compactMap { row -> (Double, Double)? in
                guard row.count >= 2, let a = row[0].number, let b = row[1].number else { return nil }
                return (a, b)
            }
            // Pomijane automatycznie (to, co słuchacz faktycznie straci albo zyska).
            let skipping = result.segments.filter(\.autoSkip)
            func overlap(_ a: (Double, Double), _ b: SkipSegment) -> Double { max(0, min(a.1, b.end) - max(a.0, b.start)) }
            var found = 0
            var errors: [[Double]] = []
            for t in truth {
                guard let best = skipping.max(by: { overlap(t, $0) < overlap(t, $1) }), overlap(t, best) >= 0.5 * (t.1 - t.0) else { continue }
                found += 1
                errors.append([((best.start - t.0) * 10).rounded() / 10, ((best.end - t.1) * 10).rounded() / 10])
            }
            let falseRegions = skipping.filter { s in truth.allSatisfy { overlap($0, s) < 0.3 * s.duration } }.count
            let covered = truth.reduce(0.0) { sum, t in sum + skipping.reduce(0.0) { $0 + overlap(t, $1) } }
            let skipped = skipping.reduce(0.0) { $0 + $1.duration }
            let report = Report(
                name: entry.name, truth: truth.count, found: found,
                segments: result.segments.map { ["\(Int($0.start.rounded()))–\(Int($0.end.rounded()))", $0.kind.rawValue, $0.source.rawValue, $0.autoSkip ? "pomija" : "znacznik"] },
                boundaryErrors: errors, falseRegions: falseRegions, contentWronglySkipped: (skipped - covered).rounded(),
                adSecondsCovered: covered.rounded(), adSeconds: truth.reduce(0) { $0 + $1.1 - $1.0 }.rounded(),
                insertedAds: result.insertedAds.map { "\($0.source.rawValue) located=\($0.located) seconds=\(Int(($0.seconds ?? 0).rounded())) slots=\($0.slots ?? 0)" },
                notices: result.notices.map { "\($0.kind.rawValue): \($0.text)" })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            lines.append(String(decoding: try encoder.encode(report), as: UTF8.self))
        }
        let text = lines.joined(separator: "\n") + "\n"
        if let out = env["SKIP_EVAL_OUT"] { try text.write(toFile: out, atomically: true, encoding: .utf8) }
        print(text)
    }

    /// Wszystkie odcinki kanałów z katalogu `SKIP_EVAL_FEEDS` (same opisy i rozdziały): lista oznaczeń
    /// do przejrzenia pod kątem fałszywych trafień.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SKIP_EVAL_FEEDS"] != nil))
    func feedsSweep() throws {
        let env = ProcessInfo.processInfo.environment
        let directory = URL(filePath: env["SKIP_EVAL_FEEDS"]!)
        var lines: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "xml" {
            guard let feed = try? RSSFeedParser.parse(Data(contentsOf: file)) else { continue }
            var episodes = 0, withRanges = 0, ranges = 0, notices = 0
            for rss in feed.episodes {
                guard let duration = rss.durationSeconds, duration > 0 else { continue }
                episodes += 1
                let chapters = RSSChapter.ranges(rss.chapters ?? [], duration: duration)
                let result = SkipDetection.analyze(.init(description: rss.summary, chapters: chapters.count > 1 ? chapters : [], fileDuration: duration))
                notices += result.notices.count
                guard !result.segments.isEmpty else { continue }
                withRanges += 1
                ranges += result.segments.count
                for segment in result.segments {
                    lines.append("  \(file.lastPathComponent) | \(rss.title.prefix(50)) | \(Int(segment.start))–\(Int(segment.end)) \(segment.kind.rawValue) | \(segment.label ?? "")")
                }
            }
            lines.insert("\(file.lastPathComponent): \(episodes) odcinków, \(withRanges) z zakresami (\(ranges)), \(notices) wzmianek", at: 0)
        }
        let text = lines.joined(separator: "\n") + "\n"
        if let out = env["SKIP_EVAL_OUT"] { try text.write(toFile: out, atomically: true, encoding: .utf8) }
    }

    // MARK: - Model (13b)

    struct ModelEntry: Decodable {
        let name: String
        /// Transkrypcja `DictationTranscriber` (TSV: początek, koniec, słowo).
        let transcript: String
        let duration: Double
        let truth: [[Value]]
    }

    struct ModelReport: Encodable {
        let name: String
        let truth: Int
        let found: Int
        let falseRegions: Int
        let contentWronglySkipped: Double
        let adSecondsCovered: Double
        let adSeconds: Double
        let boundaryErrors: [[Double]]
        let segments: [[String]]
        let categories: [String]
        let requests: Int
        let promptTokens: Int
        let completionTokens: Int
        let seconds: Double
    }

    /// Zestaw z rozpoznania przez prawdziwy model, na kluczu użytkownika (README → 13b). Wyłączony bez
    /// zmiennych; wysyła transkrypcje publicznych odcinków z manifestu do wskazanej usługi.
    ///
    ///     SPONSOR_API_BASE=https://api.mistral.ai/v1 SPONSOR_API_MODEL=mistral-small-latest SPONSOR_API_KEY=… \
    ///     SKIP_EVAL_MODEL_MANIFEST=/ścieżka/manifest.json swift test --filter SkipEvaluation/modelEvaluation
    ///
    /// Opcjonalnie `SKIP_EVAL_WINDOW` (sekundy okna, domyślnie 600; 100000 = cała transkrypcja naraz)
    /// i `SKIP_EVAL_OUT` (plik wyników JSONL). Drukuje też rozkład pewności trafień i fałszywych obszarów.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SKIP_EVAL_MODEL_MANIFEST"] != nil))
    func modelEvaluation() async throws {
        let env = ProcessInfo.processInfo.environment
        let base = try #require(env["SPONSOR_API_BASE"].flatMap(SponsorAPIConfiguration.parseBaseURL), "SPONSOR_API_BASE")
        let model = try #require(env["SPONSOR_API_MODEL"], "SPONSOR_API_MODEL")
        let configuration = SponsorAPIConfiguration(baseURL: base, model: model, apiKey: env["SPONSOR_API_KEY"])
        let defaultWindow = env["SKIP_EVAL_WINDOW"].flatMap(Double.init) ?? 600
        // Warianty: okna|calosc (okna 10 min albo cała transkrypcja) i -id (instrukcja z rozpoznania).
        let variants = (env["SKIP_EVAL_VARIANTS"] ?? "okna").split(separator: ",").map(String.init)
        let rawURL = env["SKIP_EVAL_RAW"].map { URL(filePath: $0) }
        let raw = RawLog()
        let manifest = try JSONDecoder().decode([ModelEntry].self, from: Data(contentsOf: URL(filePath: env["SKIP_EVAL_MODEL_MANIFEST"]!)))
        var lines: [String] = []
        var hits: [Double] = [], misses: [Double] = []
        for variant in variants {
        let window = variant.hasPrefix("calosc") ? 1_000_000 : defaultWindow
        let prompt = SponsorClassification.systemPrompt
        lines.append("== wariant \(variant)")
        for entry in manifest {
            let text = try String(contentsOf: URL(filePath: entry.transcript), encoding: .utf8)
            let words = text.split(separator: "\n").compactMap { line -> TextSync.Word? in
                let p = line.split(separator: "\t", maxSplits: 2)
                guard p.count == 3, let a = Double(p[0]), let b = Double(p[1]) else { return nil }
                return TextSync.Word(text: String(p[2]), start: a, end: b)
            }
            let transcriptLines = SponsorClassification.lines(from: words)
            let started = Date.now
            var classifier = SponsorClassifier(client: SponsorAPIClient(configuration: configuration), windowLength: window, overlap: min(120, window / 5), systemPrompt: prompt)
            let name = entry.name
            classifier.onReply = { w, content in await raw.add("\(variant) \(name) okno \(w.index) (\(w.ids.lowerBound)–\(w.ids.upperBound)): \(content)") }
            let result = try await classifier.classify(lines: transcriptLines, duration: entry.duration)
            let merged = SponsorClassification.merge(result.findings, lines: transcriptLines)
            let categorized = try await classifier.categorize(merged, lines: transcriptLines)
            let candidates = categorized.candidates
                .map { SponsorClassification.refine($0, silences: [], gaps: SponsorClassification.wordGaps(words), duration: entry.duration) }
            let segments = SponsorClassification.segments(candidates, model: model)
            let truth = entry.truth.compactMap { row -> (Double, Double)? in
                guard row.count >= 2, let a = row[0].number, let b = row[1].number else { return nil }
                return (a, b)
            }
            func overlap(_ a: (Double, Double), _ b: SkipSegment) -> Double { max(0, min(a.1, b.end) - max(a.0, b.start)) }
            for segment in segments {
                if truth.allSatisfy({ overlap($0, segment) < 0.3 * segment.duration }) { misses.append(segment.confidence) } else { hits.append(segment.confidence) }
            }
            let skipping = segments.filter(\.autoSkip)
            var found = 0
            var errors: [[Double]] = []
            var categories: [String] = []
            for (t, row) in zip(truth, entry.truth) {
                guard let best = skipping.max(by: { overlap(t, $0) < overlap(t, $1) }), overlap(t, best) >= 0.5 * (t.1 - t.0) else { continue }
                found += 1
                errors.append([((best.start - t.0) * 10).rounded() / 10, ((best.end - t.1) * 10).rounded() / 10])
                if row.count > 2, case .text(let label) = row[2] { categories.append("\(label) → \(best.kind.rawValue)") }
            }
            let covered = truth.reduce(0.0) { sum, t in sum + skipping.reduce(0.0) { $0 + overlap(t, $1) } }
            let report = ModelReport(
                name: entry.name, truth: truth.count, found: found,
                falseRegions: skipping.filter { s in truth.allSatisfy { overlap($0, s) < 0.3 * s.duration } }.count,
                contentWronglySkipped: (skipping.reduce(0.0) { $0 + $1.duration } - covered).rounded(),
                adSecondsCovered: covered.rounded(), adSeconds: truth.reduce(0) { $0 + $1.1 - $1.0 }.rounded(),
                boundaryErrors: errors,
                segments: segments.map { ["\(Int($0.start.rounded()))–\(Int($0.end.rounded()))", $0.kind.rawValue, String(format: "%.2f", $0.confidence), $0.autoSkip ? "pomija" : "znacznik"] },
                categories: categories,
                requests: result.requests + categorized.requests, promptTokens: result.promptTokens + categorized.promptTokens,
                completionTokens: result.completionTokens + categorized.completionTokens,
                seconds: (Date.now.timeIntervalSince(started) * 10).rounded() / 10)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            lines.append(String(decoding: try encoder.encode(report), as: UTF8.self))
        }
        }
        lines.append("pewność trafień: \(hits.sorted().map { String(format: "%.2f", $0) })")
        lines.append("pewność fałszywych obszarów: \(misses.sorted().map { String(format: "%.2f", $0) })")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = env["SKIP_EVAL_OUT"] { try text.write(toFile: out, atomically: true, encoding: .utf8) }
        if let rawURL { try (await raw.lines).joined(separator: "\n").write(to: rawURL, atomically: true, encoding: .utf8) }
        print(text)
    }

    actor RawLog {
        var lines: [String] = []
        func add(_ line: String) { lines.append(line) }
    }
}
