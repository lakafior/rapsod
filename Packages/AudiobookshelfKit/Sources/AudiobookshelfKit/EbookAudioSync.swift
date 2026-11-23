// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 11c).

import Foundation

/// Przejścia między miejscem w e-booku a czasem w nagraniu na podstawie mapy tekstu (`TextSyncMap`).
///
/// Czytnik (epub.js na iOS, docelowo też Mac) nie zna numerów zdań mapy — zna rozdział (`href`)
/// i tekst strony. Dlatego dopasowanie idzie po tekście: rozdział po końcówce ścieżki (mapa ma
/// ścieżkę w archiwum, epub.js — względem pliku OPF), zdanie po treści bez białych znaków
/// i bez wielkości liter (granice bloków w DOM nie mają spacji, mapa ma zwinięte odstępy).
/// Dokładność: początek zdania, które jest na górze strony (strona zaczęta w środku zdania →
/// początek tego zdania); w drugą stronę — strona, na której zaczyna się zdanie brzmiące w danej chwili.
public enum EbookAudioSync {
    /// Fragment do odszukania w rozdziale e-booka: `key` (tekst znormalizowany jak `normalized`)
    /// i to, które to wystąpienie `key` w rozdziale (0 — pierwsze).
    public struct Passage: Equatable, Sendable {
        public var href: String
        public var key: String
        public var occurrence: Int
        public var sentence: Int
    }

    /// Najdłuższy klucz wyszukiwania (znaki bez odstępów).
    static let keyLength = 40
    /// Krótszy tekst niż tyle znaków nie wystarcza do rozpoznania strony.
    static let minimumPassage = 8

    /// Bez białych znaków, miękkich łączników i wielkości liter.
    public static func normalized(_ text: some StringProtocol) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text where !ch.isWhitespace && ch != "\u{00AD}" && ch != "\u{200B}" {
            out.append(contentsOf: ch.lowercased())
        }
        return out
    }

    /// Ten sam rozdział: ścieżki równe albo jedna kończy się drugą (po `/`).
    public static func sameChapter(_ a: String, _ b: String) -> Bool {
        let a = a.removingPercentEncoding ?? a, b = b.removingPercentEncoding ?? b
        let x = a.split(separator: "#").first.map(String.init) ?? a
        let y = b.split(separator: "#").first.map(String.init) ?? b
        return x == y || x.hasSuffix("/" + y) || y.hasSuffix("/" + x)
    }

    /// Zdanie mapy na początku strony. `passage` — tekst od początku strony (kilkaset znaków).
    /// `nil` — tekst nie pasuje do mapy (inne wydanie e-booka albo fragment, którego mapa nie ma).
    public static func sentence(in map: TextSyncMap, href: String, passage: String) -> Int? {
        let page = String(normalized(passage).prefix(600))
        guard page.count >= minimumPassage else { return nil }
        let chapter = map.sentences.indices.filter { sameChapter(map.sentences[$0].href, href) }
        guard !chapter.isEmpty else { return nil }
        let texts = chapter.map { normalized(map.sentences[$0].text) }
        let head = String(page.prefix(30))
        // Powtórzone zdanie (np. „— Dlaczego?”) rozstrzyga następne zdanie, jeśli też jest na stronie.
        func confirmed(_ k: Int) -> Bool {
            guard k + 1 < texts.count else { return false }
            return page.contains(String(texts[k + 1].prefix(20)))
        }
        func pick(_ ks: [Int]) -> Int? { ks.first(where: confirmed) ?? ks.first }

        // Strona zaczyna się w środku (albo na początku) zdania, które zawiera początek strony.
        if head.count >= minimumPassage, let k = pick(texts.indices.filter({ texts[$0].contains(head) })) {
            return chapter[k]
        }
        // Strona zaczyna się końcówką zdania krótszą niż `head`: pierwsze zdanie, którego początek
        // jest na stronie, a przed nim — zdanie, które ta końcówka kończy.
        var found: [(offset: Int, k: Int)] = []
        for (k, text) in texts.enumerated() where text.count >= minimumPassage {
            let key = String(text.prefix(keyLength))
            guard let range = page.range(of: key) else { continue }
            found.append((page.distance(from: page.startIndex, to: range.lowerBound), k))
        }
        guard let nearest = found.map(\.offset).min(),
              let k = pick(found.filter { $0.offset == nearest }.map(\.k)) else { return nil }
        let best = (offset: nearest, k: k)
        if best.offset > 0, best.k > 0 {
            let previous = texts[best.k - 1]
            let tail = String(page.prefix(best.offset))
            if previous.hasSuffix(tail) || tail.count < minimumPassage { return chapter[best.k - 1] }
        }
        return chapter[best.k]
    }

    /// Czas w nagraniu dla strony e-booka: początek zdania na górze strony (zdanie bez czasu —
    /// następne z czasem). `nil` — strona nie pasuje do mapy albo dalej nic nie ma czasu.
    public static func time(in map: TextSyncMap, href: String, passage: String) -> Double? {
        guard let index = sentence(in: map, href: href, passage: passage) else { return nil }
        return startTime(in: map, from: index)
    }

    static func startTime(in map: TextSyncMap, from index: Int) -> Double? {
        map.sentences[index...].lazy.compactMap(\.start).first
    }

    /// Fragment e-booka dla chwili w nagraniu: zdanie, które wtedy brzmi (albo ostatnie przed nią).
    public static func passage(in map: TextSyncMap, time: Double) -> Passage? {
        guard let index = map.sentenceIndex(at: time) ?? map.sentences.firstIndex(where: { $0.start != nil }) else { return nil }
        let sentence = map.sentences[index]
        let key = String(normalized(sentence.text).prefix(keyLength))
        guard !key.isEmpty else { return nil }
        // Które to wystąpienie klucza w rozdziale — liczone w tekście poprzednich zdań tego rozdziału
        // (czytnik liczy tak samo w tekście dokumentu).
        var before = ""
        for other in map.sentences[..<index] where sameChapter(other.href, sentence.href) {
            before += normalized(other.text)
        }
        return Passage(href: sentence.href, key: key, occurrence: occurrences(of: key, in: before), sentence: index)
    }

    static func occurrences(of key: String, in text: String) -> Int {
        var count = 0
        var start = text.startIndex
        while let range = text.range(of: key, range: start..<text.endIndex) {
            count += 1
            start = text.index(after: range.lowerBound)
        }
        return count
    }
}
