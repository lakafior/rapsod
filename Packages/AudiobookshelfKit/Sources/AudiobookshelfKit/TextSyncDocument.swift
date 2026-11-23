// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 11b).

import Foundation

/// Mapa tekstu przygotowana do wyświetlania w odtwarzaczu (etap 11b): akapity i nagłówki,
/// szybkie wyszukiwanie zdania dla czasu nagrania i czas początku zdania (dotknięcie zdania).
/// Bez zależności od interfejsu — tę samą strukturę czytają widoki na Macu i iOS.
public struct TextSyncDocument: Sendable {
    public struct Paragraph: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable {
            case body
            /// Nagłówek (1 — najważniejszy).
            case heading(Int)
            case quote
            case listItem
            case preformatted
        }

        public let id: Int
        public let kind: Kind
        /// Zdania akapitu (indeksy w `map.sentences`).
        public let sentences: Range<Int>
        /// Pierwszy blok nowego pliku rozdziału EPUB-a — przed nim wyraźna przerwa.
        public let startsSection: Bool

        public var isHeading: Bool { if case .heading = kind { true } else { false } }
    }

    public let map: TextSyncMap
    public let paragraphs: [Paragraph]
    /// Akapit każdego zdania.
    private let paragraphIndex: [Int32]
    /// Zdania z czasem w kolejności nagrania i ich początki — wyszukiwanie binarne.
    private let timedSentences: [Int32]
    private let timedStarts: [Double]

    public var sentenceCount: Int { map.sentences.count }
    public var timedCount: Int { timedSentences.count }

    public init(map: TextSyncMap) {
        self.map = map
        let sentences = map.sentences
        var kinds: [String: String] = [:]
        for block in map.blocks ?? [] { kinds["\(block.block)|\(block.href)"] = block.kind }

        var paragraphs: [Paragraph] = []
        var index = [Int32](repeating: 0, count: sentences.count)
        var start = 0
        var blockInSection = 0
        while start < sentences.count {
            let first = sentences[start]
            var end = start + 1
            while end < sentences.count, sentences[end].block == first.block, sentences[end].href == first.href { end += 1 }
            let newSection = start > 0 && sentences[start - 1].href != first.href
            if newSection { blockInSection = 0 }
            let kind: Paragraph.Kind
            if map.blocks != nil {
                kind = Self.kind(kinds["\(first.block)|\(first.href)"])
            } else {
                // Mapa z etapu 11a nie ma rodzajów bloków — nagłówek zgadujemy: krótki pierwszy
                // (albo drugi) blok rozdziału, jedno zdanie bez kropki na końcu.
                kind = Self.looksLikeHeading(sentences[start..<end], blockInSection: blockInSection) ? .heading(2) : .body
            }
            let id = paragraphs.count
            paragraphs.append(Paragraph(id: id, kind: kind, sentences: start..<end, startsSection: newSection))
            for k in start..<end { index[k] = Int32(id) }
            blockInSection += 1
            start = end
        }
        self.paragraphs = paragraphs
        self.paragraphIndex = index

        // Czasy powinny rosnąć z kolejnością zdań; zdanie, które cofa się w czasie (błąd wyrównania),
        // pomijamy, żeby wyszukiwanie binarne było poprawne.
        var timed: [Int32] = [], starts: [Double] = []
        timed.reserveCapacity(sentences.count); starts.reserveCapacity(sentences.count)
        var last = -Double.infinity
        for (k, s) in sentences.enumerated() {
            guard let t = s.start, t.isFinite, t >= last else { continue }
            timed.append(Int32(k)); starts.append(t); last = t
        }
        timedSentences = timed
        timedStarts = starts
    }

    private static func kind(_ tag: String?) -> Paragraph.Kind {
        switch tag {
        case "h1": .heading(1)
        case "h2": .heading(2)
        case "h3", "h4", "h5", "h6": .heading(3)
        case "blockquote": .quote
        case "li", "dd": .listItem
        case "pre": .preformatted
        default: .body
        }
    }

    static func looksLikeHeading(_ sentences: ArraySlice<TextSyncMap.Sentence>, blockInSection: Int) -> Bool {
        guard sentences.count == 1, blockInSection < 2, let text = sentences.first?.text else { return false }
        guard text.count <= 80, let last = text.last else { return false }
        return !".,;:…!?»”\"-–—".contains(last)
    }

    // MARK: - Czas ↔ zdanie

    /// Zdanie, które brzmi w chwili `time`: ostatnie zdanie z czasem, które się już zaczęło.
    /// W luce (muzyka, zapowiedź, przypis bez czasu) zostaje poprzednie zdanie; przed pierwszym
    /// zdaniem z czasem — `nil`. O(log n).
    public func sentence(at time: Double) -> Int? {
        guard let k = timedPosition(atOrBefore: time) else { return nil }
        return Int(timedSentences[k])
    }

    /// Początek następnego zdania po `time` (do zaplanowania zmiany podświetlenia między tyknięciami zegara).
    public func nextStart(after time: Double) -> Double? {
        var lo = 0, hi = timedStarts.count
        while lo < hi { let m = (lo + hi) / 2; if timedStarts[m] <= time { lo = m + 1 } else { hi = m } }
        return lo < timedStarts.count ? timedStarts[lo] : nil
    }

    private func timedPosition(atOrBefore time: Double) -> Int? {
        var lo = 0, hi = timedStarts.count
        while lo < hi { let m = (lo + hi) / 2; if timedStarts[m] <= time { lo = m + 1 } else { hi = m } }
        return lo > 0 ? lo - 1 : nil
    }

    /// Czas, od którego odtwarzać zdanie: jego początek, a dla zdania bez czasu (lektor go nie
    /// czyta) — początek następnego zdania z czasem (albo koniec poprzedniego na końcu książki).
    public func startTime(ofSentence index: Int) -> Double? {
        guard map.sentences.indices.contains(index) else { return nil }
        if let t = map.sentences[index].start { return t }
        var lo = 0, hi = timedSentences.count
        while lo < hi { let m = (lo + hi) / 2; if Int(timedSentences[m]) < index { lo = m + 1 } else { hi = m } }
        if lo < timedSentences.count { return timedStarts[lo] }
        return lo > 0 ? map.sentences[Int(timedSentences[lo - 1])].end : nil
    }

    public func hasTime(sentence index: Int) -> Bool {
        map.sentences.indices.contains(index) && map.sentences[index].start != nil
    }

    public func paragraph(ofSentence index: Int) -> Int? {
        paragraphIndex.indices.contains(index) ? Int(paragraphIndex[index]) : nil
    }

    /// Najbliższy nagłówek przed akapitem (podpis przerwy rozdziału, gdy brak nagłówka w EPUB-ie).
    public func heading(before paragraph: Int) -> Paragraph? {
        guard paragraphs.indices.contains(paragraph) else { return nil }
        return paragraphs[...paragraph].last { $0.isHeading }
    }

    // MARK: - Tekst do pokazania

    /// Tekst zdania do wyświetlenia (bez zmiany tekstu w mapie): polskie zasady łamania —
    /// twarda spacja po myślniku dialogu i po jednoliterowych spójnikach i przyimkach, żeby nie
    /// zostawały na końcu wiersza; proste cudzysłowy zamienione na „…”.
    public func displayText(ofSentence index: Int) -> String {
        Self.typeset(map.sentences[index].text)
    }

    public static func typeset(_ text: String) -> String {
        let nbsp: Character = "\u{00A0}"
        var out = ""
        out.reserveCapacity(text.count)
        let chars = Array(text)
        var quoteOpen = false
        for (k, ch) in chars.enumerated() {
            var c = ch
            if c == "\"" {
                c = quoteOpen ? "”" : "„"
                quoteOpen.toggle()
            } else if c == "„" { quoteOpen = true } else if c == "”" { quoteOpen = false }
            if c == " ", k > 0 {
                let prev = chars[k - 1]
                let wordStart = k < 2 || chars[k - 2] == " " || chars[k - 2] == nbsp || "„(«".contains(chars[k - 2])
                // Myślnik dialogu na początku zdania zostaje z pierwszym słowem; myślnik wtrącenia
                // zostaje na końcu wiersza (twarda spacja przed nim), jednoliterowe słowa (a, i, o,
                // u, w, z) — z następnym słowem.
                if k == 1, "—–-".contains(prev) { out.append(nbsp); continue }
                if k + 1 < chars.count, "—–".contains(chars[k + 1]) { out.append(nbsp); continue }
                if wordStart, prev.isLetter, "aiouwzAIOUWZ".contains(prev) { out.append(nbsp); continue }
            }
            out.append(c)
        }
        return out
    }
}

/// Co pokazać zamiast tekstu, gdy mapy nie ma.
public enum TextSyncUnavailable: Sendable, Equatable {
    /// Odcinek podcastu albo pozycja bez książki.
    case notBook
    /// Książka nie ma e-booka.
    case noEbook
    /// E-book jest, ale nie EPUB (synchronizacja liczy tylko EPUB-y).
    case notEpub
    /// E-book EPUB jest, ale nikt go jeszcze nie zsynchronizował na Macu.
    case notSynced
    /// Bez połączenia, a mapa nie jest ani pobrana, ani zapamiętana.
    case offline

    /// Krótka informacja dla użytkownika (z podpowiedzią, jak utworzyć mapę).
    public var message: String {
        switch self {
        case .notBook: "Tekst jest dostępny tylko dla książek."
        case .noEbook: "Ta książka nie ma e-booka. Na Macu dodaj EPUB na stronie książki („Tekst książki” → „Dodaj e-book…”), a potem użyj „Synchronizuj e-book”."
        case .notEpub: "Tekst da się zsynchronizować tylko z e-booka EPUB."
        case .notSynced: "E-book nie jest jeszcze zsynchronizowany z nagraniem. Na Macu otwórz stronę książki i w karcie „Tekst książki” wybierz „Synchronizuj e-book”."
        case .offline: "Brak połączenia z serwerem, a tekstu tej książki nie ma na urządzeniu. Pobierz książkę na telefon, gdy będzie sieć."
        }
    }
}

extension TextSyncMap {
    /// Plik mapy wśród plików pozycji: najpierw ten od e-booka podstawowego, potem dowolny `.sync.json`.
    public static func file(in item: AudiobookshelfClient.ItemDetail) -> AudiobookshelfClient.ItemDetail.LibraryFile? {
        let files = (item.libraryFiles?.elements ?? []).filter { ($0.metadata.filename ?? "").hasSuffix(fileSuffix) }
        if let ebook = item.media.ebookFile?.metadata?.filename {
            let name = fileName(forEbook: ebook)
            if let match = files.first(where: { $0.metadata.filename == name }) { return match }
        }
        return files.first
    }

    /// Dlaczego pozycja nie ma mapy (gdy jej nie ma).
    public static func unavailableReason(_ item: AudiobookshelfClient.ItemDetail) -> TextSyncUnavailable {
        if item.isPodcast { return .notBook }
        guard let ebook = item.media.ebookFile else { return .noEbook }
        let format = (ebook.ebookFormat ?? (ebook.metadata?.filename as NSString?)?.pathExtension ?? "").lowercased()
        return format == "epub" ? .notSynced : .notEpub
    }

    /// Czy mapa powstała z innych plików niż obecne (nowe nagranie albo inny e-book).
    public func isStale(for item: AudiobookshelfClient.ItemDetail) -> Bool {
        let tracks = item.media.tracks?.elements ?? []
        let ebook = item.media.ebookFile
        return audio.map(\.ino) != tracks.map(\.ino) || audio.map(\.size) != tracks.map(\.metadata?.size)
            || self.ebook.ino != ebook?.ino || self.ebook.size != ebook?.metadata?.size
    }
}
