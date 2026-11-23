// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import AudiobookshelfKit
import AudiobookshelfPlayback

typealias SC = SponsorClassification

private func words(_ items: [(String, Double, Double)]) -> [TextSync.Word] {
    items.map { TextSync.Word(text: $0.0, start: $0.1, end: $0.2) }
}

/// Słowa co `step` sekund od `from` do `to` (bez przerw).
private func speech(_ from: Double, _ to: Double, step: Double = 0.4, word: String = "słowo") -> [TextSync.Word] {
    stride(from: from, to: to - step / 2, by: step).map { TextSync.Word(text: word, start: $0, end: $0 + step * 0.9) }
}

@Suite struct SponsorLinesTests {
    @Test func linesBreakAtPausesSentencesAndLength() {
        let w = words([("Dzień", 0, 0.4), ("dobry.", 0.45, 0.9), ("Partnerem", 2.0, 2.5), ("odcinka", 2.55, 3.0), ("jest", 3.05, 3.3)])
            + speech(3.3, 20)
        let lines = SC.lines(from: w)
        #expect(lines[0].text == "Dzień dobry.")   // przerwa 1,1 s
        #expect(lines[1].text.hasPrefix("Partnerem odcinka jest"))
        #expect(lines.allSatisfy { $0.end - $0.start <= 12.01 })
        #expect(lines.map(\.id) == Array(0..<lines.count))
        #expect(lines.last?.end == w.last?.end)
    }

    @Test func windowsOverlapAndCoverEverything() {
        let lines = SC.lines(from: speech(0, 3 * 3600))   // 3 h — bardzo długi odcinek
        let windows = SC.windows(lines)
        #expect(windows.count == 23)   // co 8 min po 10 min
        #expect(windows.first?.start == 0)
        #expect(windows.last?.lines.last?.id == lines.last?.id)
        for (a, b) in zip(windows, windows.dropFirst()) {
            #expect(b.start < a.end - 100)   // zakładka ok. 2 min
        }
        // Każdy wiersz w co najmniej jednym oknie.
        let covered = Set(windows.flatMap { $0.lines.map(\.id) })
        #expect(covered.count == lines.count)
        // Krótki odcinek — jedno okno.
        #expect(SC.windows(SC.lines(from: speech(0, 300))).count == 1)
        #expect(SC.windows([]).isEmpty)
    }

    @Test func promptListsLinesWithClock() {
        let lines = [SC.Line(id: 7, start: 65, end: 70, text: "use code PODCAST"), SC.Line(id: 8, start: 3700, end: 3705, text: "dalej")]
        let window = SC.Window(index: 0, lines: lines)
        let prompt = SC.userPrompt(window, totalDuration: 4000)
        #expect(prompt.contains("7 [01:05] use code PODCAST"))
        #expect(prompt.contains("8 [1:01:40] dalej"))
        #expect(prompt.contains("lines 7–8"))
    }
}

@Suite struct SponsorResponseTests {
    let window = SC.Window(index: 3, lines: (10...20).map { SC.Line(id: $0, start: Double($0) * 10, end: Double($0) * 10 + 9, text: "x") })

    @Test func validAnswer() throws {
        let findings = try SC.parse(#"{"segments":[{"first":11,"last":14,"category":"sponsor","confidence":0.9},{"first":18,"last":18,"category":"selfpromo","confidence":0.4}]}"#, window: window)
        #expect(findings == [.init(first: 11, last: 14, kind: .sponsor, confidence: 0.9, window: 3),
                             .init(first: 18, last: 18, kind: .selfPromo, confidence: 0.4, window: 3)])
    }

    @Test func emptyAnswerIsValid() throws {
        #expect(try SC.parse(#"{"segments":[]}"#, window: window).isEmpty)
    }

    @Test func toleratesFencesSwappedIDsAndPercent() throws {
        let text = "```json\n{\"segments\":[{\"first\":\"15\",\"last\":12,\"category\":\"Self-Promo\",\"confidence\":85}]}\n```"
        let findings = try SC.parse(text, window: window)
        #expect(findings == [.init(first: 12, last: 15, kind: .selfPromo, confidence: 0.85, window: 3)])
    }

    @Test func dropsItemsOutsideWindowOrWithUnknownCategory() throws {
        let text = #"{"segments":[{"first":2,"last":4,"category":"sponsor"},{"first":12,"last":13,"category":"music"},{"first":12,"category":"ad"},{"last":5}]}"#
        let findings = try SC.parse(text, window: window)
        #expect(findings == [.init(first: 12, last: 12, kind: .sponsor, confidence: 0.5, window: 3)])
    }

    @Test func lineListAnswerFromReconPrompt() throws {
        let findings = try SC.parse(#"{"ad_line_ids": [11, 12, 13, 17, 2, 13]}"#, window: window)
        #expect(findings == [.init(first: 11, last: 13, kind: .sponsor, confidence: 0.7, window: 3),
                             .init(first: 17, last: 17, kind: .sponsor, confidence: 0.7, window: 3)])
        #expect(try SC.parse(#"{"ad_line_ids": []}"#, window: window).isEmpty)
    }

    @Test func rejectsNonJSONAndMissingArray() {
        #expect(throws: SC.InvalidResponse.self) { try SC.parse("Nie znalazłem reklam.", window: window) }
        #expect(throws: SC.InvalidResponse.self) { try SC.parse(#"{"ads": "none"}"#, window: window) }
        #expect(throws: SC.InvalidResponse.self) { try SC.parse(#"{"result":[1,2]}"#, window: window) }
    }
}

@Suite struct SponsorMergeTests {
    let lines = (0..<100).map { SC.Line(id: $0, start: Double($0) * 10, end: Double($0) * 10 + 9.5, text: "") }

    @Test func overlappingWindowsAndSmallGapsJoin() {
        let findings: [SC.Finding] = [
            .init(first: 10, last: 14, kind: .sponsor, confidence: 0.7, window: 0),
            .init(first: 13, last: 18, kind: .sponsor, confidence: 0.9, window: 1),   // zakładka okien
            .init(first: 19, last: 20, kind: .sponsor, confidence: 0.5, window: 1),   // 0,5 s przerwy
            .init(first: 40, last: 42, kind: .sponsor, confidence: 0.8, window: 2),   // daleko
        ]
        let merged = SC.merge(findings, lines: lines)
        #expect(merged.map { [$0.start, $0.end] } == [[100, 209.5], [400, 429.5]])
        #expect(merged[0].confidence == 0.9)
        #expect(merged[0].windows == 2)
    }

    @Test func differentKindsStayApartUnlessMostlyOverlapping() {
        let adjacent = SC.merge([.init(first: 10, last: 12, kind: .sponsor, confidence: 0.8, window: 0),
                                 .init(first: 13, last: 14, kind: .selfPromo, confidence: 0.8, window: 0)], lines: lines)
        #expect(adjacent.map(\.kind) == [.sponsor, .selfPromo])
        let overlapping = SC.merge([.init(first: 10, last: 11, kind: .selfPromo, confidence: 0.6, window: 0),
                                    .init(first: 10, last: 15, kind: .sponsor, confidence: 0.8, window: 1)], lines: lines)
        #expect(overlapping.count == 1)
        #expect(overlapping[0].kind == .sponsor)
        #expect(overlapping[0].end == 159.5)
    }

    @Test func refineExtendsIntoAdjacentPausesOnly() {
        let candidate = SC.Candidate(start: 100, end: 160, kind: .sponsor, confidence: 0.9, windows: 1)
        // Cisza tuż przed pierwszym i tuż po ostatnim słowie (czasy słów przesunięte o 0,2 s), odstępy słów.
        let silences = [SC.Pause(start: 99.0, end: 99.8), SC.Pause(start: 160.2, end: 161.4), SC.Pause(start: 158.0, end: 158.6)]
        let gaps = [SC.Pause(start: 99.7, end: 100.0), SC.Pause(start: 160.0, end: 160.4)]
        let both = SC.refine(candidate, silences: silences, gaps: gaps, duration: 1000)
        #expect(abs(both.start - 99.4) < 0.001 && abs(both.end - 160.7) < 0.001)   // najwyżej 0,5 s w ciszę
        let gapsOnly = SC.refine(candidate, silences: [], gaps: gaps, duration: 1000)
        #expect(abs(gapsOnly.start - 99.85) < 0.001 && abs(gapsOnly.end - 160.2) < 0.001)
        // Przerwa wewnątrz segmentu (158 s) i daleko od granic — bez zmian; granica nie wchodzi w słowa.
        let inside = SC.refine(candidate, silences: [SC.Pause(start: 158, end: 159), SC.Pause(start: 101, end: 102), SC.Pause(start: 95, end: 96)], gaps: [], duration: 1000)
        #expect(inside == candidate)
        // Koniec nie wychodzi poza plik.
        let tail = SC.refine(SC.Candidate(start: 900, end: 999.8, kind: .sponsor, confidence: 1, windows: 1), silences: [SC.Pause(start: 999.9, end: 1001)], gaps: [], duration: 1000)
        #expect(tail.end == 1000)
    }

    @Test func wordGaps() {
        let gaps = SC.wordGaps(words([("a", 0, 1), ("b", 1.1, 2), ("c", 2.5, 3)]))
        #expect(gaps == [SC.Pause(start: 2, end: 2.5)])
    }

    @Test func silencesAreRelativeToRecording() {
        // Mowa ok. -20 dB, przerwa -55 dB przez 0,4 s, krótki dołek 0,06 s (nie przerwa).
        var levels = [Float](repeating: -20, count: 200)
        for i in 50..<70 { levels[i] = -55 }
        for i in 120..<123 { levels[i] = -50 }
        let pauses = SC.silences(levels: levels, frameDuration: 0.02, startTime: 10)
        #expect(pauses.count == 1)
        #expect(abs(pauses[0].start - 11) < 0.001 && abs(pauses[0].end - 11.4) < 0.001)
        // Cichsze nagranie (mowa -38 dB, przerwa -70 dB) — ten sam wynik.
        let quiet = levels.map { $0 == -20 ? Float(-38) : $0 - 15 }
        #expect(SC.silences(levels: quiet, frameDuration: 0.02, startTime: 10).count == 1)
        // Sama muzyka bez różnic — nic.
        #expect(SC.silences(levels: [Float](repeating: -18, count: 200), frameDuration: 0.02, startTime: 0).isEmpty)
    }

    @Test func autoSkipPolicyAndSegments() {
        let candidates = [SC.Candidate(start: 10, end: 60, kind: .sponsor, confidence: 0.9, windows: 1),
                          SC.Candidate(start: 100, end: 110, kind: .selfPromo, confidence: 0.95, windows: 1),
                          SC.Candidate(start: 200, end: 260, kind: .sponsor, confidence: 0.3, windows: 1)]
        let segments = SC.segments(candidates, model: "mistral-small-latest")
        #expect(segments.map(\.autoSkip) == [true, false, false])
        #expect(segments.allSatisfy { $0.source == .model && $0.label == "mistral-small-latest" })
        #expect(Set(segments.map(\.id)).count == 3)
    }
}

/// Test regresji na zapisanych odpowiedziach modelu z rozpoznania (bez sieci i bez klucza).
@Suite struct SponsorRegressionTests {
    struct Score: Equatable {
        var found = 0, truth = 0, falseRegions = 0
        var wronglySkipped = 0.0, covered = 0.0
    }

    static func score(policy: SC.AutoSkipPolicy) -> Score {
        var score = Score()
        for episode in SponsorRecordedAnswers.episodes {
            let findings = episode.answer.map { SC.Finding(first: $0, last: $0, kind: .sponsor, confidence: 0.9, window: 0) }
            let skipping = SC.segments(SC.merge(findings, lines: episode.lines), policy: policy, model: "zapis").filter(\.autoSkip)
            func overlap(_ t: (Double, Double), _ s: SkipSegment) -> Double { max(0, min(t.1, s.end) - max(t.0, s.start)) }
            for t in episode.truth {
                score.truth += 1
                if skipping.contains(where: { overlap(t, $0) >= 0.5 * (t.1 - t.0) }) { score.found += 1 }
            }
            score.falseRegions += skipping.filter { s in episode.truth.allSatisfy { overlap($0, s) < 0.3 * s.duration } }.count
            let covered = episode.truth.reduce(0.0) { sum, t in sum + skipping.reduce(0.0) { $0 + overlap(t, $1) } }
            score.covered += covered
            score.wronglySkipped += skipping.reduce(0.0) { $0 + $1.duration } - covered
        }
        return score
    }

    /// Zakresy z opisu, które 13a wyznaczyło na tych odcinkach (`etap13a-zestaw/wyniki.jsonl`).
    static let descriptionRanges: [String: [(Double, Double, SkipKind)]] = [
        "pl_kryminatorium": [(105, 225, .selfPromo)],
        "en_syntax": [(216, 240, .sponsor)],
    ]

    /// Plik po 13a i 13b razem, przez `effectiveSegments` (to, co pomija odtwarzacz).
    static func combinedScore(description: Bool, model: Bool) -> Score {
        var score = Score()
        for episode in SponsorRecordedAnswers.episodes {
            var segments: [SkipSegment] = []
            if description {
                segments += (descriptionRanges[episode.name] ?? []).map { SkipSegment(start: $0.0, end: $0.1, kind: $0.2, source: .description, confidence: 0.85) }
            }
            if model {
                let findings = episode.answer.map { SC.Finding(first: $0, last: $0, kind: .sponsor, confidence: 0.9, window: 0) }
                segments += SC.segments(SC.merge(findings, lines: episode.lines), model: "zapis")
            }
            let map = SkipMap(episode: .init(), audio: SkipAudioFingerprint(duration: 10_000), segments: segments)
            let plan = SkipPlan(map: map, actual: nil, settings: .standard).entries.filter { $0.action == .skip }
            func overlap(_ t: (Double, Double), _ s: SkipPlan.Entry) -> Double { max(0, min(t.1, s.end) - max(t.0, s.start)) }
            for t in episode.truth {
                score.truth += 1
                if plan.contains(where: { overlap(t, $0) >= 0.5 * (t.1 - t.0) }) { score.found += 1 }
            }
            score.falseRegions += plan.filter { s in episode.truth.allSatisfy { overlap($0, s) < 0.3 * s.duration } }.count
            let covered = episode.truth.reduce(0.0) { sum, t in sum + plan.reduce(0.0) { $0 + overlap(t, $1) } }
            score.covered += covered
            score.wronglySkipped += plan.reduce(0.0) { $0 + $1.duration } - covered
        }
        return score
    }

    @Test func combinedWithDescriptionRanges() {
        let only13a = Self.combinedScore(description: true, model: false)
        let onlyModel = Self.combinedScore(description: false, model: true)
        let both = Self.combinedScore(description: true, model: true)
        #expect(only13a.found == 2)
        #expect(onlyModel.found == 7)
        // Razem: trafienia modelu i pełny blok z opisu w Kryminatorium (model zgubił jego środek) — 8/10.
        // Reguła „model zawsze zastępuje opis” dawała tyle co sam model (7/10, 442 s pokrycia).
        #expect(both.found == 8 && both.falseRegions == 0)
        #expect(both.covered > onlyModel.covered + 30)
        #expect(both.wronglySkipped <= onlyModel.wronglySkipped + 6)
        print("13a: \(only13a), model: \(onlyModel), razem: \(both)")
    }

    @Test func recordedAnswersWithStandardPolicy() {
        let standard = Self.score(policy: .standard)
        #expect(standard.truth == 10)
        #expect(standard.found == 7)
        #expect(standard.falseRegions == 0)
        #expect(standard.wronglySkipped < 30)
        #expect(standard.covered > 440)
        // Bez progu długości: te same trafienia, ale 3 fałszywe obszary (5, 8 i 13 s) pomijane automatycznie.
        let noMinimum = Self.score(policy: .init(minimumConfidence: 0, minimumDuration: 0))
        #expect(noMinimum.found == 7)
        #expect(noMinimum.falseRegions == 3)
        // Za wysoki próg (20 s) gubi krótką autopromocję na końcu Kryminatorium (18 s).
        #expect(Self.score(policy: .init(minimumConfidence: 0, minimumDuration: 20)).found == 6)
    }
}

/// Docinanie granic na zapisanych odpowiedziach z prawdziwymi nagraniami i transkrypcjami z rozpoznania
/// (pliki poza repozytorium): `SKIP_EVAL_TX_DIR=<…/tx> SKIP_EVAL_AUDIO_DIR=<…/audio> swift test --filter SponsorBoundaryEvaluation`.
@Suite struct SponsorBoundaryEvaluation {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SKIP_EVAL_AUDIO_DIR"] != nil))
    func boundariesOnRecordings() throws {
        let env = ProcessInfo.processInfo.environment
        let tx = URL(filePath: env["SKIP_EVAL_TX_DIR"]!), audioDir = URL(filePath: env["SKIP_EVAL_AUDIO_DIR"]!)
        var rows: [String] = []
        var raw: [Double] = [], gapsOnly: [Double] = [], full: [Double] = []
        for episode in SponsorRecordedAnswers.episodes {
            let text = try String(contentsOf: tx.appending(path: episode.name + ".tsv"), encoding: .utf8)
            let words = text.split(separator: "\n").compactMap { line -> TextSync.Word? in
                let p = line.split(separator: "\t", maxSplits: 2)
                guard p.count == 3, let a = Double(p[0]), let b = Double(p[1]) else { return nil }
                return TextSync.Word(text: String(p[2]), start: a, end: b)
            }
            let findings = episode.answer.map { SC.Finding(first: $0, last: $0, kind: .sponsor, confidence: 0.9, window: 0) }
            let candidates = SC.merge(findings, lines: episode.lines)
            let audio = audioDir.appending(path: episode.name + ".mp3")
            let silences = try AudioLevels.silences(in: audio, around: candidates.flatMap { [$0.start, $0.end] })
            let gaps = SC.wordGaps(words)
            for c in candidates {
                guard let t = episode.truth.first(where: { min($0.1, c.end) - max($0.0, c.start) > 0.5 * ($0.1 - $0.0) }) else { continue }
                let g = SC.refine(c, silences: [], gaps: gaps, duration: 1e9)
                let f = SC.refine(c, silences: silences, gaps: gaps, duration: 1e9)
                raw += [abs(c.start - t.0), abs(c.end - t.1)]
                gapsOnly += [abs(g.start - t.0), abs(g.end - t.1)]
                full += [abs(f.start - t.0), abs(f.end - t.1)]
                rows.append(String(format: "%@ prawda %.1f–%.1f | wiersze %.1f–%.1f | słowa %.1f–%.1f | cisza %.1f–%.1f",
                                   episode.name, t.0, t.1, c.start, c.end, g.start, g.end, f.start, f.end))
            }
        }
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        rows.append(String(format: "mediana |błędu granic|: wiersze %.2f s, + odstępy słów %.2f s, + cisza %.2f s (n=%d granic)", median(raw), median(gapsOnly), median(full), raw.count))
        rows.append(String(format: "maks.: wiersze %.1f s, + odstępy %.1f s, + cisza %.1f s", raw.max() ?? 0, gapsOnly.max() ?? 0, full.max() ?? 0))
        print(rows.joined(separator: "\n"))
    }
}

@Suite struct SponsorSettingsTests {
    @Test func requestsOnlyWithEnabledConsentAndConfiguration() {
        var settings = SponsorDetectionSettings(enabled: true, baseURL: "https://api.mistral.ai/v1", model: "mistral-small-latest")
        #expect(settings.requestConfiguration(apiKey: "k") == nil)          // brak zgody
        #expect(settings.checkConfiguration(apiKey: "k") != nil)            // sprawdzenie połączenia bez transkrypcji
        settings.consentHost = "api.mistral.ai"
        #expect(settings.requestConfiguration(apiKey: "k")?.endpoint.absoluteString == "https://api.mistral.ai/v1/chat/completions")
        settings.enabled = false
        #expect(settings.requestConfiguration(apiKey: "k") == nil)
        settings.enabled = true
        settings.baseURL = "https://generativelanguage.googleapis.com/v1beta/openai/"   // inna usługa — zgoda nie przechodzi
        #expect(settings.requestConfiguration(apiKey: "k") == nil)
        settings.consentHost = "generativelanguage.googleapis.com"
        #expect(settings.requestConfiguration(apiKey: nil)?.endpoint.absoluteString == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        settings.model = "  "
        #expect(settings.requestConfiguration(apiKey: "k") == nil)
        #expect(SponsorDetectionSettings().requestConfiguration(apiKey: "k") == nil)
    }

    @Test func baseURLParsing() {
        #expect(SponsorAPIConfiguration.parseBaseURL("api.openai.com/v1")?.absoluteString == "https://api.openai.com/v1")
        #expect(SponsorAPIConfiguration.parseBaseURL("ftp://x.y") == nil)
        #expect(SponsorAPIConfiguration.parseBaseURL("https://user:pass@x.y/v1") == nil)
        #expect(SponsorAPIConfiguration.parseBaseURL("") == nil)
        let full = SponsorAPIConfiguration(baseURL: URL(string: "http://127.0.0.1:8080/v1/chat/completions")!, model: "m", apiKey: "")
        #expect(full.endpoint.absoluteString == "http://127.0.0.1:8080/v1/chat/completions")
        #expect(full.apiKey == nil)
    }

    @Test func settingsFileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "sponsor-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SponsorDetectionSettings.load(from: url) == SponsorDetectionSettings())
        let settings = SponsorDetectionSettings(enabled: true, baseURL: "https://api.mistral.ai/v1", model: "mistral-small-latest",
                                                consentHost: "api.mistral.ai", consentDate: Date(timeIntervalSince1970: 1_800_000_000))
        try settings.save(to: url)
        #expect(SponsorDetectionSettings.load(from: url) == settings)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.lowercased().contains("key"))
    }
}

// MARK: - Klient API (atrapa w URLProtocol)

final class ChatStub: URLProtocol, @unchecked Sendable {
    enum Reply {
        case http(Int, String, [String: String] = [:])
        case failure(URLError.Code)
    }

    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    nonisolated(unsafe) static var headers: [[String: String]] = []
    nonisolated(unsafe) static var urls: [URL] = []
    static let lock = NSLock()

    static func reset(_ replies: [Reply]) {
        lock.withLock {
            self.replies = replies
            bodies = []
            headers = []
            urls = []
        }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatStub.self]
        return URLSession(configuration: configuration)
    }

    static func answer(_ content: String, prompt: Int = 1000, completion: Int = 20) -> Reply {
        let escaped = String(decoding: try! JSONSerialization.data(withJSONObject: [content], options: []), as: UTF8.self).dropFirst().dropLast()
        return .http(200, #"{"choices":[{"message":{"role":"assistant","content":\#(escaped)}}],"usage":{"prompt_tokens":\#(prompt),"completion_tokens":\#(completion)}}"#)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        let reply: Reply = Self.lock.withLock {
            Self.bodies.append((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
            Self.headers.append(request.allHTTPHeaderFields ?? [:])
            Self.urls.append(request.url!)
            return Self.replies.isEmpty ? .http(500, "{}") : Self.replies.removeFirst()
        }
        switch reply {
        case .http(let status, let body, let headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers.merging(["Content-Type": "application/json"]) { a, _ in a })!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

private actor Sleeps {
    var values: [Double] = []
    func add(_ value: Double) { values.append(value) }
}

@Suite(.serialized) struct SponsorAPIClientTests {
    let configuration = SponsorAPIConfiguration(baseURL: URL(string: "https://api.example.test/v1")!, model: "small-model", apiKey: "sekret-123")

    private func client(_ sleeps: Sleeps = Sleeps()) -> SponsorAPIClient {
        SponsorAPIClient(configuration: configuration, session: ChatStub.session(), sleep: { await sleeps.add($0) })
    }

    @Test func successSendsJSONModeAndKey() async throws {
        ChatStub.reset([ChatStub.answer(#"{"segments":[]}"#)])
        let reply = try await client().complete(system: "s", user: "u", maxTokens: 100)
        #expect(reply == ChatReply(content: #"{"segments":[]}"#, promptTokens: 1000, completionTokens: 20))
        let body = ChatStub.bodies[0]
        #expect(body["model"] as? String == "small-model")
        #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
        #expect(body["temperature"] as? Int == 0)
        #expect(ChatStub.headers[0]["Authorization"] == "Bearer sekret-123")
        #expect(ChatStub.urls[0].absoluteString == "https://api.example.test/v1/chat/completions")
    }

    @Test func rateLimitHonoursRetryAfterThenSucceeds() async throws {
        ChatStub.reset([.http(429, #"{"error":{"message":"slow down"}}"#, ["Retry-After": "7"]), .http(503, "{}"), ChatStub.answer("{\"segments\":[]}")])
        let sleeps = Sleeps()
        _ = try await client(sleeps).complete(system: "s", user: "u", maxTokens: 100)
        #expect(await sleeps.values == [7, 4])
        #expect(ChatStub.bodies.count == 3)
    }

    @Test func persistentRateLimitGivesReadableError() async {
        ChatStub.reset(Array(repeating: .http(429, "{}"), count: 6))
        await #expect(throws: SponsorAPIError.rateLimited) { _ = try await client().complete(system: "s", user: "u", maxTokens: 10) }
        #expect(ChatStub.bodies.count == 4)
    }

    @Test func droppedConnectionIsRetried() async throws {
        ChatStub.reset([.failure(.networkConnectionLost), .failure(.timedOut), ChatStub.answer("{\"segments\":[]}")])
        _ = try await client().complete(system: "s", user: "u", maxTokens: 10)
        #expect(ChatStub.bodies.count == 3)
        ChatStub.reset(Array(repeating: .failure(.cannotConnectToHost), count: 5))
        do {
            _ = try await client().complete(system: "s", user: "u", maxTokens: 10)
            Issue.record("bez błędu")
        } catch let error as SponsorAPIError {
            #expect(error == .network("usługa nie przyjmuje połączeń"))
        }
    }

    @Test func unauthorizedFailsAtOnceWithoutKeyInMessage() async {
        ChatStub.reset([.http(401, #"{"error":{"message":"Invalid key sekret-123"}}"#)])
        do {
            _ = try await client().complete(system: "s", user: "u", maxTokens: 10)
            Issue.record("bez błędu")
        } catch let error as SponsorAPIError {
            #expect(error == .unauthorized(status: 401))
            #expect(error.needsSettingsChange)
            #expect(!(error.errorDescription ?? "").contains("sekret"))
        } catch {
            Issue.record("\(error)")
        }
        #expect(ChatStub.bodies.count == 1)
    }

    @Test func badRequestFallsBackToMinimalBodyOnce() async throws {
        ChatStub.reset([.http(400, #"{"error":{"message":"response_format not supported"}}"#), ChatStub.answer("{\"segments\":[]}")])
        let api = client()
        _ = try await api.complete(system: "s", user: "u", maxTokens: 10)
        #expect(ChatStub.bodies[1]["response_format"] == nil && ChatStub.bodies[1]["temperature"] == nil)
        // Kolejne zapytania od razu minimalne; drugi 400 to błąd z komunikatem usługi (bez klucza).
        ChatStub.reset([.http(400, #"{"error":{"message":"model sekret-123 is not a chat model"}}"#)])
        do {
            _ = try await api.complete(system: "s", user: "u", maxTokens: 10)
            Issue.record("bez błędu")
        } catch let error as SponsorAPIError {
            #expect(error == .badRequest("model ••• is not a chat model"))
        }
        #expect(ChatStub.bodies.count == 1 && ChatStub.bodies[0]["response_format"] == nil)
    }

    @Test func notFoundNamesModel() async {
        ChatStub.reset([.http(404, "{}")])
        await #expect(throws: SponsorAPIError.notFound(model: "small-model")) { _ = try await client().complete(system: "s", user: "u", maxTokens: 10) }
    }

    @Test func responseWithoutChoicesIsFormatError() async {
        ChatStub.reset([.http(200, #"{"object":"error"}"#)])
        await #expect(throws: SponsorAPIError.invalidFormat("odpowiedź usługi bez „choices”")) { _ = try await client().complete(system: "s", user: "u", maxTokens: 10) }
    }

    // MARK: Klasyfikator

    private func lines(_ duration: Double) -> [SC.Line] {
        stride(from: 0.0, to: duration, by: 10).enumerated().map { SC.Line(id: $0.offset, start: $0.element, end: $0.element + 9.5, text: "w") }
    }

    @Test func classifierResumesFromCheckpointAndSkipsDoneWindows() async throws {
        let all = lines(1500)   // 25 min — 3 okna
        let windows = SC.windows(all)
        #expect(windows.count == 3)
        let done: [Int: [SC.Finding]] = [0: [SC.Finding(first: 2, last: 5, kind: .sponsor, confidence: 0.9, window: 0)]]
        let first = windows[1].ids.lowerBound
        ChatStub.reset([ChatStub.answer(#"{"segments":[{"first":\#(first + 1),"last":\#(first + 4),"category":"selfpromo","confidence":0.8}]}"#),
                        ChatStub.answer(#"{"segments":[]}"#)])
        let recorder = Sleeps()
        let result = try await SponsorClassifier(client: client()).classify(lines: all, duration: 1500, done: done) { index, total, _ in
            await recorder.add(Double(index * 10 + total))
        }
        #expect(result.requests == 2)
        #expect(result.findings.map(\.window) == [0, 1])
        #expect(result.promptTokens == 2000)
        #expect(await recorder.values == [13, 23])
        // Zapytanie zawiera tylko wiersze okna.
        let messages = ChatStub.bodies[0]["messages"] as? [[String: String]]
        #expect(messages?[1]["content"]?.contains("\(first) [") == true)
        #expect(messages?[0]["content"] == SC.systemPrompt)
    }

    @Test func classifierRetriesBadFormatOnceThenFails() async throws {
        let all = lines(300)
        ChatStub.reset([ChatStub.answer("Oto reklamy: brak"), ChatStub.answer(#"{"segments":[{"first":3,"last":4,"category":"sponsor","confidence":0.7}]}"#)])
        let ok = try await SponsorClassifier(client: client()).classify(lines: all, duration: 300)
        #expect(ok.findings.count == 1 && ok.requests == 2)
        let second = (ChatStub.bodies[1]["messages"] as? [[String: String]])?[1]["content"]
        #expect(second?.hasSuffix(SC.formatReminder) == true)

        ChatStub.reset([ChatStub.answer("nie"), ChatStub.answer("nadal nie")])
        await #expect(throws: SponsorAPIError.invalidFormat("to nie jest JSON")) {
            _ = try await SponsorClassifier(client: client()).classify(lines: all, duration: 300)
        }
    }

    @Test func classifierEmptyTranscript() async throws {
        ChatStub.reset([])
        let result = try await SponsorClassifier(client: client()).classify(lines: [], duration: 0)
        #expect(result.windows == 0 && result.requests == 0 && ChatStub.bodies.isEmpty)
    }
}

// MARK: - Plik znaczników i ustawienia

@Suite struct SponsorMapTests {
    let audio = SkipAudioFingerprint(filename: "a.mp3", size: 1000, duration: 3600, headSHA256: "h", tailSHA256: "t")

    private func segment(_ start: Double, _ end: Double, _ source: SkipSource, kind: SkipKind = .sponsor, autoSkip: Bool = true) -> SkipSegment {
        SkipSegment(id: "\(source.rawValue)-\(Int(start))", start: start, end: end, kind: kind, source: source, confidence: 0.9, autoSkip: autoSkip)
    }

    @Test func modelAndDescriptionAreNotDoubled() {
        let map = SkipMap(episode: .init(), audio: audio, segments: [
            segment(105, 225, .description, kind: .selfPromo),              // pewny zakres z opisu (pomija się)
            segment(600, 1100, .description, autoSkip: false),              // długi zakres z opisu (tylko znacznik)
            segment(1200, 1500, .description, autoSkip: false),             // długi, a model niepewny
            segment(2000, 2060, .description),                              // model tu nic nie znalazł
            segment(3000, 3030, .chapters),
            segment(1600, 1660, .megaphone),
            segment(105, 125, .model, kind: .selfPromo),                    // model zgubił środek bloku
            segment(164, 218, .model, kind: .selfPromo),
            segment(640, 700, .model),
            segment(1300, 1310, .model, autoSkip: false),
            segment(3005, 3028, .model),
            segment(1590, 1665, .model),
        ])
        let effective = map.effectiveSegments.map { "\($0.source.rawValue) \(Int($0.start))" }
        #expect(effective == ["description 105", "model 640", "description 1200", "model 1300", "model 1590", "megaphone 1600",
                              "description 2000", "chapters 3000"])
        // Nowe wykrywanie z opisu niczego nie dubluje.
        let redone = map.replacingSegments(from: .description, with: [segment(106, 224, .description), segment(600, 1100, .description, autoSkip: false)])
        #expect(redone.effectiveSegments.filter { $0.start < 1200 }.map(\.start) == [106, 640])
    }

    @Test func userRejectionOfModelSegmentKeepsLongDescriptionHidden() {
        var map = SkipMap(episode: .init(), audio: audio, segments: [segment(100, 400, .description, autoSkip: false), segment(110, 190, .model)])
        #expect(map.effectiveSegments.map(\.source) == [.model])
        map.remove(map.effectiveSegments[0])
        #expect(map.effectiveSegments.isEmpty)
    }

    @Test func modelSegmentsReplaceOnlyTheirOwnAndKeepCorrections() {
        var map = SkipMap(episode: .init(), audio: audio, segments: [segment(100, 200, .description), segment(300, 360, .model)])
        map.add(start: 1000, end: 1030, kind: .selfPromo)
        map.remove(map.effectiveSegments.first { $0.source == .model }!)
        let rerun = map.replacingSegments(from: .model, with: [segment(301, 359, .model), segment(2000, 2040, .model)])
        #expect(rerun.corrections == map.corrections)
        #expect(rerun.segments.filter { $0.source == .description }.count == 1)
        // Odrzucenie przetrwało ponowną analizę (inne granice), nowy segment jest.
        #expect(rerun.effectiveSegments.map(\.start) == [100, 1000, 2000])
    }

    @Test func detectionRerunKeepsModelOnlyForSameFile() {
        let previous = SkipMap(episode: .init(), audio: audio, segments: [segment(300, 360, .model)], runs: [SkipRun(source: .model, detail: "13b.1 · m")])
        let result = SkipDetection.Result(segments: [], insertedAds: nil, notices: [], runs: [SkipRun(source: .description)])
        let same = SkipDetection.map(result: result, episode: .init(), audio: audio, previous: previous)
        #expect(same.segments.map(\.source) == [.model])
        #expect(same.modelRun?.detail == "13b.1 · m")
        var other = audio
        other.size = 2000
        let replaced = SkipDetection.map(result: result, episode: .init(), audio: other, previous: previous)
        #expect(replaced.segments.isEmpty)
        #expect(replaced.modelRun == nil)
    }

    @Test func planShowsLowConfidenceModelSegments() {
        let map = SkipMap(episode: .init(), audio: audio, segments: [segment(100, 160, .model), segment(500, 510, .model, autoSkip: false)])
        let plan = SkipPlan(map: map, actual: audio, settings: .standard)
        #expect(plan.entries.map(\.action) == [.skip, .show])
        #expect(plan.decide(from: 99.8, to: 100.3, suppressed: [])?.target == 160)
    }
}

@Suite(.serialized) struct SkipPreferenceTests {
    @Test func podcastInheritsCategoryDefaultsUnlessOverridden() throws {
        let suite = "skip-pref-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = SkipSettingsStore(suiteName: suite)
        #expect(store.settings(podcastID: "p") == .standard)
        store.setCategoryDefaults(SkipSettings(sponsor: .show, selfPromo: .ignore))
        #expect(store.settings(podcastID: "p") == SkipSettings(sponsor: .show, selfPromo: .ignore))
        // Jawny wybór „pomijaj” przy domyślnym „pokaż” zostaje (nie znika jako równy `.standard`).
        store.setPreference(SkipPreference(sponsor: .skip), podcastID: "p")
        #expect(store.settings(podcastID: "p") == SkipSettings(sponsor: .skip, selfPromo: .ignore))
        store.setCategoryDefaults(.standard)
        #expect(store.settings(podcastID: "p") == SkipSettings(sponsor: .skip, selfPromo: .skip))
        #expect(store.preference(podcastID: "p") == SkipPreference(sponsor: .skip))
        store.setPreference(.inherit, podcastID: "p")
        #expect(UserDefaults(suiteName: suite)?.data(forKey: SkipSettingsStore.prefix + "p") == nil)
        // Wyłączenie w podcaście wygrywa z domyślnymi.
        store.setPreference(SkipPreference(enabled: false), podcastID: "q")
        #expect(store.settings(podcastID: "q").action(for: .sponsor) == .ignore)
    }

    @Test func storedSettingsFrom13aReadAsExplicitChoice() throws {
        let suite = "skip-pref-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let old = try JSONEncoder().encode(SkipSettings(enabled: true, sponsor: .skip, selfPromo: .show))
        UserDefaults(suiteName: suite)?.set(old, forKey: SkipSettingsStore.prefix + "p")
        let store = SkipSettingsStore(suiteName: suite)
        store.setCategoryDefaults(SkipSettings(sponsor: .ignore, selfPromo: .ignore))
        #expect(store.settings(podcastID: "p") == SkipSettings(sponsor: .skip, selfPromo: .show))
    }
}
