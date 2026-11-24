// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 11d).

import AudiobookshelfKit
import CoreGraphics
import CoreText
import Foundation

/// Wygląd tekstu książki (ten sam co w etapie 11b): kroje, rozmiar, odstępy, kolumna.
/// Kroje podaje aplikacja (szeryfowy „New York” albo systemowy — przez deskryptor platformy).
public struct TextFlowStyle {
    public var body: CTFont
    public var heading1: CTFont
    public var heading: CTFont
    public var quote: CTFont
    public var preformatted: CTFont
    /// Podstawowy rozmiar (od niego odstępy, jak w widoku SwiftUI z 11b).
    public var size: CGFloat
    /// Najszersza kolumna tekstu i margines po bokach.
    public var columnWidth: CGFloat
    public var horizontalPadding: CGFloat
    /// Język składu (łamanie wierszy).
    public var language: String
    /// Klucz zmian wyglądu: inny klucz — układ od nowa.
    public var key: String

    public init(body: CTFont, heading1: CTFont, heading: CTFont, quote: CTFont, preformatted: CTFont, size: CGFloat, columnWidth: CGFloat, horizontalPadding: CGFloat, language: String, key: String) {
        self.body = body; self.heading1 = heading1; self.heading = heading; self.quote = quote; self.preformatted = preformatted
        self.size = size; self.columnWidth = columnWidth; self.horizontalPadding = horizontalPadding
        self.language = language; self.key = key
    }

    func font(for kind: TextSyncDocument.Paragraph.Kind) -> CTFont {
        switch kind {
        case .heading(1): heading1
        case .heading: heading
        case .quote: quote
        case .preformatted: preformatted
        case .body, .listItem: body
        }
    }

    func lineSpacing(for kind: TextSyncDocument.Paragraph.Kind) -> CGFloat {
        if case .heading = kind { size * 0.2 } else { size * 0.42 }
    }

    func indent(for kind: TextSyncDocument.Paragraph.Kind) -> CGFloat {
        switch kind {
        case .quote, .listItem: size
        default: 0
        }
    }

    /// Odstęp między akapitami.
    var paragraphSpacing: CGFloat { size * 0.85 }
    /// Przerwa przed nowym plikiem rozdziału (trzy kropki).
    var sectionBreakHeight: CGFloat { size * 2.8 + 4 }
}

/// Ułożony akapit: wiersze z położeniem (względem góry akapitu) i zdaniami w każdym wierszu.
public final class ParagraphLayout: @unchecked Sendable {
    public struct Run {
        public let sentence: Int
        public let run: CTRun
        /// Liczba znaków zdania w tym kawałku i jego zasięg poziomy (współrzędne wiersza).
        public let characters: Int
        public let minX: CGFloat
        public let maxX: CGFloat
    }

    public struct Line {
        /// `nil` — przerwa rozdziału (trzy kropki).
        public let line: CTLine?
        public let top: CGFloat
        public let height: CGFloat
        public let ascent: CGFloat
        public let x: CGFloat
        public let width: CGFloat
        public let runs: [Run]
        public var baseline: CGFloat { top + ascent }
    }

    public let lines: [Line]
    public let height: CGFloat
    /// Pierwsze i ostatnie zdanie akapitu w każdym wierszu (szybkie szukanie wierszy zdania).
    let sentenceLines: [Int: [Int]]

    init(lines: [Line], height: CGFloat) {
        self.lines = lines
        self.height = height
        var map: [Int: [Int]] = [:]
        for (index, line) in lines.enumerated() {
            for run in line.runs where map[run.sentence]?.last != index { map[run.sentence, default: []].append(index) }
        }
        sentenceLines = map
    }
}

/// Układ całej książki w jednej kolumnie: dokładny (CoreText) dla akapitów, które były
/// potrzebne, szacowany dla reszty. Szacunek zamienia się w dokładną wysokość, zanim akapit
/// pojawi się na ekranie; różnicę nad bieżącym miejscem właściciel przewijania kompensuje
/// w tej samej klatce, więc treść na ekranie nigdy nie skacze. Nie ma „okna” akapitów —
/// przewijać można przez całą książkę, a pamięć zależy tylko od ułożonych akapitów.
public final class TextFlowLayout {
    public let document: TextSyncDocument
    public let style: TextFlowStyle
    public let width: CGFloat
    /// Wolne miejsce nad pierwszym i pod ostatnim akapitem (linia czytania na początku i końcu).
    public let topInset: CGFloat
    public let bottomInset: CGFloat

    private var layouts: [ParagraphLayout?]
    private var heights: [CGFloat]
    /// Góry akapitów (bez `topInset`); ważne do `validTops`.
    private var tops: [CGFloat]
    private var validTops = 0
    public private(set) var exactCount = 0
    /// Wysokość akapitu jest dokładna (skład mógł zostać potem zwolniony).
    private var exact: [Bool]
    /// Akapity z zachowanym składem (do zwalniania pamięci).
    private var cached = Set<Int>()

    /// Atrybut zdania w tekście akapitu.
    static let sentenceKey = NSAttributedString.Key("net.smigi.rapsod.sentence")

    public init(document: TextSyncDocument, style: TextFlowStyle, width: CGFloat, topInset: CGFloat, bottomInset: CGFloat) {
        self.document = document
        self.style = style
        self.width = width
        self.topInset = topInset
        self.bottomInset = bottomInset
        let count = document.paragraphs.count
        layouts = Array(repeating: nil, count: count)
        heights = Array(repeating: 0, count: count)
        tops = Array(repeating: 0, count: count + 1)
        exact = Array(repeating: false, count: count)
        for index in 0..<count { heights[index] = estimate(index) }
    }

    public var count: Int { heights.count }

    /// Szerokość kolumny i jej lewa krawędź.
    public var column: (x: CGFloat, width: CGFloat) {
        let w = max(40, min(style.columnWidth, width - 2 * style.horizontalPadding))
        return ((width - w) / 2, w)
    }

    public var contentHeight: CGFloat {
        top(of: count) + bottomInset
    }

    /// Góra akapitu we współrzędnych treści (z `topInset`); `index == count` — koniec tekstu.
    public func top(of index: Int) -> CGFloat {
        let index = min(max(0, index), count)
        // `tops[0...validTops]` są aktualne; dalsze liczone leniwie od pierwszej zmiany.
        if index > validTops {
            var y = tops[validTops]
            for k in validTops..<index {
                y += heights[k] + (k + 1 < count ? style.paragraphSpacing : 0)
                tops[k + 1] = y
            }
            validTops = index
        }
        return topInset + tops[index]
    }

    public func height(of index: Int) -> CGFloat { heights[index] }
    public func isExact(_ index: Int) -> Bool { exact[index] }

    /// Akapit pod punktem `y` (współrzędne treści).
    public func paragraph(atY y: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        var lo = 0, hi = count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if top(of: mid) <= y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Dokładny układ akapitu; zwraca zmianę wysokości (0, gdy był już ułożony).
    @discardableResult
    public func layout(_ index: Int) -> (ParagraphLayout, delta: CGFloat) {
        if let layout = layouts[index] { return (layout, 0) }
        let layout = make(index)
        layouts[index] = layout
        cached.insert(index)
        guard !exact[index] else { return (layout, 0) }
        exact[index] = true
        exactCount += 1
        let delta = layout.height - heights[index]
        if delta != 0 {
            heights[index] = layout.height
            validTops = min(validTops, index)
        }
        return (layout, delta)
    }

    /// Zwalnia składy akapitów poza `range` (wysokości zostają dokładne; skład wróci na żądanie).
    public func evict(keeping range: Range<Int>) {
        guard cached.count > range.count + 100 else { return }
        for index in cached where !range.contains(index) {
            layouts[index] = nil
            cached.remove(index)
        }
    }

    public func existingLayout(_ index: Int) -> ParagraphLayout? { layouts[index] }

    // MARK: - Zdania

    /// Wiersze zdania we współrzędnych treści z udziałem w długości zdania (do śledzenia lektora).
    public func lines(ofSentence sentence: Int) -> [FollowPlanner.Line] {
        guard let paragraph = document.paragraph(ofSentence: sentence) else { return [] }
        let layout = layout(paragraph).0
        let base = top(of: paragraph)
        var parts: [(top: CGFloat, height: CGFloat, chars: Int)] = []
        for index in layout.sentenceLines[sentence] ?? [] {
            let line = layout.lines[index]
            let chars = line.runs.filter { $0.sentence == sentence }.reduce(0) { $0 + $1.characters }
            parts.append((base + line.top, line.height, chars))
        }
        let total = Double(max(1, parts.reduce(0) { $0 + $1.chars }))
        var done = 0
        return parts.map { part in
            defer { done += part.chars }
            return FollowPlanner.Line(top: part.top, height: part.height, from: Double(done) / total, to: Double(done + part.chars) / total)
        }
    }

    /// Prostokąty zdania (po jednym na wiersz) we współrzędnych treści — VoiceOver, podpowiedzi.
    public func frames(ofSentence sentence: Int) -> [CGRect] {
        guard let paragraph = document.paragraph(ofSentence: sentence), let layout = layouts[paragraph] else { return [] }
        let base = top(of: paragraph)
        return (layout.sentenceLines[sentence] ?? []).map { index in
            let line = layout.lines[index]
            let runs = line.runs.filter { $0.sentence == sentence }
            let minX = runs.map(\.minX).min() ?? 0, maxX = runs.map(\.maxX).max() ?? 0
            return CGRect(x: line.x + minX, y: base + line.top, width: maxX - minX, height: line.height)
        }
    }

    /// Zdanie pod punktem (współrzędne treści); między wierszami — najbliższe, jak w 11b.
    public func sentence(at point: CGPoint) -> Int? {
        let paragraph = paragraph(atY: point.y)
        var best: (distance: CGFloat, index: Int)?
        for candidate in max(0, paragraph - 1)...min(count - 1, paragraph + 1) {
            guard let layout = layouts[candidate] else { continue }
            let base = top(of: candidate)
            for line in layout.lines where line.line != nil {
                let minY = base + line.top, maxY = minY + line.height
                let dy = point.y < minY ? minY - point.y : max(0, point.y - maxY)
                for run in line.runs {
                    let minX = line.x + run.minX, maxX = line.x + run.maxX
                    let dx = point.x < minX ? minX - point.x : max(0, point.x - maxX)
                    let distance = dy * 3 + dx
                    if best == nil || distance < best!.distance { best = (distance, run.sentence) }
                }
            }
        }
        return best.flatMap { $0.distance < 60 ? $0.index : nil }
    }

    // MARK: - Skład

    private func estimate(_ index: Int) -> CGFloat {
        let paragraph = document.paragraphs[index]
        var characters = 0
        for sentence in paragraph.sentences { characters += document.map.sentences[sentence].text.count + 1 }
        let font = style.font(for: paragraph.kind)
        let size = CTFontGetSize(font)
        let textWidth = max(40, column.width - style.indent(for: paragraph.kind))
        let perLine = max(8, Double(textWidth / (size * 0.5)))
        let lines = max(1, (Double(characters) / perLine).rounded(.up))
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        return CGFloat(lines) * lineHeight + CGFloat(lines - 1) * style.lineSpacing(for: paragraph.kind) + extras(paragraph)
    }

    private func extras(_ paragraph: TextSyncDocument.Paragraph) -> CGFloat {
        var extra: CGFloat = paragraph.startsSection ? style.sectionBreakHeight : 0
        if paragraph.isHeading { extra += style.size * 0.9 }
        return extra
    }

    private func make(_ index: Int) -> ParagraphLayout {
        let paragraph = document.paragraphs[index]
        let font = style.font(for: paragraph.kind)
        let indent = style.indent(for: paragraph.kind)
        let textWidth = Double(max(40, column.width - indent))
        let string = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            NSAttributedString.Key(kCTLanguageAttributeName as String): style.language,
        ]
        for sentence in paragraph.sentences {
            if sentence != paragraph.sentences.lowerBound { string.append(NSAttributedString(string: " ", attributes: base)) }
            var attributes = base
            attributes[Self.sentenceKey] = sentence
            string.append(NSAttributedString(string: document.displayText(ofSentence: sentence), attributes: attributes))
        }

        var lines: [ParagraphLayout.Line] = []
        var y: CGFloat = 0
        if paragraph.startsSection {
            lines.append(.init(line: nil, top: 0, height: style.sectionBreakHeight, ascent: 0, x: 0, width: column.width, runs: []))
            y = style.sectionBreakHeight
        }
        if paragraph.isHeading { y += style.size * 0.6 }
        let spacing = style.lineSpacing(for: paragraph.kind)
        let typesetter = CTTypesetterCreateWithAttributedString(string as CFAttributedString)
        let length = string.length
        var start = 0
        var first = true
        while start < length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, textWidth)
            guard count > 0 else { break }
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            if !first { y += spacing }
            first = false
            var runs: [ParagraphLayout.Run] = []
            for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let sentence = attributes[Self.sentenceKey] as? Int else { continue }
                let range = CTRunGetStringRange(run)
                let minX = CTLineGetOffsetForStringIndex(line, range.location, nil)
                let maxX = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
                runs.append(.init(sentence: sentence, run: run, characters: range.length, minX: min(minX, maxX), maxX: max(minX, maxX)))
            }
            let height = ascent + descent + leading
            lines.append(.init(line: line, top: y, height: height, ascent: ascent + leading / 2, x: column.x + indent, width: width, runs: runs))
            y += height
            start += count
        }
        if paragraph.isHeading { y += style.size * 0.3 }
        return ParagraphLayout(lines: lines, height: y)
    }
}
