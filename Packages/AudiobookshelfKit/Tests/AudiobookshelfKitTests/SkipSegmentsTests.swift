// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import AudiobookshelfKit

/// Nagłówki `x-megaphone-payload-2` zaobserwowane 2026-11-23 (publiczne odcinki).
enum MegaphoneFixtures {
    /// Today, Explained — sloty wypełnione (2× pre, 4× mid, 1× post), plik 39 966 655 B, 160 kb/s.
    static let filled = "8d7ede3e-d47d-11f1-8518-2316a70fe876#942327#pre#1#17593#d393f648-d47d-11f1-a448-73a3e2761c86#false#false,bd6ce3e8-df95-11f1-9d92-f3a9d04f71d0#1538964#pre#2#942328#bd6de1b2-df95-11f1-9d92-c7a5e925b5e7#false#false,5b66b68e-a303-11f1-b71c-13478378148c#12322311#mid#1#11079406#5b6abce8-a303-11f1-b71c-8384f5983379#false#false,5117ee5e-cbd6-11f1-b396-1f1da652f2bc#13611193#mid#2#12322312#53652082-cbd6-11f1-bed5-db666e8be322#false#false,a6878352-ce2b-11f1-b4af-cf58b4ff8f99#26840123#mid#3#25361071#9ada5504-ce2e-11f1-a797-73162507ba52#false#false,f1e3a29a-d15f-11f1-ba5b-cfe39b884451#28096613#mid#4#26840124#f1e735c2-d15f-11f1-ba5b-735b68f702af#false#false,6aa59580-c756-11f1-9d76-3fd836964838#39966654#post#1#39047145#7fcac39a-c756-11f1-a29a-27b3cde789a9#false#false,#39966654#post#2#39966655###@657dab56-d05d-11f0-9f07-97ee8a114f5d#160000#17593"
    static let filledSize: Int64 = 39_966_655
    static let filledDuration = 1997.4531
    /// Kryminatorium 453 — punkty wstawienia bez reklam (pusty slot: ostatni bajt = pierwszy − 1).
    static let empty = "#24277#pre#1#24278###,#24277#pre#2#24278###,#12766180#mid#1#12766181###,#12766180#mid#2#12766181###,#31781651#mid#3#31781652###,#31781651#mid#4#31781652###,#46755457#mid#5#46755458###,#46755457#mid#6#46755458###,#77581201#mid#7#77581202###,#77581201#mid#8#77581202###,#95642053#mid#9#95642054###,#95642053#mid#10#95642054###,#113389018#post#1#113389019###,#113389018#post#2#113389019###@145c4b60-e33f-11f1-b9a8-c7384ae42bd4#128000#24278"
    /// Syntax — bez punktów wstawienia.
    static let none = "@14678690-dd33-11f1-b943-2b9148b63cb2#320000#276926"
}

@Suite("Megaphone")
struct MegaphoneTests {
    @Test func parsesFilledSlotsIntoBreaks() throws {
        let payload = try #require(MegaphonePayload.parse(MegaphoneFixtures.filled))
        #expect(payload.bitrate == 160_000)
        #expect(payload.audioStart == 17_593)
        #expect(payload.slots.count == 8)
        #expect(payload.filledSlotCount == 7)
        let breaks = payload.breaks
        #expect(breaks.count == 4)
        #expect(breaks.map(\.position) == [.pre, .mid, .mid, .post])
        #expect(abs(breaks[0].start - 0) < 0.01 && abs(breaks[0].end - 76.07) < 0.01)
        #expect(abs(breaks[1].start - 553.09) < 0.01 && abs(breaks[1].end - 679.68) < 0.01)
        #expect(abs(breaks[3].end - 1997.45) < 0.01)
        // Miejsce wstawienia na osi bez reklam: drugi blok po 76 s reklamy przed odcinkiem.
        #expect(abs(breaks[1].contentPosition - (553.09 - 76.07)) < 0.02)
        #expect(abs(payload.duration(totalSize: MegaphoneFixtures.filledSize) - MegaphoneFixtures.filledDuration) < 0.01)
    }

    @Test func emptySlotsAreNotAds() throws {
        let payload = try #require(MegaphonePayload.parse(MegaphoneFixtures.empty))
        #expect(payload.slots.count == 14)
        #expect(payload.filledSlotCount == 0)
        #expect(payload.breaks.isEmpty)
        // Ostatni punkt (po odcinku) wypada na końcu nagrania: 1:58:05.
        #expect(abs(payload.time(ofByte: 113_389_019) - 7085.3) < 0.1)
    }

    @Test func headerWithoutSlots() throws {
        let payload = try #require(MegaphonePayload.parse(MegaphoneFixtures.none))
        #expect(payload.slots.isEmpty)
        #expect(payload.bitrate == 320_000)
    }

    @Test func rejectsGarbage() {
        #expect(MegaphonePayload.parse("") == nil)
        #expect(MegaphonePayload.parse("abc") == nil)
        #expect(MegaphonePayload.parse("x#1#side#1#2@id#0#0") == nil)
    }

    @Test func describesOnlyTheSameFile() throws {
        let payload = try #require(MegaphonePayload.parse(MegaphoneFixtures.filled))
        let size = MegaphoneFixtures.filledSize
        let audio = size - 17_593
        #expect(payload.describes(totalSize: size, fileAudioBytes: audio, fileDuration: MegaphoneFixtures.filledDuration))
        // Serwer przepisał znaczniki ID3 (inny nagłówek, ~1 KB różnicy w audio) — nadal ten sam plik.
        #expect(payload.describes(totalSize: size, fileAudioBytes: audio + 1044, fileDuration: MegaphoneFixtures.filledDuration))
        // Ta sama odpowiedź, ale plik na dysku pobrany z innym zestawem reklam.
        #expect(!payload.describes(totalSize: size, fileAudioBytes: 39_047_145 - 17_593, fileDuration: 1951.5))
        // Bez rozmiaru pliku (strumień): długość musi się zgadzać.
        #expect(payload.describes(totalSize: size, fileAudioBytes: nil, fileDuration: 1997.1))
        #expect(!payload.describes(totalSize: size, fileAudioBytes: nil, fileDuration: 1990))
        #expect(SkipAudioFingerprint.id3Size(Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0x43, 0x39])) == 8643)
        #expect(MegaphonePayload.totalSize(contentRange: "bytes 0-0/39966655") == size)
    }
}

@Suite("Opis odcinka")
struct DescriptionMarkerTests {
    /// Skrót opisu Kryminatorium 453 (HTML jak w kanale).
    static let kryminatorium = "<p>[autopromocja] MOJA GRA DETEKTYWISTYCZNA – AKTA TAJEMNIC: https://akta.alt.pl/</p><p><br></p><p>Przez lata unikali schwytania.</p><p><br></p><p>ROZDZIAŁY0:00 – wstęp</p><p>1:45 – [autopromocja] Akta tajemnic</p><p>3:45– Bogdan Arnold (Władca much)</p><p>19:27 – Władysław Mazurkiewicz (elegancki morderca)</p><p>1:02:40 – Joachim Knychała (wampir z Bytomia)</p>"
    /// Skrót opisu Syntax 1055.
    static let syntax = "<ul><li><strong><a href=\"#t=00:00\">00:00</a></strong> Welcome to Syntax!</li><li><strong><a href=\"#t=01:42\">01:42</a></strong> GitHub’s Growth by the Numbers</li><li><strong><a href=\"#t=03:36\">03:36</a></strong> <a href=\"https://sentry.io/syntax/\">Brought to you by Sentry!</a></li><li><strong><a href=\"#t=04:00\">04:00</a></strong> GitHub’s Huge Infrastructure Update</li></ul>"

    @Test func kryminatoriumSelfPromoRange() throws {
        let text = try #require(HTMLText.plain(Self.kryminatorium))
        let found = DescriptionMarkers.find(in: text, duration: 7086)
        #expect(found.ranges.count == 1)
        let marker = try #require(found.ranges.first)
        #expect(marker.kind == .selfPromo)
        #expect(marker.start == 105 && marker.end == 225)
        #expect(marker.text.contains("Akta tajemnic"))
        // „[autopromocja]” na początku opisu (bez czasu) — tylko wzmianka.
        #expect(found.notices.isEmpty)
    }

    @Test func syntaxSponsor() throws {
        let text = try #require(HTMLText.plain(Self.syntax))
        let found = DescriptionMarkers.find(in: text, duration: 1882)
        #expect(found.ranges.map { [$0.start, $0.end] } == [[216, 240]])
        #expect(found.ranges.first?.kind == .sponsor)
    }

    @Test func untimedMentionsBecomeNotices() {
        let text = "Wywiad zrealizowany komercyjnie. Partnerem odcinka jest Komputronik dla Firm. Jak AI zmienia pracę handlowca?"
        let found = DescriptionMarkers.find(in: text, duration: 4000)
        #expect(found.ranges.isEmpty)
        #expect(found.notices.count == 1)
        #expect(found.notices.first?.kind == .sponsor)
        #expect(found.notices.first?.text.contains("Partnerem odcinka jest Komputronik dla Firm") == true)
        #expect(found.notices.first?.time == nil)
    }

    @Test func explicitRangeAndLastEntryWithoutEnd() {
        let text = "12:30 – 14:05 reklama: Firma X\n20:00 temat\n58:10 autopromocja: mój kurs"
        let found = DescriptionMarkers.find(in: text, duration: 3600)
        #expect(found.ranges.map { [$0.start, $0.end] } == [[750, 845]])
        // Ostatni wpis bez następnego czasu — koniec nieznany, więc wzmianka, nie segment.
        #expect(found.notices.map(\.time) == [3490])
        #expect(found.notices.first?.kind == .selfPromo)
    }

    @Test func ignoresTopicsAndClockTimes() {
        let text = "0:00 Intro\n5:00 Rozmowa o finansach\n10:00 Pytania\nNagrywamy co tydzień o 20:00."
        #expect(DescriptionMarkers.find(in: text, duration: 1800).ranges.isEmpty)
        // Tematy rozmowy — nie segmenty.
        for topic in ["Advertising in open source", "Downloads and uploads", "Wsparcie na Patronite", "Jak ustawić skuteczną reklamę Google Ads?",
                      "Wybór partnera logistycznego", "Jak przygotować skuteczną ofertę dla sponsora?", "What exactly is a “venture partner?”",
                      "Sponsorzy i pieniądze są ważniejsze, niż sport?", "Political advertising and Russian media manipulation"] {
            #expect(SponsorKeywords.kind(of: topic) == nil, "\(topic)")
        }
        // Nagłówki wstawek.
        for heading in ["Ads", "Sponsor: Sentry", "Sponsor odcinka", "BookBeat [partner odcinka]", "Partner odcinka - Polsat Box Go",
                        "Segment partnera", "Brought to you by Sentry!", "Sonos Sponsor Break", "Partnerzy odcinka", "Reklama",
                        "[współpraca reklamowa] Partnerem Imponderabiliów jest Trade Republic", "Support for this show comes from Drata"] {
            #expect(SponsorKeywords.kind(of: heading) == .sponsor, "\(heading)")
        }
        #expect(SponsorKeywords.kind(of: "1:45 – [autopromocja] Akta tajemnic") == .selfPromo)
    }

    @Test func timestamps() {
        #expect(DescriptionMarkers.seconds("1:02:40") == 3760)
        #expect(DescriptionMarkers.seconds("75:30") == 4530)
        #expect(DescriptionMarkers.seconds("1:75") == nil)
        #expect(DescriptionMarkers.stamps(in: "ROZDZIAŁY0:00 – wstęp").map(\.time) == [0])
        #expect(DescriptionMarkers.stamps(in: "wersja 1.2:30 i 3,4:00").isEmpty)
    }
}

@Suite("Wykrywanie")
struct SkipDetectionTests {
    @Test func megaphoneLocatesAdsAndShiftsDescription() throws {
        let payload = try #require(MegaphonePayload.parse(MegaphoneFixtures.filled))
        // Opis na osi wydawcy: reklama czytana 10:00–11:00.
        let input = SkipDetection.Input(description: "10:00 Sponsor: Firma\n11:00 Dalej", feedDuration: 1822,
                                        fileDuration: MegaphoneFixtures.filledDuration, fileSize: MegaphoneFixtures.filledSize,
                                        fileAudioBytes: MegaphoneFixtures.filledSize - 17_593, megaphone: payload, megaphoneTotalSize: MegaphoneFixtures.filledSize)
        let result = SkipDetection.analyze(input)
        #expect(result.insertedAds?.located == true)
        #expect(result.insertedAds?.slots == 7)
        let mega = result.segments.filter { $0.source == .megaphone }
        #expect(mega.count == 4)
        let described = try #require(result.segments.first { $0.source == .description })
        // Mid-roll #1 wstawiony w 477 s treści, więc 600 s treści przesuwa się o 76,07 + 126,59 s.
        #expect(abs(described.start - (600 + 76.07 + 126.59)) < 0.05)
        #expect(described.autoSkip)
    }

    @Test func megaphoneFromAnotherDownloadIsNotLocated() throws {
        let payload = try #require(MegaphonePayload.parse(MegaphoneFixtures.filled))
        let input = SkipDetection.Input(description: nil, fileDuration: 1951.5, fileSize: 39_047_145, fileAudioBytes: 39_047_145 - 17_593, megaphone: payload,
                                        megaphoneTotalSize: MegaphoneFixtures.filledSize)
        let result = SkipDetection.analyze(input)
        #expect(result.segments.isEmpty)
        #expect(result.insertedAds?.located == false)
    }

    @Test func durationDifferenceMarksInsertedAdsAndDisablesAutoSkip() {
        // Darknet Diaries 182: kanał 39:17, plik 2551 s.
        let input = SkipDetection.Input(description: "1:00 Sponsor: Drata\n2:00 Story", feedDuration: 2357, fileDuration: 2550.8)
        let result = SkipDetection.analyze(input)
        #expect(result.insertedAds == InsertedAds(source: .durationDifference, seconds: 2550.8 - 2357, located: false))
        #expect(result.segments.count == 1)
        #expect(result.segments.first?.autoSkip == false)
    }

    @Test func equalDurationsAreNotInsertion() {
        let input = SkipDetection.Input(description: nil, feedDuration: 7086, fileDuration: 7086.3)
        #expect(SkipDetection.analyze(input).insertedAds == nil)
    }

    @Test func chaptersWinOverDuplicateDescription() {
        let input = SkipDetection.Input(description: "1:45 – [autopromocja] Akta\n3:45 – Sprawa",
                                        chapters: [.init(start: 0, end: 105, title: "Wstęp"), .init(start: 105, end: 222, title: "Autopromocja"),
                                                   .init(start: 222, end: 3000, title: "Sprawa")],
                                        fileDuration: 3000)
        let result = SkipDetection.analyze(input)
        #expect(result.segments.count == 1)
        #expect(result.segments.first?.source == .chapters)
        #expect(result.segments.first?.end == 222)
        #expect(Set(result.runs.map(\.source)) == [.chapters, .description])
    }
}

@Suite("Plik znaczników")
struct SkipMapTests {
    static let audio = SkipAudioFingerprint(filename: "odc.mp3", size: 1000, duration: 600, headSHA256: "aa", tailSHA256: "bb")

    static func map() -> SkipMap {
        SkipMap(episode: .init(itemID: "li", episodeID: "ep"), audio: audio, segments: [
            SkipSegment(id: "d1", start: 100, end: 160, kind: .sponsor, source: .description, confidence: 0.85),
            SkipSegment(id: "m1", start: 0, end: 30, kind: .sponsor, source: .megaphone, confidence: 0.95),
        ], runs: [SkipRun(source: .description), SkipRun(source: .megaphone)])
    }

    @Test func roundTripAndUnknownValues() throws {
        var map = Self.map()
        map.add(start: 300, end: 320, kind: .selfPromo)
        let data = try map.encoded()
        // Daty w pliku mają dokładność sekundy — porównanie po ponownym zapisie.
        #expect(try SkipMap.decode(data).encoded() == data)
        #expect(try SkipMap.decode(data).effectiveSegments == map.effectiveSegments)
        #expect(SkipMap.fileName(forAudio: "Odcinek 12.mp3") == "Odcinek 12.skip.json")

        // Nowsza wersja dopisuje rodzaj i źródło, których ta nie zna; uszkodzony segment wypada.
        let json = """
        {"format":"abswift-skip","version":1,"audio":{"duration":600},
         "segments":[{"id":"x","start":10,"end":20,"kind":"intro","source":"model","confidence":0.7},
                     {"id":"bad","start":30,"end":20,"kind":"sponsor","source":"model","confidence":1},
                     {"start":40,"end":50}],
         "corrections":{"added":[],"removed":[]},"runs":[{"source":"model","date":"2026-11-23T10:00:00Z","detail":"mistral-small"}]}
        """
        let decoded = try SkipMap.decode(Data(json.utf8))
        #expect(decoded.segments.count == 2)
        #expect(decoded.segments[0].kind.rawValue == "intro")
        #expect(decoded.segments[0].source == .model)
        #expect(decoded.runs.first?.detail == "mistral-small")
        #expect(throws: SkipMap.Damaged.self) { try SkipMap.decode(Data(#"{"format":"abswift-skip","version":99,"audio":{"duration":1}}"#.utf8)) }
        #expect(throws: SkipMap.Damaged.self) { try SkipMap.decode(Data("[]".utf8)) }
    }

    @Test func correctionsSurviveNewDetection() {
        var map = Self.map()
        map.remove(map.segments[0]) // „to nie reklama”
        let mega = map.segments[1]
        map.adjust(mega, start: 0, end: 28)
        #expect(map.effectiveSegments.map { [$0.start, $0.end] } == [[0, 28]])
        #expect(map.effectiveSegments.first?.source == .user)

        // Ponowne wykrywanie z opisu z innymi granicami i nowe źródło z 13b.
        let result = SkipDetection.Result(segments: [SkipSegment(start: 98, end: 161, kind: .sponsor, source: .description, confidence: 0.85)],
                                          insertedAds: nil, notices: [], runs: [SkipRun(source: .description)])
        var redone = SkipDetection.map(result: result, episode: map.episode, audio: map.audio, previous: map)
        #expect(redone.effectiveSegments.map { [$0.start, $0.end] } == [[0, 28]])
        // Megaphone nie liczył tym razem — jego segmenty zostają (odrzucone i tak przez poprawkę).
        #expect(redone.segments.contains { $0.source == .megaphone })
        redone = redone.replacingSegments(from: .model, with: [SkipSegment(start: 400, end: 430, kind: .selfPromo, source: .model, confidence: 0.7)])
        #expect(redone.effectiveSegments.count == 2)
        #expect(redone.segments.filter { $0.source == .description }.count == 1)
    }

    @Test func removingUserSegmentDeletesIt() {
        var map = Self.map()
        let added = map.add(start: 500, end: 520, kind: .sponsor)
        map.remove(added)
        #expect(map.corrections.isEmpty)
    }

    @Test func fingerprintMatching() {
        let reference = Self.audio
        #expect(reference.match(reference) == .exact)
        #expect(reference.match(SkipAudioFingerprint(duration: 600.6)) == .duration)
        #expect(!reference.match(SkipAudioFingerprint(duration: 602)).allowsSkipping)
        #expect(!reference.match(SkipAudioFingerprint(size: 999, duration: 600)).allowsSkipping)
        #expect(!reference.match(SkipAudioFingerprint(duration: 600, headSHA256: "zz")).allowsSkipping)
    }

    @Test func fingerprintOfFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "skip-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((0..<200_000).map { UInt8($0 % 251) }).write(to: url)
        let a = try SkipAudioFingerprint.of(fileAt: url, duration: 12)
        #expect(a.size == 200_000)
        #expect(a.headSHA256 != a.tailSHA256)
        #expect(a.match(try SkipAudioFingerprint.of(fileAt: url, duration: 12.4)) == .exact)
    }
}

@Suite("Plan pomijania")
struct SkipPlanTests {
    static func plan(_ entries: [(Double, Double, SkipAction)], duration: Double = 1000) -> SkipPlan {
        SkipPlan(entries: entries.enumerated().map { index, entry in
            SkipPlan.Entry(id: "s\(index)", start: entry.0, end: entry.1, kind: .sponsor, source: .description, action: entry.2)
        }, duration: duration)
    }

    @Test func crossingStartSkipsEvenAtTripleSpeed() {
        let plan = Self.plan([(100, 160, .skip)])
        // Zegar co 0,5 s przy 3× — poprzedni odczyt 1,4 s przed segmentem, bieżący 0,1 s w środku.
        let decision = plan.decide(from: 98.6, to: 100.1, suppressed: [])
        #expect(decision?.target == 160)
        #expect(decision?.entry.id == "s0")
        // Normalny krok tuż przed początkiem i przy samym początku (granica obserwatora).
        #expect(plan.decide(from: 99.6, to: 99.9, suppressed: []) != nil)
        #expect(plan.decide(from: 99.0, to: 99.4, suppressed: []) == nil)
    }

    @Test func seekIntoMiddleDoesNotSkip() {
        let plan = Self.plan([(100, 160, .skip)])
        // Po przewinięciu poprzednia pozycja = cel przewinięcia.
        #expect(plan.decide(from: 120, to: 120.5, suppressed: []) == nil)
        // Przewinięcie dokładnie na początek (początek rozdziału) — pomija.
        #expect(plan.decide(from: 100, to: 100, suppressed: []) != nil)
        // Przewinięcie wstecz nie jest przejściem.
        #expect(plan.decide(from: 200, to: 101, suppressed: []) == nil)
    }

    @Test func undoSuppressesUntilLeaving() {
        let plan = Self.plan([(100, 160, .skip)])
        var suppressed: Set<String> = ["s0"]
        #expect(plan.decide(from: 100, to: 100.5, suppressed: suppressed) == nil)
        suppressed = plan.stillSuppressed(suppressed, at: 130)
        #expect(suppressed == ["s0"])
        suppressed = plan.stillSuppressed(suppressed, at: 161)
        #expect(suppressed.isEmpty)
        // −15 s z 170 s: znowu przed segmentem — następne przejście pomija.
        suppressed = plan.stillSuppressed(["s0"], at: 80)
        #expect(plan.decide(from: 99.8, to: 100.3, suppressed: suppressed) != nil)
    }

    @Test func adjacentSegmentsChain() {
        let plan = Self.plan([(0, 46, .skip), (46.2, 76, .skip), (76, 90, .show), (300, 320, .skip)])
        let decision = plan.decide(from: 0, to: 0, suppressed: [])
        #expect(decision?.target == 76)
        #expect(decision?.skippedIDs == ["s0", "s1"])
    }

    @Test func showOnlyAndTailAreNotSkipped() {
        let plan = Self.plan([(100, 160, .show), (200, 201, .skip)])
        #expect(plan.decide(from: 99.8, to: 100.2, suppressed: []) == nil)
        #expect(plan.entry(at: 120)?.action == .show)
        // Segment krótszy niż margines końca — przejście w jego końcówce nic nie daje.
        #expect(plan.decide(from: 200.3, to: 200.4, suppressed: []) == nil)
    }

    @Test func segmentToEndOfFileTargetsDuration() {
        let plan = Self.plan([(950, 1010, .skip)], duration: 1000)
        #expect(plan.decide(from: 949.8, to: 950.2, suppressed: [])?.target == 1000)
    }

    @Test func planFromMapRespectsSettingsAndFile() {
        var map = SkipMapTests.map()
        map.segments.append(SkipSegment(id: "p", start: 400, end: 420, kind: .selfPromo, source: .description, confidence: 0.85))
        map.segments.append(SkipSegment(id: "u", start: 500, end: 520, kind: .sponsor, source: .description, confidence: 0.5, autoSkip: false))
        let actual = SkipMapTests.audio
        let all = SkipPlan(map: map, actual: actual, settings: .standard)
        #expect(all.entries.map(\.id) == ["m1", "d1", "p", "u"])
        #expect(all.entries.first { $0.id == "u" }?.action == .show)

        let promoShown = SkipPlan(map: map, actual: actual, settings: SkipSettings(selfPromo: .show))
        #expect(promoShown.entries.first { $0.id == "p" }?.action == .show)
        let sponsorsIgnored = SkipPlan(map: map, actual: actual, settings: SkipSettings(sponsor: .ignore))
        #expect(sponsorsIgnored.entries.map(\.id) == ["p"])
        #expect(SkipPlan(map: map, actual: actual, settings: SkipSettings(enabled: false)).isEmpty)

        let other = SkipPlan(map: map, actual: SkipAudioFingerprint(size: 2000, duration: 640), settings: .standard)
        #expect(other.isEmpty)
        #expect(other.mismatch != nil)
    }

    @Test func settingsStore() {
        let suite = "skip-tests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = SkipSettingsStore(suiteName: suite)
        #expect(store.settings(podcastID: "p1") == .standard)
        store.set(SkipSettings(enabled: true, sponsor: .skip, selfPromo: .show), podcastID: "p1")
        #expect(store.settings(podcastID: "p1").selfPromo == .show)
        #expect(store.settings(podcastID: "p2") == .standard)
        store.set(.standard, podcastID: "p1")
        #expect(store.settings(podcastID: "p1") == .standard)
    }
}

@Suite("Źródła znaczników")
struct SkipSourcesTests {
    @Test func feedChapters() throws {
        let xml = """
        <rss version="2.0" xmlns:psc="http://podlove.org/simple-chapters" xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel><title>P</title>
        <item><title>O1</title><enclosure url="https://x.invalid/1.mp3" type="audio/mpeg"/>
        <psc:chapters version="1.2"><psc:chapter start="00:00:00.000" title="Wstęp"/><psc:chapter start="00:01:45" title="Autopromocja"/><psc:chapter start="00:03:45.500" title="Sprawa"/></psc:chapters>
        <podcast:chapters url="https://x.invalid/1.json" type="application/json+chapters"/></item>
        </channel></rss>
        """
        let episode = try #require(RSSFeedParser.parse(Data(xml.utf8)).episodes.first)
        #expect(episode.chapters?.map(\.start) == [0, 105, 225.5])
        #expect(episode.chaptersURL?.absoluteString == "https://x.invalid/1.json")
        let ranges = RSSChapter.ranges(episode.chapters ?? [], duration: 600)
        #expect(ranges.map(\.end) == [105, 225.5, 600])

        let json = #"{"version":"1.2.0","chapters":[{"startTime":0,"title":"Intro"},{"startTime":60,"title":"Sponsor: X","toc":false,"endTime":90},{"startTime":120,"title":"Main"}]}"#
        let parsed = RSSChapter.parseJSON(Data(json.utf8), duration: 600)
        #expect(parsed.map { [$0.start, $0.end] } == [[0, 60], [60, 90], [120, 600]])
        let result = SkipDetection.analyze(.init(description: nil, chapters: parsed, fileDuration: 600))
        #expect(result.segments.map { [$0.start, $0.end] } == [[60, 90]])
    }

    @Test func locatesSkipFileNextToEpisode() throws {
        let json = """
        {"id":"li","libraryId":"lib","mediaType":"podcast","path":"/p/Pod",
         "media":{"metadata":{"title":"Pod"},"episodes":[{"id":"ep1","title":"O1","audioFile":{"ino":"11","duration":600,"metadata":{"filename":"o1.mp3","path":"/p/Pod/o1.mp3","size":1000}}}]},
         "libraryFiles":[{"ino":"11","metadata":{"filename":"o1.mp3","path":"/p/Pod/o1.mp3","size":1000},"fileType":"audio"},
                         {"ino":"12","metadata":{"filename":"o1.skip.json","path":"/p/Pod/inny/o1.skip.json","size":10},"fileType":"metadata"},
                         {"ino":"13","metadata":{"filename":"o1.skip.json","path":"/p/Pod/o1.skip.json","size":10},"fileType":"metadata"}]}
        """
        let item = try JSONDecoder().decode(AudiobookshelfClient.ItemDetail.self, from: Data(json.utf8))
        let located = try #require(SkipMapLoader.locate(episodeID: "ep1", in: item))
        #expect(located.skipFile?.ino == "13")
        #expect(located.audioSize == 1000)
        #expect(SkipMapLoader.locate(episodeID: "nie-ma", in: item) == nil)
    }

    @Test func phoneCorrectionsMerge() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "skipfix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SkipCorrectionsStore(directory: directory)
        var phone = SkipMapTests.map()
        phone.remove(phone.segments[0])
        try store.save(phone, key: "li#ep")
        #expect(store.corrections(key: "li#ep", audio: SkipMapTests.audio)?.removed.count == 1)
        // Inny plik — poprawki nie pasują.
        #expect(store.corrections(key: "li#ep", audio: SkipAudioFingerprint(size: 5, duration: 600)) == nil)

        var server = SkipMapTests.map()
        server.add(start: 300, end: 330, kind: .sponsor)
        let merged = SkipCorrectionsStore.merged(server, with: store.corrections(key: "li#ep", audio: SkipMapTests.audio))
        #expect(merged.effectiveSegments.map(\.start) == [0, 300])
    }
}
