// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import AudiobookshelfKit

@Suite struct TextSyncDocumentTests {
    static func sentence(_ text: String, href: String = "a.xhtml", block: Int, _ start: Double?, _ end: Double?) -> TextSyncMap.Sentence {
        .init(href: href, block: block, offset: 0, length: text.utf16.count, text: text, start: start, end: end)
    }

    static func map(_ sentences: [TextSyncMap.Sentence], blocks: [TextSyncMap.Block]? = []) -> TextSyncMap {
        TextSyncMap(engine: "test", locale: "pl-PL", audio: [.init(ino: "1", filename: "a.m4b", size: 100)],
                    ebook: .init(ino: "2", filename: "a.epub", size: 50),
                    stats: .init(bookWords: 0, matchedWords: 0, transcribedWords: 0, sentences: sentences.count, direct: 0, interpolated: 0, untimed: 0),
                    sentences: sentences, blocks: blocks)
    }

    /// Wstęp lektora (przed pierwszym zdaniem), przypis bez czasu, luka (muzyka) między zdaniami.
    static let sample = map([
        sentence("Rozdział pierwszy", block: 0, 5, 6.5),
        sentence("Ala ma kota.", block: 1, 7, 9),
        sentence("Kot ma Alę.", block: 1, 9, 11),
        sentence("[1] Przypis.", block: 2, nil, nil),
        sentence("Po muzyce.", href: "b.xhtml", block: 0, 20, 22),
        sentence("Koniec.", href: "b.xhtml", block: 0, 22, 23),
    ], blocks: [.init(href: "a.xhtml", block: 0, kind: "h2")])

    @Test func sentenceLookupAtBoundariesAndGaps() {
        let doc = TextSyncDocument(map: Self.sample)
        #expect(doc.sentence(at: 0) == nil)         // zapowiedź przed tekstem
        #expect(doc.sentence(at: 4.999) == nil)
        #expect(doc.sentence(at: 5) == 0)           // dokładnie na początku
        #expect(doc.sentence(at: 8.99) == 1)
        #expect(doc.sentence(at: 9) == 2)           // granica należy do następnego zdania
        #expect(doc.sentence(at: 15) == 2)          // luka: zostaje ostatnie zdanie, przypis nigdy nie jest bieżący
        #expect(doc.sentence(at: 20) == 4)
        #expect(doc.sentence(at: 10_000) == 5)
        #expect(doc.nextStart(after: 9) == 20)
        #expect(doc.nextStart(after: 8) == 9)
        #expect(doc.nextStart(after: 30) == nil)
    }

    @Test func startTimeOfUntimedSentenceIsNextTimed() {
        let doc = TextSyncDocument(map: Self.sample)
        #expect(doc.startTime(ofSentence: 1) == 7)
        #expect(doc.startTime(ofSentence: 3) == 20)
        #expect(doc.startTime(ofSentence: 99) == nil)
        let tail = TextSyncDocument(map: Self.map([Self.sentence("A.", block: 0, 1, 2), Self.sentence("Bez czasu.", block: 1, nil, nil)]))
        #expect(tail.startTime(ofSentence: 1) == 2)
    }

    @Test func paragraphsAndSections() {
        let doc = TextSyncDocument(map: Self.sample)
        #expect(doc.paragraphs.map(\.sentences) == [0..<1, 1..<3, 3..<4, 4..<6])
        #expect(doc.paragraphs[0].kind == .heading(2))
        #expect(doc.paragraphs[1].kind == .body)
        #expect(doc.paragraphs.map(\.startsSection) == [false, false, false, true])
        #expect(doc.paragraph(ofSentence: 2) == 1)
        #expect(doc.paragraph(ofSentence: 5) == 3)
        #expect(doc.heading(before: 2)?.id == 0)
    }

    /// Mapa z etapu 11a (bez `blocks`, wersja 1) — czyta się, nagłówek zgadnięty.
    @Test func olderFormatDecodesAndGuessesHeadings() throws {
        var json = try JSONSerialization.jsonObject(with: Self.sample.encoded()) as! [String: Any]
        json["version"] = 1
        json.removeValue(forKey: "blocks")
        let data = try JSONSerialization.data(withJSONObject: json)
        let map = try TextSyncLoader.decode(data)
        #expect(map.blocks == nil)
        let doc = TextSyncDocument(map: map)
        #expect(doc.paragraphs[0].kind == .heading(2))   // „Rozdział pierwszy” — krótki, bez kropki
        #expect(doc.paragraphs[1].kind == .body)
        #expect(doc.paragraphs[2].kind == .body)          // trzeci blok rozdziału, z kropką
    }

    @Test func damagedMapIsRejected() {
        #expect(throws: TextSyncLoader.Damaged.self) { try TextSyncLoader.decode(Data("{\"version\": 2".utf8)) }
        #expect(throws: TextSyncLoader.Damaged.self) { try TextSyncLoader.decode(Data("[1,2,3]".utf8)) }
        let empty = Self.map([])
        #expect(throws: TextSyncLoader.Damaged.self) { try TextSyncLoader.decode(try empty.encoded()) }
    }

    /// Czasy cofające się (błąd wyrównania) nie psują wyszukiwania binarnego.
    @Test func nonMonotonicTimesAreSkipped() {
        let doc = TextSyncDocument(map: Self.map([
            Self.sentence("A.", block: 0, 10, 11), Self.sentence("B.", block: 0, 3, 4), Self.sentence("C.", block: 0, 12, 13),
        ]))
        #expect(doc.timedCount == 2)
        #expect(doc.sentence(at: 11.5) == 0)
        #expect(doc.sentence(at: 12) == 2)
    }

    @Test func lookupIsFastOnLargeBook() {
        let sentences = (0..<60_000).map { Self.sentence("Zdanie \($0).", block: $0 / 5, Double($0) * 3, Double($0) * 3 + 2.5) }
        let doc = TextSyncDocument(map: Self.map(sentences))
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for k in 0..<100_000 { _ = doc.sentence(at: Double(k % 180_000)) }
        }
        #expect(doc.sentence(at: 3 * 41_234 + 1) == 41_234)
        #expect(elapsed < .seconds(1))
    }

    @Test func blockKindsKeepNumbering() {
        let xhtml = "<body><h1>Część I</h1><div><p>Akapit.</p><blockquote>Cytat.</blockquote>Luźny tekst.<br/>Drugi wiersz.</div><ul><li>Punkt.</li></ul></body>"
        let elements = TextSync.blockElements(fromXHTML: xhtml)
        #expect(elements.map(\.text) == TextSync.blocks(fromXHTML: xhtml))
        #expect(elements.map(\.kind) == ["h1", "p", "blockquote", "p", "p", "li"])
        let doc = TextSync.document(spine: [(href: "x.xhtml", xhtml: xhtml)])
        #expect(doc.blocks.map(\.kind) == ["h1", "blockquote", "li"])
        #expect(doc.blocks.map(\.block) == [0, 2, 5])
    }

    @Test func polishTypesetting() {
        let nb = "\u{00A0}"
        #expect(TextSyncDocument.typeset("— Idę w las i z psem") == "—\(nb)Idę w\(nb)las i\(nb)z\(nb)psem")
        #expect(TextSyncDocument.typeset("Szedł – powoli – do domu") == "Szedł\(nb)– powoli\(nb)– do domu")
        #expect(TextSyncDocument.typeset("Rzekł \"tak\" i wyszedł") == "Rzekł „tak” i\(nb)wyszedł")
    }

    @MainActor @Test func followModelTracksAndJumps() {
        let sentences = (0..<3000).map { Self.sentence("Zdanie \($0).", block: $0 / 3, Double($0) * 2, Double($0) * 2 + 1.8) }
        let model = TextFollowModel()
        model.apply(.ready(TextSyncDocument(map: Self.map(sentences)), isStale: false, isOffline: false))
        #expect(model.phase == .ready)
        model.update(time: 1, rate: 1, isPlaying: false)
        #expect(model.currentSentence == 0)
        let jumps = model.jumpRequest
        // Przeskok (suwak, rozdział) — prośba o natychmiastowe ustawienie tekstu.
        model.update(time: 2 * 900 + 0.5, rate: 1, isPlaying: false)
        #expect(model.currentSentence == 900)
        #expect(model.currentParagraph == 300)
        #expect(model.jumpRequest == jumps + 1)
        // Ręczne przewinięcie: zdanie się zmienia, bez prośby o przeskok; wznowienie odtwarzania wraca do śledzenia.
        model.userDidScroll()
        #expect(!model.isFollowing)
        model.update(time: 2 * 901 + 0.5, rate: 1, isPlaying: false)
        #expect(model.currentSentence == 901)
        #expect(model.jumpRequest == jumps + 1)
        let returns = model.returnRequest
        model.update(time: 2 * 901 + 0.5, rate: 1, isPlaying: true)
        #expect(model.isFollowing)
        #expect(model.returnRequest == returns + 1)
        // Zwykłe tykanie zegara to nie przeskok.
        model.update(time: 2 * 901 + 0.9, rate: 1, isPlaying: true)
        #expect(model.jumpRequest == jumps + 1)
        #expect(model.span(ofSentence: 901) == 1802...1803.8)
    }

    /// Granice zdań bez tyknięć zegara: kilka krótkich zdań w pół sekundy przechodzi po kolei,
    /// a tyknięcie z czasem tuż sprzed przewidzianej granicy nie cofa podświetlenia.
    @MainActor @Test func followModelChainsBoundariesWithoutFlicker() async throws {
        let starts: [Double] = [0, 10, 10.12, 10.24, 10.36, 20]
        let sentences = starts.enumerated().map { Self.sentence("Z \($0.offset).", block: $0.offset, $0.element, $0.element + 0.1) }
        let model = TextFollowModel()
        model.apply(.ready(TextSyncDocument(map: Self.map(sentences)), isStale: false, isOffline: false))
        model.update(time: 9.95, rate: 1, isPlaying: true)
        #expect(model.currentSentence == 0)
        var seen: [Int] = []
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(10))
            if let s = model.currentSentence, seen.last != s { seen.append(s) }
        }
        // Po kolei, bez cofania się; przy wolnym wybudzeniu (obciążona maszyna) zdanie może zostać przeskoczone.
        #expect(seen.first == 0 && seen.last == 4 && zip(seen, seen.dropFirst()).allSatisfy { $0 < $1 }, "\(seen)")
        // Zegar odtwarzacza „spóźniony” o 0,2 s względem przewidywania — zostajemy przy zdaniu 4.
        model.update(time: 10.30, rate: 1, isPlaying: true)
        #expect(model.currentSentence == 4)
        // Prawdziwy przeskok wstecz działa.
        model.update(time: 5, rate: 1, isPlaying: true)
        #expect(model.currentSentence == 0)
    }

    /// Zegar odtwarzacza przestaje tykać (czekanie na dane): podświetlenie nie ucieka naprzód
    /// dalej niż ok. pół sekundy, a spóźnione tyknięcie z dawnym czasem nie jest przeskokiem
    /// i nie cofa podświetlenia o więcej niż jedno krótkie zdanie.
    @MainActor @Test func followModelSurvivesStalledClock() async throws {
        let sentences = (0..<40).map { Self.sentence("Z \($0).", block: $0, Double($0) * 0.3, Double($0) * 0.3 + 0.25) }
        let model = TextFollowModel()
        model.apply(.ready(TextSyncDocument(map: Self.map(sentences)), isStale: false, isOffline: false))
        model.update(time: 3.0, rate: 1, isPlaying: true)
        let jumps = model.jumpRequest
        #expect(model.currentSentence == 10)
        try await Task.sleep(for: .seconds(1.6))
        // Bez tyknięć: najwyżej ok. 0,6 s naprzód (zdanie 12), nie 1,5 s (zdanie 15).
        #expect((model.currentSentence ?? 0) <= 12, "\(String(describing: model.currentSentence))")
        model.update(time: 3.1, rate: 1, isPlaying: true)
        #expect(model.jumpRequest == jumps)
        #expect((model.currentSentence ?? 0) >= 10)
    }

    @Test func staleness() throws {
        let item = try JSONDecoder().decode(AudiobookshelfClient.ItemDetail.self, from: Data("""
        {"id":"li1","libraryId":"l","mediaType":"book","media":{"metadata":{"title":"T"},
         "tracks":[{"index":1,"ino":"1","metadata":{"filename":"a.m4b","size":100}}],
         "ebookFile":{"ino":"2","ebookFormat":"epub","metadata":{"filename":"a.epub","size":50}}},
         "libraryFiles":[{"ino":"9","metadata":{"filename":"a.sync.json","size":10,"mtimeMs":1700000000000}},
                         {"ino":"2","metadata":{"filename":"a.epub","size":50}}]}
        """.utf8))
        #expect(!Self.sample.isStale(for: item))
        #expect(TextSyncMap.file(in: item)?.ino == "9")
        #expect(TextSyncCache.key(TextSyncMap.file(in: item)!) == "9-10-1700000000000")
        var changed = Self.sample
        changed.audio[0].size = 101
        #expect(changed.isStale(for: item))
        #expect(TextSyncMap.unavailableReason(item) == .notSynced)
    }
}
