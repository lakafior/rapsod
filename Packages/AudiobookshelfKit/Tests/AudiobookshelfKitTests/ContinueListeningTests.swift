// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import AudiobookshelfKit

/// „Słuchaj dalej” pokazywało dwa razy ten sam odcinek (etap 10i): `items-in-progress` zwraca
/// tę samą pozycję podcastu dla każdego zaczętego odcinka, a lista była kluczowana po `id` pozycji.
@Suite struct ContinueListeningTests {
    typealias Client = AudiobookshelfClient

    private func book(_ id: String, lastUpdate: Double) -> Client.LibraryItem {
        decode(#"{"id":"\#(id)","libraryId":"L","mediaType":"book","media":{"metadata":{"title":"\#(id)"}},"progressLastUpdate":\#(lastUpdate)}"#)
    }

    /// Pozycja podcastu z `items-in-progress` z jednym odcinkiem.
    private func episode(_ itemID: String, _ episodeID: String, guid: String?, url: String, title: String = "Odcinek", lastUpdate: Double) -> Client.LibraryItem {
        let guidJSON = guid.map { "\"\($0)\"" } ?? "null"
        return decode(#"{"id":"\#(itemID)","libraryId":"P","mediaType":"podcast","media":{"metadata":{"title":"Podcast"}},"progressLastUpdate":\#(lastUpdate),"recentEpisode":{"id":"\#(episodeID)","title":"\#(title)","guid":\#(guidJSON),"enclosure":{"url":"\#(url)"},"publishedAt":1700000000000}}"#)
    }

    private func record(_ itemID: String, feedKey: String, guid: String?, url: String, title: String = "Odcinek", updated: Double, time: Double = 100) -> LocalEpisodeRecord {
        LocalEpisodeRecord(itemID: itemID, feedKey: feedKey, title: title, podcastTitle: "Podcast", guid: guid, enclosureURL: url,
                           published: Date(timeIntervalSince1970: 1_700_000_000), duration: 600, currentTime: time, isFinished: false,
                           updatedAt: Date(timeIntervalSince1970: updated / 1000))
    }

    private func decode(_ json: String) -> Client.LibraryItem {
        try! JSONDecoder().decode(Client.LibraryItem.self, from: Data(json.utf8))
    }

    @Test func twoEpisodesOfOnePodcastAreTwoEntries() {
        let result = ContinueListening.merge(
            books: [],
            serverEpisodes: [
                episode("pod", "e1", guid: "g1", url: "https://x/1.mp3", lastUpdate: 2000),
                episode("pod", "e2", guid: "g2", url: "https://x/2.mp3", lastUpdate: 3000),
            ],
            local: []
        )
        #expect(result.entries.map(\.id) == ["pod/e2", "pod/e1"])
        #expect(Set(result.entries.map(\.id)).count == result.entries.count)
    }

    @Test func sameEpisodeFromServerAndStreamIsShownOnce() {
        // Odcinek słuchany ze strumienia, potem pobrany na serwer i słuchany stamtąd.
        let result = ContinueListening.merge(
            books: [],
            serverEpisodes: [episode("pod", "e1", guid: "g1", url: "https://x/1.mp3", lastUpdate: 5000)],
            local: [record("pod", feedKey: "g1", guid: "g1", url: "https://x/1.mp3", updated: 4000)]
        )
        #expect(result.entries.map(\.id) == ["pod/e1"])
        #expect(result.handover.map(\.feedKey) == ["g1"])
    }

    @Test func weakMatchIsOneEntryWithNewerTime() {
        // Inny guid na serwerze, ten sam plik po zdjęciu przekierowania śledzącego: dopasowanie słabe.
        let result = ContinueListening.merge(
            books: [],
            serverEpisodes: [episode("pod", "e1", guid: "server-guid", url: "https://cdn.example.com/a/1.mp3", lastUpdate: 1000)],
            local: [record("pod", feedKey: "feed-guid", guid: nil, url: "https://dts.podtrac.com/redirect.mp3/cdn.example.com/a/1.mp3?x=1", updated: 9000)]
        )
        #expect(result.entries.count == 1)
        #expect(result.handover.isEmpty)
        guard case .serverEpisode(_, _, let weak)? = result.entries.first?.kind else { Issue.record("brak odcinka"); return }
        #expect(weak?.feedKey == "feed-guid")
        // Nowszy zapis (telefonu) ustala miejsce na półce.
        #expect(result.entries.first?.lastUpdate == 9000)
    }

    @Test func unrelatedLocalEpisodeStays() {
        let result = ContinueListening.merge(
            books: [book("b1", lastUpdate: 1000)],
            serverEpisodes: [episode("pod", "e1", guid: "g1", url: "https://x/1.mp3", lastUpdate: 3000)],
            local: [record("pod", feedKey: "g9", guid: "g9", url: "https://x/9.mp3", title: "Inny", updated: 2000)]
        )
        #expect(result.entries.map(\.id) == ["pod/e1", LocalEpisodeRecord.id(itemID: "pod", feedKey: "g9"), "b1"])
    }

    @Test func booksUseLastUpdateFromMe() {
        let result = ContinueListening.merge(
            books: [book("a", lastUpdate: 1000), book("b", lastUpdate: 2000)],
            serverEpisodes: [],
            local: [],
            lastUpdate: ["a": 5000]
        )
        #expect(result.entries.map(\.id) == ["a", "b"])
    }

    @Test func weakRecordExits() {
        let local = record("pod", feedKey: "f", guid: nil, url: "https://x/1.mp3", updated: 9000, time: 300)
        // Serwer nowszy: wpis lokalny do usunięcia, nic nie przechodzi.
        #expect(EpisodeHandover.weakMatchIsStale(local, serverLastUpdate: 10_000))
        #expect(EpisodeHandover.adoptedStart(local, serverLastUpdate: 10_000, serverDuration: 600) == nil)
        // Telefon nowszy: start od jego miejsca (przeliczonego na plik serwera).
        #expect(!EpisodeHandover.weakMatchIsStale(local, serverLastUpdate: 1000))
        #expect(EpisodeHandover.adoptedStart(local, serverLastUpdate: 1000, serverDuration: 600) == 300)
        #expect(EpisodeHandover.adoptedStart(local, serverLastUpdate: nil, serverDuration: 1200) == 600)
    }

    // MARK: Menu na pasku menu (etap 14d)

    private func progress(_ itemID: String, _ episodeID: String? = nil, lastUpdate: Double, finished: Bool = false, hidden: Bool = false) -> (String, Client.MediaProgress) {
        (ProgressJournal.key(itemID, episodeID), Client.MediaProgress(libraryItemId: itemID, episodeId: episodeID, duration: 600, progress: 0.5,
            currentTime: 300, isFinished: finished, hideFromContinueListening: hidden, lastUpdate: lastUpdate))
    }

    @Test func recentMixesBooksAndEpisodesNewestFirst() {
        let entries = ContinueListening.recent(
            inProgress: [
                book("a", lastUpdate: 1000),
                episode("pod", "e1", guid: "g1", url: "https://x/1.mp3", lastUpdate: 3000),
                book("b", lastUpdate: 2000),
            ],
            progress: [:]
        )
        #expect(entries.map(\.id) == ["pod/e1", "b", "a"])
    }

    @Test func recentSkipsHiddenAndFinishedAndUsesNewerProgress() {
        let entries = ContinueListening.recent(
            inProgress: [book("a", lastUpdate: 1000), book("b", lastUpdate: 2000), book("c", lastUpdate: 3000), book("d", lastUpdate: 500)],
            progress: Dictionary(uniqueKeysWithValues: [
                progress("b", lastUpdate: 2000, hidden: true),
                progress("c", lastUpdate: 3000, finished: true),
                // Telefon słuchał „d” później, niż mówi odpowiedź `items-in-progress`.
                progress("d", lastUpdate: 9000),
            ])
        )
        #expect(entries.map(\.id) == ["d", "a"])
    }

    @Test func recentKeepsLimit() {
        let items = (0..<8).map { book("k\($0)", lastUpdate: Double($0)) }
        #expect(ContinueListening.recent(inProgress: items, progress: [:], limit: 3).map(\.id) == ["k7", "k6", "k5"])
    }
}
