// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Tekst e-booka zsynchronizowany z nagraniem (etap 11): zdania z EPUB-a z czasem w audiobooku.
///
/// Mapa leży w folderze pozycji obok audio jako `<nazwa e-booka>.sync.json`. Serwer bierze
/// pliki `.json` jako pliki metadanych pozycji (czyta wyłącznie `metadata.json`), więc mapa
/// trafia do `libraryFiles` i każde konto z dostępem do pozycji pobierze ją przez
/// `GET /api/items/:id/file/:ino`. Plik o nieznanym rozszerzeniu skaner by pominął.
public struct TextSyncMap: Codable, Sendable, Hashable {
    /// 1 — etap 11a; 2 — etap 11b: rodzaje bloków (`blocks`) do wyświetlania tekstu w odtwarzaczu.
    /// Mapy w starszej wersji czyta się dalej (brakujące pola są opcjonalne).
    public static let currentVersion = 2
    /// Końcówka nazwy pliku mapy.
    public static let fileSuffix = ".sync.json"

    public static func fileName(forEbook filename: String) -> String {
        ((filename as NSString).deletingPathExtension) + fileSuffix
    }

    public struct FileFingerprint: Codable, Sendable, Hashable {
        public var ino: String?
        public var filename: String?
        public var size: Double?
        public init(ino: String?, filename: String?, size: Double?) {
            self.ino = ino; self.filename = filename; self.size = size
        }
    }

    public struct Stats: Codable, Sendable, Hashable {
        /// Słowa książki (po normalizacji) i ile z nich znalazło swoje miejsce w nagraniu.
        public var bookWords: Int
        public var matchedWords: Int
        public var transcribedWords: Int
        public var sentences: Int
        /// Zdania z czasem z dopasowanych słów, z interpolacji i bez czasu (lektor ich nie czyta:
        /// przypisy, strona redakcyjna, opis z calibre…).
        public var direct: Int
        public var interpolated: Int
        public var untimed: Int

        public var timedFraction: Double { sentences == 0 ? 0 : Double(direct + interpolated) / Double(sentences) }
        public var matchedFraction: Double { bookWords == 0 ? 0 : Double(matchedWords) / Double(bookWords) }
    }

    public struct Sentence: Codable, Sendable, Hashable {
        /// Plik rozdziału w EPUB-ie (ścieżka w archiwum) i numer bloku tekstu (akapit, nagłówek…)
        /// w kolejności dokumentu.
        public var href: String
        public var block: Int
        /// Położenie zdania w tekście bloku (jednostki UTF-16, białe znaki zwinięte do spacji) —
        /// wskazówka do przeliczenia na CFI; rozstrzyga `text`.
        public var offset: Int
        public var length: Int
        public var text: String
        /// Czas w całej książce (sekundy); `nil` — zdania nie ma w nagraniu.
        public var start: Double?
        public var end: Double?
        public var interpolated: Bool?
    }

    /// Blok tekstu inny niż zwykły akapit (nagłówek, element listy, cytat…) — do ładnego
    /// wyświetlania bez parsowania EPUB-a na telefonie. Zwykłe akapity się pomija (oszczędność miejsca).
    public struct Block: Codable, Sendable, Hashable {
        public var href: String
        public var block: Int
        /// Nazwa znacznika XHTML: `h1`…`h6`, `li`, `blockquote`, `pre`, `td`, `figcaption`…
        public var kind: String
        public init(href: String, block: Int, kind: String) {
            self.href = href; self.block = block; self.kind = kind
        }

        /// Poziom nagłówka 1…6 albo `nil`.
        public var headingLevel: Int? {
            guard kind.count == 2, kind.first == "h", let level = Int(kind.dropFirst()), (1...6).contains(level) else { return nil }
            return level
        }
    }

    public var version: Int
    public var createdAt: Date
    /// Silnik rozpoznawania mowy (np. `apple-dictation`) i jego język (BCP 47).
    public var engine: String
    public var locale: String
    /// Pliki, z których mapa powstała — zmiana któregoś oznacza, że mapa jest nieaktualna.
    public var audio: [FileFingerprint]
    public var ebook: FileFingerprint
    public var stats: Stats
    public var sentences: [Sentence]
    /// Od wersji 2; `nil` w mapach z etapu 11a (wtedy nagłówki zgaduje `TextSyncDocument`).
    public var blocks: [Block]?

    public init(createdAt: Date = .now, engine: String, locale: String, audio: [FileFingerprint], ebook: FileFingerprint, stats: Stats, sentences: [Sentence], blocks: [Block]? = nil) {
        self.version = Self.currentVersion
        self.createdAt = createdAt
        self.engine = engine
        self.locale = locale
        self.audio = audio
        self.ebook = ebook
        self.stats = stats
        self.sentences = sentences
        self.blocks = blocks
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> TextSyncMap {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TextSyncMap.self, from: data)
    }

    /// Indeks zdania, które brzmi w chwili `time` (albo ostatniego przed nią), wśród zdań z czasem.
    public func sentenceIndex(at time: Double) -> Int? {
        var best: Int?
        var lo = 0, hi = sentences.count - 1
        // Zdania z czasem są uporządkowane rosnąco, ale przeplatają się z bezczasowymi —
        // wyszukiwanie binarne po najbliższym zdaniu z czasem.
        while lo <= hi {
            let mid = (lo + hi) / 2
            var k = mid
            while k <= hi, sentences[k].start == nil { k += 1 }
            if k > hi { hi = mid - 1; continue }
            if sentences[k].start! <= time { best = k; lo = k + 1 } else { hi = mid - 1 }
        }
        return best
    }
}

/// Wyciąganie tekstu z EPUB-a i wyrównanie go z transkrypcją.
public enum TextSync {
    /// Słowo z rozpoznawania mowy z czasem w całej książce. `text` może zawierać kilka słów
    /// (fraza silnika) — czas dzieli się wtedy po długości.
    public struct Word: Sendable, Hashable {
        public var text: String
        public var start: Double
        public var end: Double
        public init(text: String, start: Double, end: Double) {
            self.text = text; self.start = start; self.end = end
        }
    }

    // MARK: - Tekst z XHTML

    private static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "br", "tr", "td", "th",
        "dt", "dd", "pre", "section", "article", "aside", "header", "footer", "figcaption", "hr",
    ]
    private static let skippedTags: Set<String> = ["script", "style", "head", "title", "svg", "math"]

    /// Bloki tekstu dokumentu XHTML w kolejności (akapity, nagłówki, elementy listy…), białe znaki
    /// zwinięte, encje rozwinięte. Prosty skaner znaczników zamiast parsera XML: rozdziały EPUB-ów
    /// z różnych narzędzi bywają niepoprawnym XML-em (encje HTML, niezamknięte znaczniki).
    public static func blocks(fromXHTML source: String) -> [String] {
        blockElements(fromXHTML: source).map(\.text)
    }

    /// Jak `blocks(fromXHTML:)` (te same bloki w tej samej kolejności, więc te same numery),
    /// z nazwą znacznika, który blok otworzył (`p`, `h2`, `li`…; tekst poza znacznikiem — `p`).
    public static func blockElements(fromXHTML source: String) -> [(text: String, kind: String)] {
        var blocks: [(text: String, kind: String)] = []
        var current = ""
        var kind = "p"
        var skipDepth = 0
        var skipName: String?
        let s = Array(source.unicodeScalars)
        var i = 0

        func flush() {
            let text = collapse(decodeEntities(current))
            if !text.isEmpty { blocks.append((text, kind)) }
            current = ""
        }

        while i < s.count {
            let c = s[i]
            if c != "<" {
                if skipDepth == 0 { current.unicodeScalars.append(c) }
                i += 1
                continue
            }
            // Komentarz, CDATA, deklaracje.
            if i + 3 < s.count, s[i+1] == "!", s[i+2] == "-", s[i+3] == "-" {
                var j = i + 4
                while j + 2 < s.count, !(s[j] == "-" && s[j+1] == "-" && s[j+2] == ">") { j += 1 }
                i = min(s.count, j + 3)
                continue
            }
            var j = i + 1
            var quote: Unicode.Scalar?
            while j < s.count {
                let d = s[j]
                if let q = quote { if d == q { quote = nil } }
                else if d == "\"" || d == "'" { quote = d }
                else if d == ">" { break }
                j += 1
            }
            let inner = String(String.UnicodeScalarView(s[(i+1)..<min(j, s.count)]))
            i = min(s.count, j + 1)
            if inner.hasPrefix("!") || inner.hasPrefix("?") { continue }
            let closing = inner.hasPrefix("/")
            let nameText = closing ? inner.dropFirst() : Substring(inner)
            let name = nameText.prefix { $0.isLetter || $0.isNumber || $0 == ":" || $0 == "-" }.lowercased()
                .split(separator: ":").last.map(String.init) ?? ""
            let selfClosing = inner.hasSuffix("/")

            if skippedTags.contains(name) {
                if closing {
                    if skipName == name { skipDepth = max(0, skipDepth - 1); if skipDepth == 0 { skipName = nil } }
                } else if !selfClosing {
                    if skipDepth == 0 { skipName = name; skipDepth = 1 } else if skipName == name { skipDepth += 1 }
                }
                continue
            }
            if skipDepth > 0 { continue }
            if blockTags.contains(name) {
                flush()
                // Tekst po zamknięciu bloku należy już do rodzica — zwykły akapit.
                kind = closing || selfClosing || name == "br" || name == "hr" ? (name == "br" ? kind : "p") : Self.kindName(name)
            }
            else if name == "img" || name == "image" {
                // Obrazek w tekście nie jest słowem; odstęp, żeby nie skleić sąsiednich słów.
                current += " "
            }
        }
        flush()
        return blocks
    }

    /// Kontenery (`div`, `section`…) liczą się jako zwykły akapit.
    private static func kindName(_ tag: String) -> String {
        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "pre", "td", "th", "dt", "dd", "figcaption": tag
        default: "p"
        }
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "shy": "",
        "hellip": "…", "mdash": "—", "ndash": "–", "bdquo": "„", "ldquo": "“", "rdquo": "”",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "laquo": "«", "raquo": "»", "bull": "•",
        "middot": "·", "copy": "©", "reg": "®", "deg": "°", "times": "×", "thinsp": " ", "ensp": " ", "emsp": " ",
        "zwnj": "", "zwj": "", "oacute": "ó", "Oacute": "Ó", "eacute": "é", "aacute": "á", "uuml": "ü", "ouml": "ö", "auml": "ä",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(12).firstIndex(of: ";") {
                let name = after[..<semi]
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if name.hasPrefix("#") {
                    replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    replacement = entities[String(name)]
                }
                if let replacement {
                    out += replacement
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        out += rest
        return out
    }

    private static func collapse(_ text: String) -> String {
        var out = ""
        var space = false
        for ch in text {
            if ch.isWhitespace {
                space = !out.isEmpty
            } else {
                if space { out.append(" "); space = false }
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - Zdania

    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…", "»", "”", "\""]
    private static let sentenceOpeners: Set<Character> = ["„", "«", "\"", "-", "–", "—"]

    /// Zdania bloku jako przedziały UTF-16: koniec po `.!?…»”"` i odstępie, gdy następne słowo
    /// zaczyna się wielką literą, cyfrą, cudzysłowem albo myślnikiem dialogu.
    public static func sentenceRanges(in block: String) -> [(offset: Int, length: Int)] {
        var result: [(Int, Int)] = []
        let chars = Array(block)
        var utf16 = [Int](); utf16.reserveCapacity(chars.count + 1)
        var pos = 0
        for ch in chars { utf16.append(pos); pos += ch.utf16.count }
        utf16.append(pos)
        var start = 0
        var k = 0
        while k < chars.count {
            if chars[k].isWhitespace, k > start, sentenceEnders.contains(chars[k-1]) {
                var n = k
                while n < chars.count, chars[n].isWhitespace { n += 1 }
                if n < chars.count, chars[n].isUppercase || chars[n].isNumber || sentenceOpeners.contains(chars[n]) {
                    result.append((utf16[start], utf16[k] - utf16[start]))
                    start = n
                    k = n
                    continue
                }
            }
            k += 1
        }
        if start < chars.count {
            var end = chars.count
            while end > start, chars[end-1].isWhitespace { end -= 1 }
            if end > start { result.append((utf16[start], utf16[end] - utf16[start])) }
        }
        return result
    }

    /// Zdania całej książki z rozdziałów w kolejności spisu (`spine`).
    public static func sentences(spine: [(href: String, xhtml: String)]) -> [TextSyncMap.Sentence] {
        document(spine: spine).sentences
    }

    /// Zdania i bloki inne niż zwykły akapit (do zapisania w mapie od wersji 2).
    public static func document(spine: [(href: String, xhtml: String)]) -> (sentences: [TextSyncMap.Sentence], blocks: [TextSyncMap.Block]) {
        var out: [TextSyncMap.Sentence] = []
        var kinds: [TextSyncMap.Block] = []
        for doc in spine {
            for (b, element) in blockElements(fromXHTML: doc.xhtml).enumerated() {
                let block = element.text
                let utf16 = Array(block.utf16)
                let ranges = sentenceRanges(in: block)
                for r in ranges {
                    let text = String(decoding: utf16[r.offset..<(r.offset + r.length)], as: UTF16.self)
                    out.append(.init(href: doc.href, block: b, offset: r.offset, length: r.length, text: text))
                }
                if element.kind != "p", !ranges.isEmpty { kinds.append(.init(href: doc.href, block: b, kind: element.kind)) }
            }
        }
        return (out, kinds)
    }

    // MARK: - Wyrównanie

    static func normalize(_ word: some StringProtocol) -> String {
        var out = ""
        for ch in word.lowercased() {
            if ch == "ó" { out.append("o"); continue }  // ASR myli ó/u, a zgodność ó→o nic nie psuje
            if ch.isLetter || ch.isNumber { out.append(ch) }
        }
        return out
    }

    /// Wyrównanie zdań e-booka z transkrypcją: znormalizowane słowa obu stron, unikalne n-gramy
    /// (od 5 w dół) jako kotwice, najdłuższy rosnący podciąg kotwic, programowanie dynamiczne
    /// z rozmytym podobieństwem słów (odmiana, liczby zapisane cyframi) w lukach między nimi.
    /// Czas zdania to pierwsze i ostatnie dopasowane słowo; zdania bez dopasowania dostają czas
    /// z interpolacji tylko wtedy, gdy luka w nagraniu pasuje do tempa lektora — inaczej lektor
    /// ich nie czyta (przypisy) i zostają bez czasu.
    public static func align(sentences input: [TextSyncMap.Sentence], words: [Word]) -> (sentences: [TextSyncMap.Sentence], stats: TextSyncMap.Stats) {
        var aligner = Aligner(sentences: input, words: words)
        return aligner.run()
    }

    struct Aligner {
        var sentences: [TextSyncMap.Sentence]
        var B: [Int] = []          // słowa książki (identyfikatory słownika)
        var Bs: [Int] = []         // indeks zdania słowa książki
        var A: [Int] = []          // słowa transkrypcji
        var At: [(Double, Double)] = []
        var vocab: [String] = []
        var ids: [String: Int] = [:]
        var digits: [Bool] = []
        var match: [Int: Int] = [:]
        var simCache: [Int64: Float] = [:]

        init(sentences: [TextSyncMap.Sentence], words: [Word]) {
            self.sentences = sentences
            for (si, s) in sentences.enumerated() {
                for w in s.text.split(whereSeparator: \.isWhitespace) {
                    let n = TextSync.normalize(w)
                    if !n.isEmpty { B.append(id(n)); Bs.append(si) }
                }
            }
            for w in words {
                let parts = w.text.split(whereSeparator: \.isWhitespace)
                let total = max(1, parts.reduce(0) { $0 + $1.count })
                var acc = 0
                for p in parts {
                    let n = TextSync.normalize(p)
                    let a = w.start + (w.end - w.start) * Double(acc) / Double(total)
                    acc += p.count
                    let b = w.start + (w.end - w.start) * Double(acc) / Double(total)
                    if !n.isEmpty { A.append(id(n)); At.append((a, b)) }
                }
            }
        }

        mutating func id(_ w: String) -> Int {
            if let i = ids[w] { return i }
            let i = vocab.count
            vocab.append(w); ids[w] = i
            digits.append(w.allSatisfy(\.isNumber))
            return i
        }

        mutating func sim(_ a: Int, _ b: Int) -> Float {
            if a == b { return 1 }
            let key = Int64(min(a, b)) << 32 | Int64(max(a, b))
            if let v = simCache[key] { return v }
            let v = computeSim(vocab[a], vocab[b], digits[a] || digits[b])
            simCache[key] = v
            return v
        }

        func computeSim(_ a: String, _ b: String, _ number: Bool) -> Float {
            if number { return 0.5 }
            let x = Array(a), y = Array(b)
            if x.count >= 4, y.count >= 4, x.prefix(4) == y.prefix(4) { return 0.8 }  // odmiana
            if abs(x.count - y.count) > max(x.count, y.count) / 2 { return 0 }
            var prev = Array(0...y.count)
            var cur = [Int](repeating: 0, count: y.count + 1)
            for i in 1...max(1, x.count) where !x.isEmpty {
                cur[0] = i
                for j in 1...max(1, y.count) where !y.isEmpty {
                    cur[j] = Swift.min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + (x[i-1] == y[j-1] ? 0 : 1))
                }
                swap(&prev, &cur)
            }
            let d = prev[y.count]
            return Swift.max(0, 1 - Float(d) / Float(Swift.max(x.count, y.count)))
        }

        func anchors(_ b0: Int, _ b1: Int, _ a0: Int, _ a1: Int, _ n: Int) -> [(Int, Int)] {
            func unique(_ seq: [Int], _ lo: Int, _ hi: Int) -> [[Int]: Int] {
                guard hi - lo >= n else { return [:] }
                var count: [[Int]: Int] = [:], pos: [[Int]: Int] = [:]
                for i in lo...(hi - n) {
                    let g = Array(seq[i..<(i+n)])
                    count[g, default: 0] += 1
                    pos[g] = i
                }
                return pos.filter { count[$0.key] == 1 }
            }
            let gb = unique(B, b0, b1), ga = unique(A, a0, a1)
            var pairs: [(Int, Int)] = []
            for (g, i) in gb { if let j = ga[g] { pairs.append((i, j)) } }
            pairs.sort { $0.0 < $1.0 }
            // Najdłuższy rosnący podciąg po indeksie transkrypcji.
            var tails: [Int] = [], tailIdx: [Int] = []
            var prev = [Int](repeating: -1, count: pairs.count)
            for (k, p) in pairs.enumerated() {
                var lo = 0, hi = tails.count
                while lo < hi { let m = (lo + hi) / 2; if tails[m] < p.1 { lo = m + 1 } else { hi = m } }
                if lo == tails.count { tails.append(p.1); tailIdx.append(k) } else { tails[lo] = p.1; tailIdx[lo] = k }
                prev[k] = lo > 0 ? tailIdx[lo - 1] : -1
            }
            var out: [(Int, Int)] = []
            var k = tailIdx.last ?? -1
            while k >= 0 { out.append(pairs[k]); k = prev[k] }
            return out.reversed()
        }

        mutating func dp(_ b0: Int, _ b1: Int, _ a0: Int, _ a1: Int) {
            let nb = b1 - b0, na = a1 - a0
            guard nb > 0, na > 0, nb * na <= 3_000_000 else { return }
            let gap: Float = -0.6
            let w = na + 1
            var S = [Float](repeating: 0, count: (nb + 1) * w)
            var T = [UInt8](repeating: 0, count: (nb + 1) * w)
            for i in 1...nb { S[i*w] = Float(i) * gap; T[i*w] = 1 }
            for j in 1...na { S[j] = Float(j) * gap; T[j] = 2 }
            for i in 1...nb {
                let bw = B[b0 + i - 1]
                for j in 1...na {
                    let m = S[(i-1)*w + j-1] + (2 * sim(bw, A[a0 + j - 1]) - 1)
                    let u = S[(i-1)*w + j] + gap, l = S[i*w + j-1] + gap
                    if m >= u, m >= l { S[i*w + j] = m; T[i*w + j] = 0 }
                    else if u >= l { S[i*w + j] = u; T[i*w + j] = 1 }
                    else { S[i*w + j] = l; T[i*w + j] = 2 }
                }
            }
            var i = nb, j = na
            while i > 0, j > 0 {
                switch T[i*w + j] {
                case 0:
                    if sim(B[b0 + i - 1], A[a0 + j - 1]) >= 0.6 { match[b0 + i - 1] = a0 + j - 1 }
                    i -= 1; j -= 1
                case 1: i -= 1
                default: j -= 1
                }
            }
        }

        mutating func solve(_ b0: Int, _ b1: Int, _ a0: Int, _ a1: Int, _ n: Int) {
            if (b1 - b0) * (a1 - a0) <= 40_000 || n < 2 { dp(b0, b1, a0, a1); return }
            var pb = b0, pa = a0
            for (b, a) in anchors(b0, b1, a0, a1, n) {
                if b < pb || a < pa { continue }
                solve(pb, b, pa, a, n - 1)
                for k in 0..<n { match[b + k] = a + k }
                pb = b + n; pa = a + n
            }
            solve(pb, b1, pa, a1, n - 1)
        }

        mutating func run() -> (sentences: [TextSyncMap.Sentence], stats: TextSyncMap.Stats) {
            solve(0, B.count, 0, A.count, 5)

            var perSentence: [Int: (min: Int, max: Int, count: Int)] = [:]
            for (b, a) in match {
                let s = Bs[b]
                if let e = perSentence[s] { perSentence[s] = (Swift.min(e.min, a), Swift.max(e.max, a), e.count + 1) }
                else { perSentence[s] = (a, a, 1) }
            }
            var out = sentences
            for k in out.indices {
                out[k].start = nil; out[k].end = nil; out[k].interpolated = nil
                let words = out[k].text.split(whereSeparator: \.isWhitespace).filter { !TextSync.normalize($0).isEmpty }.count
                if let m = perSentence[k], Double(m.count) >= Swift.max(1, Double(words) * 0.3) {
                    out[k].start = At[m.min].0
                    out[k].end = At[m.max].1
                }
            }
            let timed = out.indices.filter { out[$0].start != nil }
            let chars = timed.reduce(0.0) { $0 + Double(out[$1].text.count) }
            let seconds = timed.reduce(0.0) { $0 + (out[$1].end! - out[$1].start!) }
            let rate = seconds > 0 ? chars / seconds : 15  // znaki na sekundę lektora
            for (x, y) in zip(timed, timed.dropFirst()) where y > x + 1 {
                let t0 = out[x].end!, t1 = out[y].start!
                let gapChars = (x+1..<y).reduce(0.0) { $0 + Double(out[$1].text.count) }
                let expected = gapChars / rate
                guard t1 > t0, gapChars > 0, t1 - t0 >= 0.4 * expected, t1 - t0 <= 2.5 * expected + 2 else { continue }
                var acc = 0.0
                for k in (x+1)..<y {
                    out[k].start = t0 + (t1 - t0) * acc / gapChars
                    acc += Double(out[k].text.count)
                    out[k].end = t0 + (t1 - t0) * acc / gapChars
                    out[k].interpolated = true
                }
            }
            let interpolated = out.filter { $0.interpolated == true }.count
            let direct = out.filter { $0.start != nil }.count - interpolated
            let stats = TextSyncMap.Stats(
                bookWords: B.count, matchedWords: match.count, transcribedWords: A.count,
                sentences: out.count, direct: direct, interpolated: interpolated,
                untimed: out.count - direct - interpolated)
            return (out, stats)
        }
    }
}
