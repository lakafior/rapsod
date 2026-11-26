// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
import RapsodIntegration

/// Powiadomienia i Skróty aplikacji na Maca (etap 14e).
@Suite struct NotificationPreferencesTests {
    @Test func defaultsAreOffUntilEnabled() {
        let prefs = NotificationPreferences()
        #expect(!prefs.isEnabled)
        #expect(prefs.isOn(.libraryScan) && prefs.isOn(.newEpisodes) && prefs.isOn(.uploads) && prefs.isOn(.appUpdate))
        #expect(!prefs.isOn(.sponsorSegments))
        #expect(!prefs.wants(.libraryScan))
        #expect(!prefs.needsServerEvents)
    }

    @Test func roundTripsThroughStore() {
        var prefs = NotificationPreferences(isEnabled: true)
        prefs.set(.newEpisodes, false)
        prefs.set(.sponsorSegments, true)
        let stored = prefs.stored
        let read = NotificationPreferences(read: { stored[$0] })
        #expect(read == prefs)
        #expect(read.wants(.sponsorSegments))
        #expect(!read.wants(.newEpisodes))
        #expect(Set(stored.keys).isSubset(of: Set(NotificationPreferences.allKeys)))
    }

    @Test func serverEventsOnlyForServerKinds() {
        var prefs = NotificationPreferences(isEnabled: true)
        for kind in NotificationKind.allCases { prefs.set(kind, false) }
        prefs.set(.appUpdate, true)
        prefs.set(.sponsorSegments, true)
        #expect(!prefs.needsServerEvents)
        prefs.set(.uploads, true)
        #expect(prefs.needsServerEvents)
    }

    @Test func categoriesRoundTrip() {
        for kind in NotificationKind.allCases {
            #expect(NotificationKind(categoryIdentifier: kind.categoryIdentifier) == kind)
        }
        #expect(NotificationKind(categoryIdentifier: "other.libraryScan") == nil)
        #expect(NotificationAction.actions(for: .appUpdate) == [.install])
        #expect(NotificationAction.actions(for: .libraryScan).isEmpty)
    }
}

@Suite struct NotificationTextTests {
    @Test func polishPlurals() {
        let forms = [0, 1, 2, 4, 5, 11, 12, 14, 21, 22, 25, 102, 112, 1000].map {
            PolishPlural.form($0, one: "odcinek", few: "odcinki", many: "odcinków")
        }
        #expect(forms == ["odcinków", "odcinek", "odcinki", "odcinki", "odcinków", "odcinków", "odcinków", "odcinków",
                          "odcinków", "odcinki", "odcinków", "odcinki", "odcinków", "odcinków"])
    }

    @Test func scanSummary() {
        #expect(NotificationTexts.scanSummary(ScanCounts(added: 3, updated: 1, missing: 2)) == "Dodano 3 pozycje, zmieniono 1, brakuje 2.")
        #expect(NotificationTexts.scanSummary(ScanCounts(added: 1, updated: nil, missing: nil)) == "Dodano 1 pozycję.")
        #expect(NotificationTexts.scanSummary(ScanCounts(added: 0, updated: 5, missing: 0)) == "Zmieniono 5 pozycji.")
        #expect(NotificationTexts.scanSummary(ScanCounts(added: nil, updated: nil, missing: 1)) == "Brakuje 1 pozycji.")
        #expect(NotificationTexts.scanSummary(ScanCounts(added: 0, updated: 0, missing: 0)) == "Bez zmian.")
    }

    @Test func scanNotificationIsStablePerLibrary() throws {
        let first = try #require(NotificationTexts.scan(libraryID: "lib1", libraryName: "Książki",
                                                         outcome: .finished(nil, canceled: false), requestedHere: true))
        let later = try #require(NotificationTexts.scan(libraryID: "lib1", libraryName: "Książki",
                                                         outcome: .finished(ScanCounts(added: 2, updated: 0, missing: 0), canceled: false),
                                                         requestedHere: true))
        // Późniejszy wynik tego samego skanu zastępuje wcześniejsze powiadomienie.
        #expect(first.identifier == later.identifier)
        #expect(later.body == "Dodano 2 pozycje.")
        #expect(later.subtitle == "Książki")
        #expect(later.route == .librarySettings(libraryID: "lib1"))
        #expect(later.threadIdentifier == "library-lib1")
    }

    @Test func episodesBodyListsTitles() {
        let one = NotificationTexts.episodes(EpisodeBatch(itemID: "p1", libraryID: "L", podcastTitle: "Podcast",
                                                         episodes: [episode("d1", "Odcinek 1")]))
        #expect(one.title == "Nowy odcinek")
        #expect(one.body == "Odcinek 1")
        #expect(one.subtitle == "Podcast")
        let many = NotificationTexts.episodes(EpisodeBatch(itemID: "p1", libraryID: "L", podcastTitle: "Podcast",
                                                          episodes: (1...5).map { episode("d\($0)", "O\($0)") }))
        #expect(many.title == "Nowe odcinki")
        #expect(many.body == "5 nowych odcinków: O1, O2, O3…")
        #expect(many.route == .episode(itemID: "p1", libraryID: "L", episodeID: nil, guid: "g-d5", title: "O5"))
        #expect(many.threadIdentifier == "podcast-p1")
    }

    @Test func uploadTexts() {
        #expect(NotificationTexts.upload(libraryID: "L", libraryName: "B", uploadedTitles: [], failures: 0) == nil)
        #expect(NotificationTexts.upload(libraryID: "L", libraryName: "B", uploadedTitles: ["Lalka"], failures: 0)?.body == "Wgrano „Lalka”.")
        #expect(NotificationTexts.upload(libraryID: "L", libraryName: "B", uploadedTitles: ["a", "b", "c"], failures: 1)?.body
            == "Wgrano 3 książki. Jednej nie udało się wgrać.")
        let failed = NotificationTexts.upload(libraryID: "L", libraryName: "B", uploadedTitles: [], failures: 2)
        #expect(failed?.title == "Wgrywanie nie powiodło się")
        #expect(failed?.body == "Nie udało się wgrać 2 książek.")
        #expect(NotificationTexts.upload(libraryID: "L", libraryName: "B", uploadedTitles: Array(repeating: "x", count: 5), failures: 0)?.body
            == "Wgrano 5 książek.")
    }

    @Test func mergeAndUpdateAndSponsor() {
        let ok = NotificationTexts.merge(itemID: "i", libraryID: "L", itemTitle: "Lalka", failure: nil)
        #expect(ok.title == "Scalono do M4B" && ok.kind == .uploads && ok.route == .item(itemID: "i", libraryID: "L"))
        let bad = NotificationTexts.merge(itemID: "i", libraryID: nil, itemTitle: nil, failure: "ffmpeg nie scalił plików audio.")
        #expect(bad.title == "Scalanie do M4B nie powiodło się" && bad.body == "ffmpeg nie scalił plików audio.")
        let update = NotificationTexts.update(version: "1.2.0", title: "")
        #expect(update.subtitle == "Rapsod 1.2.0" && update.route == .update(version: "1.2.0"))
        let sponsor = NotificationTexts.sponsorSegments(itemID: "p", libraryID: "L", episodeID: "e", podcastTitle: "Pod",
                                                        episodeTitle: "Ep", count: 2)
        #expect(sponsor.title == "Wykryto 2 segmenty sponsorowane")
        #expect(sponsor.identifier == "sponsor-p-e")
    }

    @Test func routeSurvivesUserInfo() {
        let routes: [NotificationRoute] = [
            .item(itemID: "a", libraryID: nil),
            .episode(itemID: "p", libraryID: "L", episodeID: nil, guid: "g", title: "Tytuł „z” cudzysłowem"),
            .librarySettings(libraryID: "L"),
            .library(libraryID: nil),
            .update(version: "1.0"),
        ]
        for route in routes {
            #expect(NotificationRoute(userInfoValue: route.userInfoValue) == route)
        }
        #expect(NotificationRoute(userInfoValue: "nie json") == nil)
        #expect(NotificationRoute(userInfoValue: 5) == nil)
    }

    private func episode(_ id: String, _ title: String) -> DownloadedEpisode {
        DownloadedEpisode(downloadID: id, itemID: "p1", libraryID: "L", podcastTitle: "Podcast", title: title, guid: "g-\(id)")
    }
}

@Suite struct NotificationPolicyTests {
    @Test func scanPolicy() {
        let changes = ScanCounts(added: 1, updated: 0, missing: 0)
        let none = ScanCounts(added: 0, updated: 0, missing: 0)
        #expect(ScanNotificationPolicy.shouldNotify(.finished(changes, canceled: false), requestedHere: false))
        #expect(!ScanNotificationPolicy.shouldNotify(.finished(none, canceled: false), requestedHere: false))
        #expect(!ScanNotificationPolicy.shouldNotify(.finished(nil, canceled: false), requestedHere: false))
        #expect(ScanNotificationPolicy.shouldNotify(.finished(none, canceled: false), requestedHere: true))
        #expect(!ScanNotificationPolicy.shouldNotify(.finished(changes, canceled: true), requestedHere: true))
        #expect(ScanNotificationPolicy.shouldNotify(.failed("x"), requestedHere: false))
    }

    @Test func batcherGroupsPerPodcastAndWaitsForQuiet() {
        var batcher = EpisodeBatcher(quiet: 8)
        let t0 = Date(timeIntervalSince1970: 1000)
        let r1 = batcher.add(ep("d1", "p1"), at: t0)
        #expect(r1)
        let r2 = batcher.add(ep("d2", "p1"), at: t0.addingTimeInterval(5))
        #expect(r2)
        let r3 = batcher.add(ep("d3", "p2"), at: t0.addingTimeInterval(6))
        #expect(r3)
        // Powtórka tego samego zdarzenia (dwa gniazda) nie liczy się drugi raz.
        let r4 = batcher.add(ep("d2", "p1"), at: t0.addingTimeInterval(7))
        #expect(!r4)
        let none = batcher.drain(now: t0.addingTimeInterval(10))
        #expect(none.isEmpty)
        #expect(batcher.nextDeadline == t0.addingTimeInterval(13))
        let first = batcher.drain(now: t0.addingTimeInterval(13))
        #expect(first.map(\.itemID) == ["p1"])
        #expect(first.first?.episodes.map(\.downloadID) == ["d1", "d2"])
        let second = batcher.drain(now: t0.addingTimeInterval(14))
        #expect(second.map(\.itemID) == ["p2"])
        #expect(batcher.isEmpty)
        #expect(batcher.nextDeadline == nil)
        // Po wysłaniu partii ten sam odcinek nie wraca.
        let r5 = batcher.add(ep("d1", "p1"), at: t0.addingTimeInterval(20))
        #expect(!r5)
    }

    @Test func sponsorGateOncePerEpisode() {
        var gate = SponsorNotificationGate()
        let r6 = gate.shouldNotify(key: "p/e", segments: 0, automatic: true)
        #expect(!r6)
        let r7 = gate.shouldNotify(key: "p/e", segments: 2, automatic: false)
        #expect(!r7)
        let r8 = gate.shouldNotify(key: "p/e", segments: 2, automatic: true)
        #expect(r8)
        // Drugi przebieg (model) tego samego odcinka.
        let r9 = gate.shouldNotify(key: "p/e", segments: 3, automatic: true)
        #expect(!r9)
        let r10 = gate.shouldNotify(key: "p/f", segments: 1, automatic: true)
        #expect(r10)
    }

    @Test func presentationSkipsRelevantKeyWindow() {
        let windows: [NotificationKind: Set<String>] = [.libraryScan: ["settings"], .uploads: ["library"]]
        #expect(!NotificationPresentation.shouldShow(kind: .libraryScan, appIsActive: true, keyWindowID: "settings", relevantWindows: windows))
        #expect(NotificationPresentation.shouldShow(kind: .libraryScan, appIsActive: false, keyWindowID: "settings", relevantWindows: windows))
        #expect(NotificationPresentation.shouldShow(kind: .libraryScan, appIsActive: true, keyWindowID: "library", relevantWindows: windows))
        #expect(NotificationPresentation.shouldShow(kind: .appUpdate, appIsActive: true, keyWindowID: "settings", relevantWindows: windows))
        #expect(NotificationPresentation.shouldShow(kind: .uploads, appIsActive: true, keyWindowID: nil, relevantWindows: windows))
    }

    private func ep(_ id: String, _ item: String) -> DownloadedEpisode {
        DownloadedEpisode(downloadID: id, itemID: item, libraryID: nil, podcastTitle: nil, title: id, guid: nil)
    }
}

@Suite struct ShortcutsSupportTests {
    typealias C = MediaSearchRanking.Candidate

    @Test func ranksTitleMatchesFirst() {
        let candidates = [
            C(id: "narrator", title: "Coś innego", author: "Ktoś"),
            C(id: "author", title: "Inna", author: "Bolesław Prus"),
            C(id: "contains", title: "Ostatnia Lalka", author: nil),
            C(id: "word", title: "Wielka lalkarnia", author: nil),
            C(id: "prefix", title: "Lalka. Tom 2", author: nil),
            C(id: "exact", title: "Lalka", author: "Prus"),
            C(id: "exact", title: "Lalka (duplikat)", author: nil),
        ]
        #expect(MediaSearchRanking.rank(candidates, query: " lalka ").map(\.id) == ["exact", "prefix", "contains", "word", "narrator", "author"])
        #expect(MediaSearchRanking.rank(candidates, query: "prus").map(\.id).prefix(2) == ["author", "exact"])
    }

    @Test func normalizesPolishLetters() {
        #expect(MediaSearchRanking.normalize("  ŁÓDŹ Żółć ") == "lodz zolc")
        let ranked = MediaSearchRanking.rank([C(id: "b", title: "Inny", author: nil), C(id: "a", title: "Łąka", author: nil)], query: "laka")
        #expect(ranked.first?.id == "a")
        #expect(MediaSearchRanking.rank([C(id: "b", title: "B", author: nil), C(id: "a", title: "A", author: nil)], query: "").map(\.id) == ["b", "a"])
    }

    @Test func findsEpisodeByGuidThenTitle() {
        let episodes = [
            EpisodeLookup.Episode(id: "1", guid: "g1", title: "Pierwszy"),
            EpisodeLookup.Episode(id: "2", guid: nil, title: "Drugi"),
            EpisodeLookup.Episode(id: "3", guid: "g3", title: "drugi"),
        ]
        #expect(EpisodeLookup.find(in: episodes, guid: "g1", title: "Drugi") == "1")
        #expect(EpisodeLookup.find(in: episodes, guid: "brak", title: "DRUGI") == "3")
        #expect(EpisodeLookup.find(in: episodes, guid: nil, title: "Trzeci") == nil)
        #expect(EpisodeLookup.find(in: episodes, guid: "", title: nil) == nil)
    }

    @Test func skipIntervalClamps() {
        #expect(SkipInterval.seconds(nil, default: 30) == 30)
        #expect(SkipInterval.seconds(-5, default: 15) == 15)
        #expect(SkipInterval.seconds(.nan, default: 15) == 15)
        #expect(SkipInterval.seconds(0.2, default: 15) == 1)
        #expect(SkipInterval.seconds(90, default: 15) == 90)
        #expect(SkipInterval.seconds(99999, default: 15) == 3600)
    }

    @Test func readinessWaitStopsWhenSettledOrTimedOut() async {
        actor Counter { var n = 0; func next() -> Int { n += 1; return n } }
        let counter = Counter()
        let ready = await ReadinessWait.wait(limit: 5, step: 0.01) {
            await counter.next() >= 3 ? .ready : .starting
        }
        #expect(ready == .ready)
        let unavailable = await ReadinessWait.wait(limit: 5, step: 0.01) { .unavailable }
        #expect(unavailable == .unavailable)
        let timedOut = await ReadinessWait.wait(limit: 0.05, step: 0.01) { .starting }
        #expect(timedOut == .starting)
    }
}
