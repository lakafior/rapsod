// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import AudiobookshelfKit

private func date(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: text)!
}

@Suite struct FeedDateTests {
    @Test func rfc822Variants() {
        #expect(FeedDate.parse("Tue, 05 Nov 2024 10:00:00 GMT") == date("2024-11-05T10:00:00Z"))
        #expect(FeedDate.parse("Tue, 5 Nov 2024 10:00:00 +0000") == date("2024-11-05T10:00:00Z"))
        #expect(FeedDate.parse("5 Nov 2024 11:00:00 +0100") == date("2024-11-05T10:00:00Z"))
        #expect(FeedDate.parse("Tue, 05 Nov 2024 05:00:00 EST") == date("2024-11-05T10:00:00Z"))
        #expect(FeedDate.parse("Tue, 05 Nov 2024 03:00:00 PDT") == date("2024-11-05T10:00:00Z"))
        // Bez sekund, z dwukropkiem w strefie, pełna nazwa miesiąca, bez strefy, dwucyfrowy rok.
        #expect(FeedDate.parse("Tuesday, 05 November 2024 12:00 +02:00") == date("2024-11-05T10:00:00Z"))
        #expect(FeedDate.parse("Tue, 05 Nov 2024 10:00:00") == date("2024-11-05T10:00:00Z"))
        #expect(FeedDate.parse("Tue, 05 Nov 24 10:00:00 GMT") == date("2024-11-05T10:00:00Z"))
        #expect(FeedDate.parse("Nov 5 2024 10:00:00 GMT") == date("2024-11-05T10:00:00Z"))
        #expect(FeedDate.parse("Tue, 05 Nov 2024") == date("2024-11-05T00:00:00Z"))
        #expect(FeedDate.parse("Tue,05 Nov 2024 10:00:00 GMT") == date("2024-11-05T10:00:00Z"))
    }

    @Test func iso8601Variants() {
        #expect(FeedDate.parse("2024-11-05T10:00:00Z") == date("2024-11-05T10:00:00Z"))
        #expect(FeedDate.parse("2024-11-05T12:00:00.123+02:00") == date("2024-11-05T10:00:00Z"))
        #expect(FeedDate.parse("2024-11-05") == date("2024-11-05T00:00:00Z"))
    }

    @Test func rejectsNonsense() {
        #expect(FeedDate.parse("") == nil)
        #expect(FeedDate.parse("wczoraj") == nil)
        #expect(FeedDate.parse("31 Feb 2024 10:00:00 GMT") == nil)
        #expect(FeedDate.parse("Tue, 05 Foo 2024 10:00:00 GMT") == nil)
    }
}

@Suite struct FeedDurationTests {
    @Test func formats() {
        #expect(FeedDuration.seconds("1:02:03") == 3723)
        #expect(FeedDuration.seconds("62:03") == 3723)
        #expect(FeedDuration.seconds("3723") == 3723)
        #expect(FeedDuration.seconds("3723.5") == 3723.5)
        #expect(FeedDuration.seconds(" 00:45 ") == 45)
        #expect(FeedDuration.seconds("") == nil)
        #expect(FeedDuration.seconds("1:75:00") == nil)
        #expect(FeedDuration.seconds("abc") == nil)
        #expect(FeedDuration.seconds("0") == nil)
    }
}

/// Zwyczajny kanał: przestrzenie nazw iTunes i content, CDATA z HTML, guid, sezon i odcinek.
private let standardFeed = """
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/">
<channel>
  <title>Przykładowy podcast</title>
  <link>https://example.com</link>
  <language>pl</language>
  <itunes:author>Jan Kowalski</itunes:author>
  <description><![CDATA[<p>Opis <b>kanału</b> &amp; więcej</p>]]></description>
  <image><url>https://example.com/small.jpg</url><title>Logo</title></image>
  <itunes:image href="https://example.com/cover.jpg"/>
  <item>
    <title>Odcinek 2: Drugi</title>
    <guid isPermaLink="false">ep-2</guid>
    <pubDate>Wed, 06 Nov 2024 10:00:00 GMT</pubDate>
    <itunes:duration>1:02:03</itunes:duration>
    <itunes:season>1</itunes:season>
    <itunes:episode>2</itunes:episode>
    <itunes:episodeType>Full</itunes:episodeType>
    <itunes:image href="https://example.com/ep2.jpg"/>
    <description>Krótki opis</description>
    <content:encoded><![CDATA[<p>Pełny <script>alert(1)</script>opis</p><ul><li>punkt</li></ul>]]></content:encoded>
    <enclosure url=" https://cdn.example.com/ep2.mp3?aid=rss " length="12345678" type="audio/mpeg"/>
  </item>
  <item>
    <title>Zwiastun</title>
    <guid>ep-1</guid>
    <pubDate>Tue, 05 Nov 2024 10:00:00 GMT</pubDate>
    <itunes:episodeType>trailer</itunes:episodeType>
    <enclosure url="https://cdn.example.com/ep1.m4a" type="audio/x-m4a"/>
  </item>
  <item>
    <title>Wpis bez pliku</title>
    <guid>post-1</guid>
  </item>
</channel>
</rss>
"""

@Suite struct RSSParserTests {
    @Test func standardFeedFields() throws {
        let podcast = try RSSFeedParser.parse(Data(standardFeed.utf8))
        #expect(podcast.title == "Przykładowy podcast")
        #expect(podcast.author == "Jan Kowalski")
        #expect(podcast.summary == "Opis kanału & więcej")
        #expect(podcast.imageURL == URL(string: "https://example.com/cover.jpg"))
        #expect(podcast.language == "pl")
        #expect(!podcast.isPartial)
        // Wpis bez pliku audio pominięty.
        #expect(podcast.episodes.count == 2)
        let ep = podcast.episodes[0]
        #expect(ep.title == "Odcinek 2: Drugi")
        #expect(ep.guid == "ep-2")
        #expect(ep.id == "g:ep-2")
        #expect(ep.published == date("2024-11-06T10:00:00Z"))
        #expect(ep.durationSeconds == 3723)
        #expect(ep.season == "1")
        #expect(ep.episode == "2")
        #expect(ep.episodeType == "full")
        #expect(ep.imageURL == URL(string: "https://example.com/ep2.jpg"))
        // Adres przycięty, ale z parametrami — dokładnie jak zapisze serwer.
        #expect(ep.enclosure.url == "https://cdn.example.com/ep2.mp3?aid=rss")
        #expect(ep.enclosure.length == 12_345_678)
        #expect(ep.enclosure.type == "audio/mpeg")
        // Opis z content:encoded, jako tekst — znaczniki (także <script>) usunięte.
        #expect(ep.summary?.contains("<") == false)
        #expect(ep.summary?.contains("Pełny") == true)
        #expect(ep.summary?.contains("• punkt") == true)
        #expect(podcast.episodes[1].episodeType == "trailer")
        #expect(podcast.episodes[1].durationSeconds == nil)
    }

    @Test func toleratesSloppyFeeds() throws {
        // Pusta linia przed deklaracją, niezadeklarowany przedrostek itunes:, &nbsp; i gołe & w adresie,
        // brak guid, plik w media:content, inny przedrostek dla przestrzeni iTunes.
        let feed = """

        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:it="http://www.itunes.com/DTDs/Podcast-1.0.dtd" xmlns:media="http://search.yahoo.com/mrss/">
        <channel>
          <title>Bałagan&nbsp;FM</title>
          <item>
            <title>Bez guid</title>
            <it:duration>45:00</it:duration>
            <pubDate>5 Nov 2024 10:00 +0100</pubDate>
            <enclosure url="https://host.example/play?id=7&src=rss" type="audio/mpeg" length="abc"/>
          </item>
          <item>
            <title>Tylko media</title>
            <itunes:summary>Tekst &hellip; dalej</itunes:summary>
            <media:content url="https://host.example/b.mp3" type="audio/mpeg" fileSize="99"/>
          </item>
        </channel>
        </rss>
        """
        let podcast = try RSSFeedParser.parse(Data(feed.utf8))
        #expect(podcast.title == "Bałagan\u{A0}FM")
        #expect(podcast.episodes.count == 2)
        let first = podcast.episodes[0]
        #expect(first.guid == nil)
        #expect(first.id == "u:https://host.example/play?id=7&src=rss")
        #expect(first.durationSeconds == 2700)
        #expect(first.enclosure.length == nil)
        #expect(first.published == date("2024-11-05T09:00:00Z"))
        let second = podcast.episodes[1]
        #expect(second.enclosure.url == "https://host.example/b.mp3")
        #expect(second.enclosure.length == 99)
        #expect(second.summary == "Tekst … dalej")
    }

    @Test func truncatedFeedKeepsReadEpisodes() throws {
        let cut = String(standardFeed.prefix(through: standardFeed.range(of: "<title>Zwiastun")!.lowerBound))
        let podcast = try RSSFeedParser.parse(Data(cut.utf8))
        #expect(podcast.isPartial)
        #expect(podcast.episodes.map(\.guid) == ["ep-2"])
    }

    @Test func rejectsNonRSS() {
        #expect(throws: RSSFeedParser.ParseError.notRSS) { try RSSFeedParser.parse(Data("<html><body>404</body></html>".utf8)) }
        #expect(throws: (any Error).self) { try RSSFeedParser.parse(Data("nie xml".utf8)) }
    }

    @Test func onlyWebURLs() {
        #expect(RSSFeedParser.webURL("javascript:alert(1)") == nil)
        #expect(RSSFeedParser.webURL("file:///etc/passwd") == nil)
        #expect(RSSFeedParser.webURL("https://ok.example/a b.mp3")?.host() == "ok.example")
        #expect(RSSFeedParser.webURL("http://ok.example/a.mp3") != nil)
        let feed = standardFeed.replacingOccurrences(of: "https://cdn.example.com/ep1.m4a", with: "file:///private/x.m4a")
        let podcast = try? RSSFeedParser.parse(Data(feed.utf8))
        #expect(podcast?.episodes[1].audioURL == nil)
    }

    @Test func entityBombIsNotExpanded() throws {
        // Encje wewnętrzne DTD: libxml2 bez rozwijania encji zewnętrznych; wynik ograniczony długością pola.
        let feed = """
        <?xml version="1.0"?>
        <!DOCTYPE rss [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;"><!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">]>
        <rss><channel><title>&c;</title><item><title>x</title><enclosure url="https://a.example/x.mp3"/></item></channel></rss>
        """
        let podcast = try? RSSFeedParser.parse(Data(feed.utf8))
        #expect((podcast?.title?.count ?? 0) <= RSSFeedParser.maxFieldLength + 1000)
    }
}

@Suite struct EpisodeMatchingTests {
    private func id(_ guid: String?, _ url: String?, _ title: String? = nil, _ published: String? = nil) -> EpisodeIdentity {
        EpisodeIdentity(guid: guid, url: url, title: title, published: published.map(date))
    }

    @Test func serverRules() {
        #expect(EpisodeMatching.strength(id("a", "https://x/1.mp3"), id("a", "https://y/2.mp3")) == .guid)
        // Adres równy, guid inny — serwer też uznaje za ten sam (guid ALBO adres).
        #expect(EpisodeMatching.strength(id("a", "https://x/1.mp3"), id("b", "https://x/1.mp3")) == .exactURL)
        #expect(EpisodeMatching.strength(id(nil, "https://x/1.mp3"), id(nil, "https://x/1.mp3")) == .exactURL)
        #expect(EpisodeMatching.strength(id("a", nil), id("b", nil)) == nil)
    }

    @Test func trackingRedirectsAndParameters() {
        let plain = "https://traffic.libsyn.com/show/ep1.mp3"
        let tracked = [
            "https://dts.podtrac.com/redirect.mp3/traffic.libsyn.com/show/ep1.mp3?utm_source=rss",
            "https://chtbl.com/track/ABC123/traffic.libsyn.com/show/ep1.mp3",
            "https://dts.podtrac.com/redirect.mp3/chtbl.com/track/ABC123/traffic.libsyn.com/show/ep1.mp3",
            "https://op3.dev/e/https://traffic.libsyn.com/show/ep1.mp3",
            "https://pdst.fm/e/traffic.libsyn.com/show/ep1.mp3",
            "http://www.traffic.libsyn.com/show/ep1.mp3?aid=rss_feed&amp;feed=1",
        ]
        let expected = EpisodeMatching.normalizedURL(plain)
        #expect(expected == "traffic.libsyn.com/show/ep1.mp3")
        for url in tracked {
            #expect(EpisodeMatching.normalizedURL(url) == expected, "\(url)")
            #expect(EpisodeMatching.strength(id(nil, url), id(nil, plain)) == .normalizedURL)
        }
        // Adres bez rozszerzenia: parametr wyróżnia plik.
        #expect(EpisodeMatching.normalizedURL("https://a.example/get?id=1&utm_campaign=x") == "a.example/get?id=1")
        #expect(EpisodeMatching.normalizedURL("https://a.example/get?id=1") != EpisodeMatching.normalizedURL("https://a.example/get?id=2"))
        // Różne guidy blokują dopasowanie po adresie po normalizacji.
        #expect(EpisodeMatching.strength(id("a", tracked[0]), id("b", plain)) == nil)
    }

    @Test func titleAndDate() {
        let a = id(nil, "https://old.example/1.mp3", "Odcinek #12: Lato!", "2024-06-01T10:00:00Z")
        let b = id(nil, "https://new.example/abc", "odcinek 12 lato", "2024-06-01T22:00:00Z")
        #expect(EpisodeMatching.strength(a, b) == .titleAndDate)
        #expect(EpisodeMatching.strength(a, id(nil, "https://new.example/abc", "odcinek 12 lato", "2024-06-05T10:00:00Z")) == nil)
        // Data tylko po jednej stronie — za mało.
        #expect(EpisodeMatching.strength(a, id(nil, "https://new.example/abc", "odcinek 12 lato", nil)) == nil)
        #expect(!EpisodeMatching.Strength.titleAndDate.isCertain)
        #expect(EpisodeMatching.Strength.exactURL.isCertain)
    }

    @Test func pairsEachEpisodeOnce() {
        let feed = [
            id("g1", "https://cdn/1.mp3", "Jeden", "2024-01-01T00:00:00Z"),
            id(nil, "https://dts.podtrac.com/redirect.mp3/cdn.example/2.mp3", "Dwa", "2024-01-02T00:00:00Z"),
            id(nil, "https://cdn/3.mp3", "Powtórka", "2024-01-03T00:00:00Z"),
            id(nil, "https://cdn/4.mp3", "Powtórka", "2024-01-03T01:00:00Z"),
            id("g5", "https://cdn/5.mp3", "Pięć", "2024-01-05T00:00:00Z"),
        ]
        let server = [
            id("g5", "https://cdn/5-renamed.mp3", "Pięć (poprawione)", nil),
            id(nil, "https://cdn.example/2.mp3", "Dwa", nil),
            id(nil, "https://moved/x", "Powtórka", "2024-01-03T00:30:00Z"),
            id("g1", "https://cdn/1.mp3", "Jeden", nil),
        ]
        let matches = EpisodeMatching.match(feed, server)
        #expect(matches[0] == .init(other: 3, strength: .guid))
        #expect(matches[1] == .init(other: 1, strength: .normalizedURL))
        // Dwa odcinki „Powtórka” blisko siebie w czasie: niejednoznaczne — bez dopasowania.
        #expect(matches[2] == nil)
        #expect(matches[3] == nil)
        #expect(matches[4] == .init(other: 0, strength: .guid))
    }

    @Test func downloadQueueEntries() throws {
        let json = #"{"id":"d1","libraryItemId":"li","url":"https://cdn.example/Odcinek%20%C5%9Bwi%C4%99ta.mp3?a=1","guid":null}"#
        let download = try JSONDecoder().decode(AudiobookshelfClient.EpisodeDownload.self, from: Data(json.utf8))
        #expect(EpisodeMatching.isSame(download, as: id(nil, "https://cdn.example/Odcinek święta.mp3?a=1")))
        #expect(!EpisodeMatching.isSame(download, as: id(nil, "https://cdn.example/inny.mp3")))
        let withGuid = #"{"id":"d2","libraryItemId":"li","url":"https://x/y.mp3","guid":"abc"}"#
        let byGuid = try JSONDecoder().decode(AudiobookshelfClient.EpisodeDownload.self, from: Data(withGuid.utf8))
        #expect(EpisodeMatching.isSame(byGuid, as: id("abc", "https://zupelnie/inny.mp3")))
        #expect(!EpisodeMatching.isSame(byGuid, as: id("xyz", "https://x/y.mp3")))
    }

    @Test func downloadOrderNeedsCertainMatch() throws {
        let serverFeed = #"{"metadata":{"title":"P"},"episodes":[{"title":"A","guid":"ga","enclosure":{"url":"https://cdn/a.mp3"},"publishedAt":1700000000000},{"title":"B","enclosure":{"url":"https://cdn/b.mp3"}}]}"#
        let feed = try JSONDecoder().decode(AudiobookshelfClient.PodcastFeed.self, from: Data(serverFeed.utf8))
        let wanted = [
            RSSEpisode(guid: "ga", title: "A", enclosure: .init(url: "https://cdn/a.mp3")),
            RSSEpisode(guid: nil, title: "B", enclosure: .init(url: "https://cdn/b.mp3")),
            // Ten sam tytuł, ale inny adres — za mało pewne, by zlecać.
            RSSEpisode(guid: nil, title: "C", enclosure: .init(url: "https://dts.podtrac.com/redirect.mp3/cdn/c.mp3")),
        ]
        let order = PodcastDownloadOrder.select(wanted, in: feed.episodes)
        #expect(order.found.map(\.title) == ["A", "B"])
        #expect(order.missing.map(\.title) == ["C"])
    }
}

@Suite @MainActor struct LocalEpisodeProgressTests {
    private func record(time: Double = 120, finished: Bool = false, updated: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> LocalEpisodeRecord {
        LocalEpisodeRecord(itemID: "li", feedKey: "g:ep", title: "Odcinek", podcastTitle: "P", guid: "ep", enclosureURL: "https://cdn/ep.mp3",
                           published: nil, duration: 600, currentTime: time, isFinished: finished, updatedAt: updated)
    }

    @Test func survivesRestart() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "local-episodes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ProgressJournal(fileURL: file)
        store.save(record())
        store.save(LocalEpisodeRecord(itemID: "li", feedKey: "u:https://cdn/b.mp3", title: "B", podcastTitle: nil, guid: nil, enclosureURL: "https://cdn/b.mp3", published: nil, duration: 10, currentTime: 10, isFinished: true, updatedAt: .now))
        let reopened = ProgressJournal(fileURL: file)
        #expect(reopened.records.count == 2)
        #expect(reopened.record(itemID: "li", feedKey: "g:ep")?.currentTime == 120)
        #expect(reopened.inProgress.map(\.feedKey) == ["g:ep"])
        reopened.remove(itemID: "li", feedKey: "g:ep")
        #expect(ProgressJournal(fileURL: file).records.count == 1)
    }

    @Test func handoverDecision() {
        let local = record()
        // Serwer nie zna postępu — wysyłamy.
        #expect(EpisodeHandover.decide(local, serverLastUpdate: nil, serverDuration: 598) == .send(currentTime: 120, duration: 598, isFinished: false))
        // Serwer ma nowszy (np. Mac słuchał już pobranego) — lokalny przepada.
        #expect(EpisodeHandover.decide(local, serverLastUpdate: (local.updatedAt.timeIntervalSince1970 + 5) * 1000, serverDuration: 600) == .discardLocal)
        // Starszy zapis na serwerze — wygrywa telefon.
        #expect(EpisodeHandover.decide(local, serverLastUpdate: (local.updatedAt.timeIntervalSince1970 - 60) * 1000, serverDuration: nil) == .send(currentTime: 120, duration: 600, isFinished: false))
        // Plik na serwerze krótszy niż strumień (inne reklamy): pozycja proporcjonalnie, bez fałszywego „ukończone”.
        let streamed = LocalEpisodeRecord(itemID: "li", feedKey: "g:ep", title: "O", podcastTitle: nil, guid: "ep", enclosureURL: "https://cdn/ep.mp3",
                                          published: nil, duration: 304.7, currentTime: 282, isFinished: false, updatedAt: local.updatedAt)
        if case .send(let time, let duration, let finished) = EpisodeHandover.decide(streamed, serverLastUpdate: nil, serverDuration: 286.7) {
            #expect(abs(time - 282 * 286.7 / 304.7) < 0.01)
            #expect(duration == 286.7)
            #expect(!finished)
        } else {
            Issue.record("oczekiwano wysłania")
        }
        // Różnica poniżej 1% — bez przeliczania.
        #expect(EpisodeHandover.serverTime(100, streamDuration: 600, serverDuration: 598) == 100)
        // Ukończony lokalnie.
        #expect(EpisodeHandover.decide(record(time: 600, finished: true), serverLastUpdate: nil, serverDuration: 590) == .send(currentTime: 590, duration: 590, isFinished: true))
        // Nic nie przesłuchano.
        #expect(EpisodeHandover.decide(record(time: 0), serverLastUpdate: nil, serverDuration: 600) == .discardLocal)
    }

    @Test func findsServerEpisodeOnlyWhenCertain() throws {
        let json = #"[{"id":"e1","title":"Odcinek","enclosure":{"url":"https://dts.podtrac.com/redirect.mp3/cdn/ep.mp3"}},{"id":"e2","title":"Inny","guid":"ep","enclosure":{"url":"https://elsewhere/x.mp3"}}]"#
        let episodes = try JSONDecoder().decode([AudiobookshelfClient.PodcastEpisode].self, from: Data(json.utf8))
        #expect(EpisodeHandover.serverEpisode(for: record(), in: episodes)?.id == "e2")
        #expect(EpisodeHandover.serverEpisode(for: record(), in: [episodes[0]]) == nil)
    }
}

@Suite struct PodcastSortTests {
    private func item(_ id: String, _ title: String, author: String?, added: Double, episodes: Int) throws -> AudiobookshelfClient.LibraryItem {
        let authorJSON = author.map { "\"\($0)\"" } ?? "null"
        let json = #"{"id":"\#(id)","libraryId":"P","mediaType":"podcast","addedAt":\#(added),"media":{"numEpisodes":\#(episodes),"metadata":{"title":"\#(title)","author":\#(authorJSON)}}}"#
        return try JSONDecoder().decode(AudiobookshelfClient.LibraryItem.self, from: Data(json.utf8))
    }

    @Test func orders() throws {
        let items = [
            try item("1", "beta", author: "Zenon", added: 3, episodes: 5),
            try item("2", "Alfa", author: nil, added: 1, episodes: 9),
            try item("3", "Gamma", author: "adam", added: 2, episodes: 5),
        ]
        let sort = CombinedLibraries.sortPodcasts
        #expect(sort(items, .title, false, false).map(\.id) == ["2", "1", "3"])
        #expect(sort(items, .author, false, false).map(\.id) == ["3", "1", "2"])
        #expect(sort(items, .author, true, false).map(\.id) == ["2", "1", "3"])
        #expect(sort(items, .addedAt, true, false).map(\.id) == ["1", "3", "2"])
        #expect(sort(items, .episodes, true, false).map(\.id) == ["2", "1", "3"])
    }
}
