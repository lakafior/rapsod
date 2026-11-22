// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import AudiobookshelfKit

@Suite struct TextSyncTests {
    @Test func blocksSkipHeadAndDecodeEntities() {
        let xhtml = """
        <?xml version="1.0"?><html><head><title>Tytuł</title><style>p{}</style></head>
        <body><h1>Rozdział&nbsp;1</h1><p>Ala ma <i>kota</i> &amp; psa.<br/>Druga&#8230; linia</p>
        <!-- komentarz <p>nie</p> --><p class="x">Zażółć &bdquo;gęślą&rdquo; jaźń</p></body></html>
        """
        #expect(TextSync.blocks(fromXHTML: xhtml) == ["Rozdział 1", "Ala ma kota & psa.", "Druga… linia", "Zażółć „gęślą” jaźń"])
    }

    @Test func sentenceSplitting() {
        let block = "Pierwsze zdanie. Drugie? — Trzecie, z dialogu! 12 lat później. koniec bez wielkiej."
        let parts = TextSync.sentenceRanges(in: block).map { r in
            String(decoding: Array(block.utf16)[r.offset..<(r.offset + r.length)], as: UTF16.self)
        }
        #expect(parts == ["Pierwsze zdanie.", "Drugie?", "— Trzecie, z dialogu!", "12 lat później. koniec bez wielkiej."])
    }

    @Test func offsetsAreUTF16() {
        let spine = [(href: "a.xhtml", xhtml: "<p>Zdanie 😀 pierwsze. Drugie zdanie.</p>")]
        let s = TextSync.sentences(spine: spine)
        #expect(s.count == 2)
        #expect(s[1].text == "Drugie zdanie.")
        #expect(s[1].offset == "Zdanie 😀 pierwsze. ".utf16.count)
        #expect(s[1].block == 0)
    }

    /// Lektor czyta tekst z zapowiedzią na początku i bez przypisu, z błędami rozpoznawania:
    /// przypis zostaje bez czasu, reszta dostaje czas słów, które naprawdę padły.
    @Test func alignSkipsUnreadFootnoteAndToleratesErrors() {
        let paragraphs = (0..<60).map { i in
            "Rozdział \(i) opowiada o sprawie numer \(i), w której oskarżona kobieta \(["Anna", "Beata", "Celina"][i % 3]) zeznawała przed sądem okręgowym w mieście \(["Warszawa", "Kraków", "Gdańsk", "Łódź"][i % 4]) przez wiele długich godzin."
        }
        var spine: [(href: String, xhtml: String)] = []
        for (i, p) in paragraphs.enumerated() {
            var body = "<p>\(p)</p>"
            if i == 30 { body += "<p>[1] Przypis, którego lektor nie czyta w nagraniu wcale.</p>" }
            spine.append((href: "c\(i).xhtml", xhtml: body))
        }
        let sentences = TextSync.sentences(spine: spine)

        // „Nagranie”: zapowiedź wydawcy, potem tekst z błędami (co dziesiąte słowo zniekształcone,
        // liczby cyframi), 0,4 s na słowo, bez przypisu.
        var words: [TextSync.Word] = []
        var t = 0.0
        for w in ["Wydawnictwo", "przedstawia", "audiobook", "czyta", "lektor"] { words.append(.init(text: w, start: t, end: t + 0.3)); t += 0.4 }
        var expectedStart: [String: Double] = [:]
        for s in sentences where !s.text.hasPrefix("[1]") {
            expectedStart[s.text] = t
            for (k, w) in s.text.split(separator: " ").enumerated() {
                let spoken = k % 10 == 3 ? String(w.dropLast()) + "x" : String(w)
                words.append(.init(text: spoken, start: t, end: t + 0.3)); t += 0.4
            }
        }
        let result = TextSync.align(sentences: sentences, words: words)
        let footnote = result.sentences.first { $0.text.hasPrefix("[1]") }
        #expect(footnote?.start == nil)
        for s in result.sentences where !s.text.hasPrefix("[1]") {
            let start = try! #require(s.start)
            #expect(abs(start - expectedStart[s.text]!) < 0.01, "\(s.text)")
        }
        #expect(result.stats.untimed == 1)
        #expect(result.stats.direct == sentences.count - 1)
        #expect(result.stats.matchedFraction > 0.85)

        let map = TextSyncMap(engine: "test", locale: "pl-PL", audio: [], ebook: .init(ino: "1", filename: "a.epub", size: 1), stats: result.stats, sentences: result.sentences)
        let decoded = try! TextSyncMap.decode(try! map.encoded())
        #expect(decoded.sentences == map.sentences)
        let mid = result.sentences[20]
        #expect(decoded.sentenceIndex(at: mid.start! + 0.1) == 20)
        #expect(decoded.sentenceIndex(at: 0) == nil)
    }

    @Test func mapFileName() {
        #expect(TextSyncMap.fileName(forEbook: "Autor - Tytuł.epub") == "Autor - Tytuł.sync.json")
    }
}
