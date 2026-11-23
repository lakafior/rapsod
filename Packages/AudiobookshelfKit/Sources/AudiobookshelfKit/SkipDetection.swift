// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 13a). Parser nagłówka Megaphone napisany od zera
// z obserwacji odpowiedzi serwerów Megaphone (2026-11-23, przykłady w testach) — bez zaglądania
// do istniejących parserów (te są na AGPL/GPL).

import Foundation

/// Wykrywanie segmentów sponsorowanych bez modelu (etap 13a): czasy z opisu odcinka przy słowach
/// kluczowych, rozdziały, sloty reklam z nagłówka Megaphone i różnica długości pliku i kanału.
/// Czyste funkcje na gotowych danych — tę samą logikę wołają Mac (po pobraniu odcinka na serwer)
/// i iOS (odcinek grany prosto z kanału).
public enum SkipDetection {
    public struct Chapter: Sendable, Hashable {
        public var start: Double
        public var end: Double
        public var title: String

        public init(start: Double, end: Double, title: String) {
            self.start = start
            self.end = end
            self.title = title
        }
    }

    public struct Input: Sendable {
        /// Opis odcinka jako czysty tekst (z zachowanymi nowymi liniami).
        public var description: String?
        /// Rozdziały z pliku albo z kanału.
        public var chapters: [Chapter]
        /// `itunes:duration` z kanału.
        public var feedDuration: Double?
        /// Długość odtwarzanego/analizowanego pliku.
        public var fileDuration: Double
        /// Rozmiar pliku w bajtach, gdy znany (plik na dysku).
        public var fileSize: Int64?
        /// Nagłówek `x-megaphone-payload-2` i całkowity rozmiar z `Content-Range` tej samej odpowiedzi.
        public var megaphone: MegaphonePayload?
        public var megaphoneTotalSize: Int64?

        public init(description: String?, chapters: [Chapter] = [], feedDuration: Double? = nil, fileDuration: Double,
                    fileSize: Int64? = nil, megaphone: MegaphonePayload? = nil, megaphoneTotalSize: Int64? = nil) {
            self.description = description
            self.chapters = chapters
            self.feedDuration = feedDuration
            self.fileDuration = fileDuration
            self.fileSize = fileSize
            self.megaphone = megaphone
            self.megaphoneTotalSize = megaphoneTotalSize
        }
    }

    public struct Result: Sendable, Equatable {
        public var segments: [SkipSegment]
        public var insertedAds: InsertedAds?
        public var notices: [SkipNotice]
        public var runs: [SkipRun]
    }

    /// Wersja reguł (zapisywana w `runs`, żeby wiedzieć, kiedy warto liczyć od nowa).
    public static let rulesVersion = "13a.1"
    /// Dłuższy segment z opisu albo rozdziałów to raczej cały temat niż reklama — tylko znacznik.
    public static let longSegment: Double = 300
    /// Ile sekund nadwyżki pliku nad `itunes:duration` uznajemy za wstawione reklamy.
    public static func insertionThreshold(feedDuration: Double) -> Double { max(20, feedDuration * 0.02) }

    public static func analyze(_ input: Input, now: Date = .now) -> Result {
        var runs: [SkipRun] = []
        var segments: [SkipSegment] = []
        var notices: [SkipNotice] = []
        var inserted: InsertedAds?

        // 1. Megaphone: sloty z położeniem, gdy nagłówek opisuje dokładnie ten plik.
        var breaks: [MegaphonePayload.Break] = []
        if let payload = input.megaphone {
            runs.append(SkipRun(source: .megaphone, date: now, detail: rulesVersion))
            let filled = payload.breaks
            if !filled.isEmpty {
                let seconds = filled.reduce(0) { $0 + $1.duration }
                if payload.describes(totalSize: input.megaphoneTotalSize, fileSize: input.fileSize, fileDuration: input.fileDuration) {
                    breaks = filled
                    for item in filled {
                        segments.append(SkipSegment(start: item.start, end: min(item.end, input.fileDuration), kind: .sponsor, source: .megaphone,
                                                    confidence: 0.95, label: item.label))
                    }
                    inserted = InsertedAds(source: .megaphone, seconds: seconds, slots: payload.filledSlotCount, located: true)
                } else {
                    inserted = InsertedAds(source: .megaphone, seconds: nil, slots: payload.filledSlotCount, located: false,
                                           note: "Nagłówek opisuje inną wersję pliku niż ta na dysku — położenie reklam nieznane.")
                }
            }
        }

        // 2. Różnica długości kanału i pliku.
        if let feed = input.feedDuration, feed > 0 {
            runs.append(SkipRun(source: .durationDifference, date: now, detail: rulesVersion))
            let extra = input.fileDuration - feed
            if inserted == nil, extra > insertionThreshold(feedDuration: feed) {
                inserted = InsertedAds(source: .durationDifference, seconds: extra, located: false)
            }
        }

        // Czasy z opisu i rozdziałów z kanału są na osi wydawcy (bez wstawionych reklam).
        let located = inserted?.located ?? true
        let shift: (Double) -> Double = { time in
            time + breaks.filter { $0.contentPosition <= time + 0.01 }.reduce(0) { $0 + $1.duration }
        }

        // 3. Rozdziały.
        var chapterSegments: [SkipSegment] = []
        if !input.chapters.isEmpty {
            runs.append(SkipRun(source: .chapters, date: now, detail: rulesVersion))
            for chapter in input.chapters {
                guard let kind = SponsorKeywords.kind(of: chapter.title), chapter.end - chapter.start >= 3 else { continue }
                chapterSegments.append(SkipSegment(start: chapter.start, end: min(chapter.end, input.fileDuration), kind: kind, source: .chapters,
                                                   confidence: 0.9, label: chapter.title,
                                                   autoSkip: chapter.end - chapter.start <= longSegment))
            }
        }

        // 4. Opis.
        var descriptionSegments: [SkipSegment] = []
        if let text = input.description, !text.isEmpty {
            runs.append(SkipRun(source: .description, date: now, detail: rulesVersion))
            let found = DescriptionMarkers.find(in: text, duration: input.feedDuration ?? input.fileDuration)
            for marker in found.ranges {
                let start = shift(marker.start)
                let end = min(shift(marker.end - 0.01) + 0.01, input.fileDuration)
                guard end - start >= 3, start < input.fileDuration else { continue }
                descriptionSegments.append(SkipSegment(start: start, end: end, kind: marker.kind, source: .description,
                                                       confidence: located ? 0.85 : 0.5, label: marker.text,
                                                       autoSkip: located && marker.end - marker.start <= longSegment))
            }
            notices += found.notices
        }
        // Opis zwykle powtarza rozdziały kanału — zostają rozdziały (mają jawny koniec).
        descriptionSegments.removeAll { d in chapterSegments.contains { overlap($0, d) >= 0.5 * min($0.duration, d.duration) } }
        segments += chapterSegments + descriptionSegments
        segments.sort { $0.start < $1.start }
        return Result(segments: segments, insertedAds: inserted, notices: notices, runs: runs)
    }

    static func overlap(_ a: SkipSegment, _ b: SkipSegment) -> Double {
        max(0, min(a.end, b.end) - max(a.start, b.start))
    }

    /// Nowa mapa z wyniku wykrywania; z poprzedniej wersji przechodzą poprawki użytkownika i segmenty
    /// źródeł, które tym razem nie liczyły (np. model z 13b).
    public static func map(result: Result, episode: SkipMap.EpisodeRef, audio: SkipAudioFingerprint, previous: SkipMap?, now: Date = .now) -> SkipMap {
        let fresh = SkipMap(episode: episode, audio: audio, segments: result.segments, insertedAds: result.insertedAds,
                            notices: result.notices, runs: result.runs, generatedAt: now)
        guard let previous else { return fresh }
        let ranNow: Set<SkipSource> = Set(result.runs.map(\.source))
        let keep = Set(previous.segments.map(\.source)).union(previous.runs.map(\.source)).subtracting(ranNow)
        return fresh.carryingOver(from: previous, keeping: keep)
    }
}

// MARK: - Słowa kluczowe

/// Słowa, po których rozpoznajemy fragment sponsorowany w opisie albo tytule rozdziału (PL i EN).
public enum SponsorKeywords {
    /// Autopromocja: własne produkty i zbiórki prowadzącego.
    static let selfPromo: [String] = [
        #"\bautopromocj"#, #"\bautopromo\b"#, #"\bself[- ]?promo"#, #"\bpromocja własna\b"#,
    ]
    /// Reklama i sponsor (czytane przez prowadzącego albo wstawiane).
    static let sponsor: [String] = [
        #"\bsponsor"#, #"\breklam"#, #"\bpartner(em|a|zy|ów|ami|s)?\b"#, #"\bbrought to you by\b"#,
        #"\bmateriał sponsorowany\b"#, #"\bwspółprac[aąy] reklamow"#, #"\blokowanie produktu\b"#,
        #"\badvertis"#, #"\bad[- ]?break\b"#, #"\bthis episode is supported by\b"#, #"\bsupported by\b"#,
        #"\bpaid promotion\b"#, #"\bcommercial break\b"#,
    ]
    /// Krótkie wpisy typu „Ad” / „Ads” (dłuższe zdanie z „ad” to zwykle temat).
    static let shortSponsor: [String] = [#"^\W*ads?\W*$"#, #"^\W*(mid|pre|post)[- ]?roll\W*$"#]

    private static func matches(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// Rodzaj fragmentu według tekstu albo `nil`, gdy to nie fragment sponsorowany.
    public static func kind(of text: String) -> SkipKind? {
        let lower = text.lowercased()
        if matches(lower, selfPromo) { return .selfPromo }
        if matches(lower, sponsor) { return .sponsor }
        if lower.count <= 24, matches(lower, shortSponsor) { return .sponsor }
        return nil
    }
}

// MARK: - Opis odcinka

/// Znaczniki czasu w opisie odcinka („1:45 – [autopromocja] Akta tajemnic”, „03:36 Brought to you by…”).
public enum DescriptionMarkers {
    public struct Marker: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var kind: SkipKind
        public var text: String
    }

    public struct Found: Sendable, Equatable {
        public var ranges: [Marker]
        public var notices: [SkipNotice]
    }

    struct Stamp {
        var time: Double
        var range: Range<String.Index>
        /// Jawny koniec („1:45–3:45”).
        var end: Double?
        var endRange: Range<String.Index>?
    }

    private static let stampPattern = #"(?<![\d:.,])(\d{1,3})(?::(\d{2}))?:(\d{2})(?![\d:]|\.\d)"#

    /// Czas z tekstu `h:mm:ss` albo `m:ss` (minuty mogą przekraczać 59).
    static func seconds(_ match: Substring) -> Double? {
        let parts = match.split(separator: ":").map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap { $0 }
        switch values.count {
        case 2:
            guard values[1] < 60 else { return nil }
            return Double(values[0] * 60 + values[1])
        case 3:
            guard values[1] < 60, values[2] < 60 else { return nil }
            return Double(values[0] * 3600 + values[1] * 60 + values[2])
        default: return nil
        }
    }

    static func stamps(in text: String) -> [Stamp] {
        guard let regex = try? NSRegularExpression(pattern: stampPattern) else { return [] }
        let ns = text as NSString
        var result: [Stamp] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(match.range, in: text), let time = seconds(text[range]) else { continue }
            result.append(Stamp(time: time, range: range))
        }
        // „1:45 – 3:45”: drugi czas tuż po pierwszym (tylko myślnik i spacje) to koniec zakresu.
        var merged: [Stamp] = []
        var index = 0
        while index < result.count {
            var stamp = result[index]
            if index + 1 < result.count {
                let between = text[stamp.range.upperBound..<result[index + 1].range.lowerBound]
                let separator = between.trimmingCharacters(in: .whitespaces)
                if ["-", "–", "—", "do", "to"].contains(separator), result[index + 1].time > stamp.time {
                    stamp.end = result[index + 1].time
                    stamp.endRange = result[index + 1].range
                    index += 1
                }
            }
            merged.append(stamp)
            index += 1
        }
        return merged
    }

    public static func find(in text: String, duration: Double) -> Found {
        let stamps = stamps(in: text).filter { $0.time <= duration + 5 }
        var ranges: [Marker] = []
        var notices: [SkipNotice] = []
        var coveredLines: [Range<String.Index>] = []

        for (index, stamp) in stamps.enumerated() {
            // Tekst wpisu: od czasu do następnego czasu albo końca wiersza; plus tekst przed czasem
            // w tym samym wierszu (format „[autopromocja] 1:45”).
            let after = stamp.endRange?.upperBound ?? stamp.range.upperBound
            let nextStart = index + 1 < stamps.count ? stamps[index + 1].range.lowerBound : text.endIndex
            let lineEnd = text[after...].firstIndex(where: \.isNewline) ?? text.endIndex
            let entryEnd = min(nextStart, lineEnd)
            let lineStart = text[..<stamp.range.lowerBound].lastIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.startIndex
            let previousEnd = index > 0 ? (stamps[index - 1].endRange?.upperBound ?? stamps[index - 1].range.upperBound) : text.startIndex
            let entryStart = max(lineStart, previousEnd)
            let before = String(text[entryStart..<stamp.range.lowerBound])
            let entry = String(text[after..<entryEnd])
            let label = clean(before + " " + String(text[stamp.range.lowerBound..<after]) + entry)
            // Tekst przed czasem liczy się tylko w krótkim prefiksie (nie cały poprzedni akapit).
            let keyText = (before.count <= 40 ? before + " " : "") + entry
            guard let kind = SponsorKeywords.kind(of: keyText) else { continue }
            coveredLines.append(lineStart..<lineEnd)
            // Koniec: jawny zakres albo następny czas w opisie (większy od początku).
            let end = stamp.end ?? stamps[(index + 1)...].first(where: { $0.time > stamp.time })?.time
            if let end {
                ranges.append(Marker(start: stamp.time, end: min(end, duration), kind: kind, text: label))
            } else {
                notices.append(SkipNotice(kind: kind, source: .description, text: label, time: stamp.time))
            }
        }

        // Wzmianki bez czasu („[autopromocja] …” na początku, „Partnerem odcinka jest …”): po jednej na rodzaj.
        var seenKinds: Set<SkipKind> = Set(ranges.map(\.kind))
        for line in text.split(whereSeparator: \.isNewline) {
            let lineRange = line.startIndex..<line.endIndex
            guard !coveredLines.contains(where: { $0.overlaps(lineRange) }),
                  let kind = SponsorKeywords.kind(of: String(line)), !seenKinds.contains(kind) else { continue }
            seenKinds.insert(kind)
            notices.append(SkipNotice(kind: kind, source: .description, text: clean(sentence(around: String(line), kind: kind))))
        }
        return Found(ranges: ranges, notices: notices)
    }

    /// Zdanie z wzmianką (opis bywa jednym długim akapitem).
    private static func sentence(around line: String, kind: SkipKind) -> String {
        let sentences = line.split(omittingEmptySubsequences: true) { ".!?\u{2026}".contains($0) }.map(String.init)
        return sentences.first { SponsorKeywords.kind(of: $0) == kind } ?? line
    }

    private static func clean(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "•-–—|")))
        return collapsed.count > 160 ? String(collapsed.prefix(159)) + "…" : collapsed
    }
}

// MARK: - Megaphone

/// Nagłówek `x-megaphone-payload-2` z odpowiedzi serwerów Megaphone (Spotify) — opis slotów reklam
/// wstawianych dynamicznie w tej konkretnej odpowiedzi. Format nieudokumentowany; odczytany z obserwacji:
///
///     <slot>,<slot>,…@<id odcinka>#<bitrate b/s>#<bajt początku audio>
///     slot: <id reklamy>#<ostatni bajt>#<pre|mid|post>#<numer>#<pierwszy bajt>#<id kreacji>#…
///
/// Pusty slot ma puste id i „ostatni bajt” o jeden mniejszy od pierwszego (punkt wstawienia bez reklamy).
/// Odcinek bez punktów wstawienia ma sam człon po `@`. Bajty liczone są w zszytym pliku, a czas
/// z bajtu — przy stałym bitrate: `(bajt − początek audio) × 8 / bitrate`.
public struct MegaphonePayload: Sendable, Equatable {
    public static let headerName = "x-megaphone-payload-2"

    public struct Slot: Sendable, Equatable {
        public enum Position: String, Sendable { case pre, mid, post }
        public var adID: String?
        public var position: Position
        public var number: Int
        public var firstByte: Int64
        public var lastByte: Int64
        public var isFilled: Bool { lastByte >= firstByte && !(adID ?? "").isEmpty }
        public var byteCount: Int64 { max(0, lastByte - firstByte + 1) }
    }

    /// Ciągły blok reklam (sąsiednie wypełnione sloty) na osi pliku.
    public struct Break: Sendable, Equatable {
        public var position: Slot.Position
        public var start: Double
        public var end: Double
        /// Miejsce wstawienia na osi czasu bez reklam (do przeliczania czasów z opisu).
        public var contentPosition: Double
        public var duration: Double { end - start }

        public var label: String {
            switch position {
            case .pre: "Reklama wstawiona przed odcinkiem"
            case .mid: "Reklama wstawiona w trakcie odcinka"
            case .post: "Reklama wstawiona po odcinku"
            }
        }
    }

    public var slots: [Slot]
    public var bitrate: Int
    public var audioStart: Int64

    public static func parse(_ header: String) -> MegaphonePayload? {
        let text = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = text.lastIndex(of: "@") else { return nil }
        let trailer = text[text.index(after: at)...].split(separator: "#", omittingEmptySubsequences: false)
        guard trailer.count >= 3, let bitrate = Int(trailer[1]), bitrate > 0, let audioStart = Int64(trailer[2]), audioStart >= 0 else { return nil }
        var slots: [Slot] = []
        let body = text[..<at]
        if !body.isEmpty {
            for entry in body.split(separator: ",") {
                let fields = entry.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 5, let last = Int64(fields[1]), let position = Slot.Position(rawValue: fields[2].lowercased()),
                      let number = Int(fields[3]), let first = Int64(fields[4]) else { return nil }
                slots.append(Slot(adID: fields[0].isEmpty ? nil : fields[0], position: position, number: number, firstByte: first, lastByte: last))
            }
        }
        return MegaphonePayload(slots: slots, bitrate: bitrate, audioStart: audioStart)
    }

    public func time(ofByte byte: Int64) -> Double {
        Double(max(0, byte - audioStart)) * 8 / Double(bitrate)
    }

    /// Długość pliku o tym rozmiarze według bitrate z nagłówka.
    public func duration(totalSize: Int64) -> Double { time(ofByte: totalSize) }

    public var filledSlotCount: Int { slots.filter(\.isFilled).count }

    /// Wypełnione sloty połączone w ciągłe bloki, w kolejności w pliku.
    public var breaks: [Break] {
        let filled = slots.filter(\.isFilled).sorted { $0.firstByte < $1.firstByte }
        var result: [Break] = []
        var inserted = 0.0
        for slot in filled {
            let start = time(ofByte: slot.firstByte)
            let end = time(ofByte: slot.lastByte + 1)
            if var last = result.last, last.position == slot.position, abs(last.end - start) < 0.05 {
                last.end = end
                result[result.count - 1] = last
            } else {
                result.append(Break(position: slot.position, start: start, end: end, contentPosition: start - inserted))
            }
            inserted += end - start
        }
        return result
    }

    /// Czy nagłówek opisuje właśnie ten plik: rozmiar z `Content-Range` równy plikowi na dysku
    /// (albo, bez rozmiaru pliku, długość z bitrate zgodna z długością odtwarzanego pliku) i stały bitrate.
    public func describes(totalSize: Int64?, fileSize: Int64?, fileDuration: Double) -> Bool {
        guard let totalSize, totalSize > audioStart else { return false }
        if let fileSize, fileSize != totalSize { return false }
        return abs(duration(totalSize: totalSize) - fileDuration) <= SkipAudioFingerprint.durationTolerance
    }

    /// Całkowity rozmiar z nagłówka `Content-Range: bytes 0-0/12345`.
    public static func totalSize(contentRange: String?) -> Int64? {
        guard let contentRange, let slash = contentRange.lastIndex(of: "/") else { return nil }
        return Int64(contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}
