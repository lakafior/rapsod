// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import AudiobookshelfKit

@Suite struct EbookAudioSyncTests {
    typealias T = TextSyncDocumentTests
    static let map = T.map([
        T.sentence("ROZDZIAŁ I", href: "OEBPS/ch1.xhtml", block: 0, 0, 1),
        T.sentence("— Wiesz, Nel — mówił Staś Tarkowski do swojej przyjaciółki.", href: "OEBPS/ch1.xhtml", block: 1, 1, 5),
        T.sentence("— Dlaczego?", href: "OEBPS/ch1.xhtml", block: 2, 5, 6),
        T.sentence("Staś, który kończył rok czternasty, rzekł z miną wielce zarozumiałą:", href: "OEBPS/ch1.xhtml", block: 3, 6, 10),
        T.sentence("— Dlaczego?", href: "OEBPS/ch1.xhtml", block: 4, 10, 11),
        T.sentence("[1] Przypis bez czasu.", href: "OEBPS/ch1.xhtml", block: 5, nil, nil),
        T.sentence("ROZDZIAŁ II", href: "OEBPS/ch2.xhtml", block: 0, 20, 21),
        T.sentence("Obaj inżynierowie wyjechali nazajutrz na noc do Kairu.", href: "OEBPS/ch2.xhtml", block: 1, 21, 25),
    ])

    @Test func normalizationAndChapters() {
        #expect(EbookAudioSync.normalized("Ala  ma\u{00AD}\nKota.") == "alamakota.")
        #expect(EbookAudioSync.sameChapter("OEBPS/ch1.xhtml", "ch1.xhtml"))
        #expect(EbookAudioSync.sameChapter("OEBPS/Text/ch%201.xhtml", "Text/ch 1.xhtml#x"))
        #expect(!EbookAudioSync.sameChapter("OEBPS/ch1.xhtml", "ch11.xhtml"))
    }

    @Test func pageToTime() {
        let map = Self.map
        // Strona od początku rozdziału — nagłówek i akapit sklejone bez spacji (granica bloków w DOM).
        #expect(EbookAudioSync.time(in: map, href: "ch1.xhtml", passage: "ROZDZIAŁ I— Wiesz, Nel — mówił") == 0)
        // Strona zaczyna się w środku zdania → początek tego zdania.
        #expect(EbookAudioSync.sentence(in: map, href: "ch1.xhtml", passage: "Tarkowski do swojej przyjaciółki.— Dlaczego?Staś") == 1)
        // Krótka końcówka zdania na górze strony → zdanie, które kończy.
        #expect(EbookAudioSync.sentence(in: map, href: "ch1.xhtml", passage: "łki.— Dlaczego?Staś, który kończył rok czternasty") == 1)
        // Zdanie bez czasu (przypis) → następne zdanie z czasem.
        #expect(EbookAudioSync.time(in: map, href: "ch1.xhtml", passage: "[1] Przypis bez czasu.") == 20)
        #expect(EbookAudioSync.startTime(in: map, from: 5) == 20)
        // Inny rozdział, inne wydanie, za mało tekstu.
        #expect(EbookAudioSync.time(in: map, href: "OEBPS/ch2.xhtml", passage: "Obaj inżynierowie wyjechali nazajutrz") == 21)
        #expect(EbookAudioSync.sentence(in: map, href: "ch1.xhtml", passage: "Zupełnie inny tekst tej strony, którego nie ma w mapie.") == nil)
        #expect(EbookAudioSync.sentence(in: map, href: "ch9.xhtml", passage: "— Wiesz, Nel — mówił Staś") == nil)
        #expect(EbookAudioSync.sentence(in: map, href: "ch1.xhtml", passage: "  ") == nil)
    }

    @Test func timeToPassage() throws {
        let map = Self.map
        let first = try #require(EbookAudioSync.passage(in: map, time: 3))
        #expect(first.href == "OEBPS/ch1.xhtml" && first.sentence == 1 && first.occurrence == 0)
        #expect(first.key == String(EbookAudioSync.normalized("— Wiesz, Nel — mówił Staś Tarkowski do swojej przyjaciółki.").prefix(40)))
        // Drugie „— Dlaczego?” w rozdziale — drugie wystąpienie klucza.
        let second = try #require(EbookAudioSync.passage(in: map, time: 10.5))
        #expect(second.sentence == 4 && second.occurrence == 1)
        // Przed pierwszym zdaniem z czasem — pierwsze zdanie; w luce — ostatnie przed nią.
        #expect(EbookAudioSync.passage(in: map, time: -1)?.sentence == 0)
        #expect(EbookAudioSync.passage(in: map, time: 15)?.sentence == 4)
        #expect(EbookAudioSync.passage(in: map, time: 22)?.href == "OEBPS/ch2.xhtml")
    }
}
