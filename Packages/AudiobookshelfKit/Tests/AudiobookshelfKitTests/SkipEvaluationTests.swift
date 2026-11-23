// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import AudiobookshelfKit

/// Ocena wykrywania na zestawie publicznych odcinków (etap 13a; 13b użyje tego samego jako testu
/// regresji). Wyłączona domyślnie — nagrania i kanały nie są w repozytorium. Uruchomienie:
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
}
