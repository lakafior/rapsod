// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 13b). Pomysły (okna z zakładką, numerowane wiersze zamiast
// czasów w odpowiedzi modelu, docinanie do ciszy) za opisami projektów MinusPod i Podly z rozpoznania —
// bez ich kodu.

import Foundation

/// Klasyfikacja transkrypcji odcinka przez zdalny model (etap 13b): wiersze z czasami, okna z zakładką,
/// prompt, walidacja odpowiedzi, scalanie wyników z okien i docinanie granic do przerw w mowie.
/// Czyste funkcje — sieć jest w `SponsorAPIClient`, dźwięk (poziomy głośności) czyta Mac.
public enum SponsorClassification {
    /// Wersja promptu i reguł (zapisywana w `SkipRun.detail` obok nazwy modelu).
    public static let version = "13b.2"

    // MARK: - Wiersze

    /// Wiersz transkrypcji wysyłany do modelu: kilka sekund mowy między przerwami.
    public struct Line: Codable, Sendable, Hashable {
        /// Numer w całym odcinku (od 0) — model odpowiada numerami, nie czasami.
        public var id: Int
        public var start: Double
        public var end: Double
        public var text: String

        public init(id: Int, start: Double, end: Double, text: String) {
            self.id = id
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// Wiersze ze słów: koniec przy przerwie ≥ `pause`, przy kropce po co najmniej `sentence` sekundach
    /// albo po `maxDuration`. Krótsze wiersze to dokładniejsze granice (rozpoznanie: wiersze do 20 s
    /// dawały błędy granic 8–19 s), ale więcej numerów w zapytaniu.
    public static func lines(from words: [TextSync.Word], maxDuration: Double = 12, pause: Double = 0.7, sentence: Double = 4) -> [Line] {
        var lines: [Line] = []
        var current: [TextSync.Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            lines.append(Line(id: lines.count, start: first.start, end: last.end, text: current.map(\.text).joined(separator: " ")))
            current = []
        }
        for word in words where !word.text.isEmpty && word.end >= word.start {
            if let first = current.first, let last = current.last {
                let gap = word.start - last.end
                let length = last.end - first.start
                let endsSentence = last.text.last.map { ".?!…".contains($0) } ?? false
                if gap >= pause || (endsSentence && length >= sentence) || word.end - first.start > maxDuration { flush() }
            }
            current.append(word)
        }
        flush()
        return lines
    }

    // MARK: - Okna

    public struct Window: Sendable, Hashable {
        public var index: Int
        public var lines: [Line]
        public var start: Double { lines.first?.start ?? 0 }
        public var end: Double { lines.last?.end ?? 0 }
        public var ids: ClosedRange<Int> { (lines.first?.id ?? 0)...(lines.last?.id ?? 0) }
    }

    /// Okna po `length` sekund, każde zaczyna się `overlap` sekund przed końcem poprzedniego. Reklama
    /// krótsza niż zakładka mieści się w całości w co najmniej jednym oknie; dłuższa na granicy okien
    /// trafia w dwa i skleja się przy scalaniu. Bardzo długi odcinek to po prostu więcej okien.
    public static func windows(_ lines: [Line], length: Double = 600, overlap: Double = 120) -> [Window] {
        guard let first = lines.first, let last = lines.last else { return [] }
        let step = max(60, length - overlap)
        var windows: [Window] = []
        var from = first.start
        while from < last.end {
            let to = from + length
            let chunk = lines.filter { $0.end > from && $0.start < to }
            if !chunk.isEmpty, chunk.last?.id != windows.last?.lines.last?.id {
                windows.append(Window(index: windows.count, lines: chunk))
            }
            if to >= last.end { break }
            from += step
        }
        return windows
    }

    // MARK: - Prompt

    /// Instrukcja dla modelu: instrukcja z rozpoznania (Mistral Small: 7/10, 0 fałszywych obszarów), rozdzielona na
    /// dwie kategorie. Po angielsku z przykładami polskich i angielskich zwrotów — ten sam prompt dla obu języków.
    /// Pierwsza wersja 13b (segmenty z kategorią i pewnością, długa lista wyjątków) dawała z tym samym modelem
    /// 0/10 — model odpowiadał pustą listą w każdym oknie (ocena 2026-11-23, README).
    public static let systemPrompt = """
    You label podcast transcripts. A transcript fragment is given as lines "ID [mm:ss] text" (Polish or English, from speech \
    recognition with errors). Return the IDs of every line that is part of a sponsored segment, in two lists:
    - "sponsor_line_ids": advertisements and sponsor reads: "this episode is sponsored by", "partnerem odcinka jest", brand \
    descriptions, offers, discount codes, URLs to buy something, calls to action to sign up or buy.
    - "selfpromo_line_ids": host self-promotion of their own products, books, courses, newsletters, paid community, Patronite \
    or Patreon.
    Include the whole block from first to last line. Do NOT include normal conversation, even if it mentions companies. \
    Answer ONLY with JSON: {"sponsor_line_ids": [..], "selfpromo_line_ids": [..]} (empty lists if none).
    """

    /// Wariant instrukcji z rozpoznania (2026-11-23, Mistral Small, cała transkrypcja: 7/10): lista numerów
    /// wierszy bez kategorii i pewności. Do porównania w `SkipEvaluation` — wynik bez kategorii to „sponsor”.
    public static let lineListPrompt = """
    You label podcast transcripts. A transcript fragment is given as lines "ID [mm:ss] text" (Polish or English, from speech \
    recognition with errors). Return the IDs of every line that is part of an advertisement or sponsor read: "this episode is \
    sponsored by", "partnerem odcinka jest", brand descriptions, offers, discount codes, URLs to buy something, calls to action \
    to sign up or buy, and host self-promotion of their own products, books, newsletters or paid community. Include the whole \
    ad block from first to last line. Do NOT include normal conversation, even if it mentions companies. Answer ONLY with JSON: \
    {"ad_line_ids": [..]} (empty list if none).
    """

    /// Treść zapytania dla okna: położenie okna w odcinku i wiersze „ID [mm:ss] tekst”.
    public static func userPrompt(_ window: Window, totalDuration: Double) -> String {
        var text = "Transcript fragment \(clock(window.start))–\(clock(window.end)) of a \(clock(totalDuration)) episode, lines \(window.ids.lowerBound)–\(window.ids.upperBound):\n"
        for line in window.lines {
            text += "\(line.id) [\(clock(line.start))] \(line.text)\n"
        }
        return text
    }

    /// Przypomnienie po odpowiedzi w złym formacie (jedna ponowna próba).
    public static let formatReminder = "Your previous answer was not valid. Answer ONLY with JSON in the form {\"sponsor_line_ids\": [..], \"selfpromo_line_ids\": [..]}, using line IDs from this fragment."

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: - Odpowiedź

    /// Jeden segment z odpowiedzi modelu dla okna.
    public struct Finding: Codable, Sendable, Hashable {
        public var first: Int
        public var last: Int
        public var kind: SkipKind
        public var confidence: Double
        public var window: Int

        public init(first: Int, last: Int, kind: SkipKind, confidence: Double, window: Int) {
            self.first = first
            self.last = last
            self.kind = kind
            self.confidence = confidence
            self.window = window
        }
    }

    /// Pewność segmentu z listy numerów (model jej nie podaje) — powyżej progu automatycznego pomijania,
    /// więc o pomijaniu decyduje długość.
    public static let listConfidence = 0.7

    public struct InvalidResponse: Error, Sendable, Equatable {
        public var reason: String
    }

    /// Odpowiedź modelu → segmenty okna. Format ścisły: obiekt z tablicą `segments`; tekst dookoła JSON-a
    /// (np. blok ```json) jest tolerowany. Element z numerem spoza okna, nieznaną kategorią albo bez
    /// numerów jest pomijany (zwykle pojedyncza pomyłka modelu); brak tablicy albo nie-JSON to błąd formatu.
    public static func parse(_ content: String, window: Window) throws -> [Finding] {
        guard let open = content.firstIndex(of: "{"), let close = content.lastIndex(of: "}"), open < close,
              let object = try? JSONSerialization.jsonObject(with: Data(content[open...close].utf8)) as? [String: Any] else {
            throw InvalidResponse(reason: "to nie jest JSON")
        }
        // Listy numerów wierszy (prompt 13b.2; `ad_line_ids` — instrukcja z rozpoznania, bez kategorii):
        // kolejne numery to jeden segment. Model nie podaje pewności — stała `listConfidence`.
        let lists: [(String, SkipKind)] = [("sponsor_line_ids", .sponsor), ("selfpromo_line_ids", .selfPromo), ("ad_line_ids", .sponsor)]
        if lists.contains(where: { object[$0.0] != nil }) {
            var findings: [Finding] = []
            for (key, kind) in lists {
                guard let raw = object[key] else { continue }
                guard let ids = raw as? [Any] else { throw InvalidResponse(reason: "„\(key)” to nie lista") }
                var run: Finding?
                for id in Set(ids.compactMap(integer).filter { window.ids.contains($0) }).sorted() {
                    if var current = run, id == current.last + 1 { current.last = id; run = current; continue }
                    if let current = run { findings.append(current) }
                    run = Finding(first: id, last: id, kind: kind, confidence: listConfidence, window: window.index)
                }
                if let current = run { findings.append(current) }
            }
            return findings
        }
        guard let items = (object["segments"] ?? object["ad_segments"] ?? object["ads"]) as? [Any] else {
            throw InvalidResponse(reason: "brak tablicy „segments”")
        }
        var findings: [Finding] = []
        for case let item as [String: Any] in items {
            guard var first = integer(item["first"] ?? item["start_id"] ?? item["from"]) else { continue }
            var last = integer(item["last"] ?? item["end_id"] ?? item["to"]) ?? first
            if last < first { swap(&first, &last) }
            guard window.ids.contains(first), window.ids.contains(last) else { continue }
            guard let kind = category(item["category"] ?? item["kind"] ?? item["type"]) else { continue }
            let raw = number(item["confidence"]) ?? 0.5
            let confidence = raw > 1 && raw <= 100 ? raw / 100 : min(max(raw, 0), 1)
            findings.append(Finding(first: first, last: last, kind: kind, confidence: confidence, window: window.index))
        }
        return findings
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): n.intValue
        case let s as String: Int(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): n.doubleValue
        case let s as String: Double(s.replacingOccurrences(of: ",", with: "."))
        default: nil
        }
    }

    private static func category(_ value: Any?) -> SkipKind? {
        guard let raw = (value as? String)?.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "") else { return nil }
        switch raw {
        case "sponsor", "ad", "ads", "advert", "advertisement", "reklama", "sponsored": return .sponsor
        case "selfpromo", "selfpromotion", "autopromocja", "promo": return .selfPromo
        default: return nil
        }
    }

    // MARK: - Scalanie

    /// Segment po scaleniu okien, przed docięciem.
    public struct Candidate: Sendable, Hashable {
        public var start: Double
        public var end: Double
        public var kind: SkipKind
        public var confidence: Double
        /// Ile okien zgłosiło ten fragment (zakładka: dwa okna widzą to samo miejsce).
        public var windows: Int
        public var duration: Double { end - start }
    }

    /// Wyniki z okien → rozłączne zakresy czasu. Zgłoszenia tej samej kategorii, które nachodzą na siebie
    /// albo dzieli je mniej niż `gap` sekund, łączą się (blok reklam podzielony przez okno albo przez model
    /// na kilka spotów). Różne kategorie nachodzące w większości — wygrywa dłuższa; sąsiednie zostają osobno.
    public static func merge(_ findings: [Finding], lines: [Line], gap: Double = 4) -> [Candidate] {
        let byID = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var raw: [(Candidate, Set<Int>)] = findings.compactMap { finding in
            guard let a = byID[finding.first], let b = byID[finding.last], b.end > a.start else { return nil }
            return (Candidate(start: a.start, end: b.end, kind: finding.kind, confidence: finding.confidence, windows: 1), [finding.window])
        }
        raw.sort { ($0.0.start, $0.0.end) < ($1.0.start, $1.0.end) }
        var merged: [(Candidate, Set<Int>)] = []
        for (candidate, windows) in raw {
            guard var (last, lastWindows) = merged.last else { merged.append((candidate, windows)); continue }
            let overlap = min(last.end, candidate.end) - max(last.start, candidate.start)
            let sameKind = last.kind == candidate.kind
            if (sameKind && overlap >= -gap) || (!sameKind && overlap >= 0.5 * min(last.duration, candidate.duration)) {
                if !sameKind && candidate.duration > last.duration { last.kind = candidate.kind }
                last.end = max(last.end, candidate.end)
                last.confidence = max(last.confidence, candidate.confidence)
                lastWindows.formUnion(windows)
                last.windows = lastWindows.count
                merged[merged.count - 1] = (last, lastWindows)
            } else {
                merged.append((candidate, windows))
            }
        }
        return merged.map(\.0)
    }

    // MARK: - Granice

    /// Przerwa w mowie (cisza w nagraniu albo odstęp między słowami).
    public struct Pause: Sendable, Hashable {
        public var start: Double
        public var end: Double
        public var middle: Double { (start + end) / 2 }
        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    /// Odstępy między słowami dłuższe niż `minimum` sekund.
    public static func wordGaps(_ words: [TextSync.Word], minimum: Double = 0.25) -> [Pause] {
        zip(words, words.dropFirst()).compactMap { a, b in b.start - a.end >= minimum ? Pause(start: a.end, end: b.start) : nil }
    }

    /// Docięcie granic segmentu do przerwy w mowie. Granice wierszy to już granice słów (początek pierwszego,
    /// koniec ostatniego słowa), więc docięcie nie wchodzi w słowa: początek cofa się w przerwę tuż przed
    /// pierwszym słowem, koniec wydłuża w przerwę tuż po ostatnim — do jej środka, najwyżej o `pad` sekundy.
    /// Najpierw cisza w nagraniu (czasy słów z rozpoznawania mowy bywają przesunięte o ułamki sekundy), potem
    /// odstęp między słowami. Pomiar (README, 13b): szersze przyciąganie do najbliższej przerwy w promieniu
    /// kilku sekund pogarszało granice — przesuwało koniec w przerwę wewnątrz ostatniego zdania reklamy.
    public static func refine(_ candidate: Candidate, silences: [Pause], gaps: [Pause], duration: Double, pad: Double = 0.5) -> Candidate {
        var refined = candidate
        let tolerance = 0.4
        for pauses in [silences, gaps] {
            let before = pauses.filter { $0.start < candidate.start && abs($0.end - candidate.start) <= tolerance }
            if let best = before.min(by: { abs($0.end - candidate.start) < abs($1.end - candidate.start) }) {
                refined.start = min(candidate.start, max(best.middle, best.end - pad))
                break
            }
        }
        for pauses in [silences, gaps] {
            let after = pauses.filter { $0.end > candidate.end && abs($0.start - candidate.end) <= tolerance }
            if let best = after.min(by: { abs($0.start - candidate.end) < abs($1.start - candidate.end) }) {
                refined.end = max(candidate.end, min(best.middle, best.start + pad))
                break
            }
        }
        refined.start = max(0, refined.start)
        if duration > 0 { refined.end = min(duration, refined.end) }
        return refined
    }

    // MARK: - Cisza

    /// Fragmenty ciszy w poziomach głośności (dBFS na ramkę). Próg względny: między tłem a typową
    /// mową w tym fragmencie, bo nagrania różnią się głośnością; najwyżej `maxThreshold`.
    public static func silences(levels: [Float], frameDuration: Double, startTime: Double,
                                minimumLength: Double = 0.15, maxThreshold: Float = -30) -> [Pause] {
        guard levels.count > 4 else { return [] }
        let sorted = levels.sorted()
        let floor = sorted[sorted.count / 10]
        let speech = sorted[sorted.count * 3 / 4]
        guard speech - floor >= 10 else { return [] }   // bez wyraźnej różnicy (muzyka, szum) — nic
        let threshold = min(maxThreshold, floor + (speech - floor) * 0.35)
        var pauses: [Pause] = []
        var runStart: Int?
        func appendRun(_ from: Int, _ to: Int) {
            let length = Double(to - from) * frameDuration
            if length >= minimumLength {
                pauses.append(Pause(start: startTime + Double(from) * frameDuration, end: startTime + Double(to) * frameDuration))
            }
        }
        for (index, level) in levels.enumerated() {
            if level <= threshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                appendRun(start, index)
                runStart = nil
            }
        }
        if let start = runStart { appendRun(start, levels.count) }
        return pauses
    }

    // MARK: - Segmenty

    /// Kiedy segment z modelu pomija się sam (reszta to znacznik z przyciskiem „Pomiń”).
    public struct AutoSkipPolicy: Sendable, Equatable {
        /// Próg pewności zgłoszonej przez model. Tymczasowy: zapisane odpowiedzi z rozpoznania nie mają
        /// pewności, więc progu nie dało się zmierzyć — `SkipEvaluation` z kluczem pokazuje rozkład.
        public var minimumConfidence: Double
        /// Najkrótszy segment pomijany automatycznie. Zmierzone na zapisanych odpowiedziach modelu
        /// (rozpoznanie): oba fałszywe obszary miały 5 i 13 s, trafienia 19 s i więcej (README, 13b).
        public var minimumDuration: Double

        public init(minimumConfidence: Double = 0.6, minimumDuration: Double = 15) {
            self.minimumConfidence = minimumConfidence
            self.minimumDuration = minimumDuration
        }

        public static let standard = AutoSkipPolicy()

        public func autoSkip(_ candidate: Candidate) -> Bool {
            candidate.confidence >= minimumConfidence && candidate.duration >= minimumDuration
        }
    }

    /// Wynik → segmenty `.model` do `SkipMap.replacingSegments(from: .model, …)`.
    public static func segments(_ candidates: [Candidate], policy: AutoSkipPolicy = .standard, model: String) -> [SkipSegment] {
        candidates.map { candidate in
            SkipSegment(id: "model-\(Int(candidate.start.rounded()))-\(candidate.kind.rawValue)",
                        start: (candidate.start * 100).rounded() / 100, end: (candidate.end * 100).rounded() / 100,
                        kind: candidate.kind, source: .model, confidence: (candidate.confidence * 100).rounded() / 100,
                        label: model, autoSkip: policy.autoSkip(candidate))
        }
    }
}
