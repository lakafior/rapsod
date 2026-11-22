// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
import AudiobookshelfKit

/// Scalanie na prawdziwym serwerze (domyślnie wyłączone). Uruchomienie:
/// `ABS_LIVE_URL=http://127.0.0.1:PORT/audiobookshelf ABS_LIVE_KEY_FILE=plik ABS_LIVE_OUT=folder swift test --filter LiveMerge`.
/// Klucz API słuchacza czytany z pliku JSON (`{"key": "…"}`), nigdy z argumentów. Test zapisuje
/// scaloną kolejność każdego sortowania do `ABS_LIVE_OUT`; zgodność z kolejnością serwera
/// sprawdza się potem zapytaniem SQLite na bazie serwera (`scripts` w notatce etapu 10d).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ABS_LIVE_URL"] != nil))
struct LiveMergeTests {
    @Test func dumpMergedOrders() async throws {
        let environment = ProcessInfo.processInfo.environment
        let url = try #require(environment["ABS_LIVE_URL"].flatMap(URL.init(string:)))
        let secrets = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: try #require(environment["ABS_LIVE_KEY_FILE"])))) as? [String: Any]
        let key = try #require(secrets?["key"] as? String)
        let out = URL(filePath: try #require(environment["ABS_LIVE_OUT"]), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let auth = ListeningAuth(client: AudiobookshelfClient(baseURL: url), apiKey: key)
        let combined = try await CombinedLibraries.load(auth: auth)
        #expect(combined.libraries.count >= 2)
        let me: AudiobookshelfClient.MeState = try await auth.perform { try await $0.me(token: $1) }
        let lastUpdate = Dictionary(me.mediaProgress.elements.filter { $0.episodeId == nil }.compactMap { p in p.libraryItemId.map { ($0, p.lastUpdate) } }, uniquingKeysWith: max)

        var report: [String: Any] = ["ignoresPrefix": combined.ignoresTitlePrefix]
        for sort in CombinedLibraries.ItemSort.allCases {
            for descending in [false, true] {
                let merge = combined.items(sort: sort, descending: descending, lastUpdate: lastUpdate, pageSize: 25)
                var ids: [String] = []
                while true {
                    let batch = try await merge.next(30)
                    #expect(batch.stalled == nil)
                    ids += batch.elements.map { $0.value.id }
                    if batch.isFinished || batch.elements.isEmpty { break }
                }
                #expect(ids.count == merge.total)
                #expect(Set(ids).count == ids.count)
                report["\(sort.rawValue)-\(descending ? "desc" : "asc")"] = ["ids": ids, "requests": merge.requestCount]
            }
        }
        for (name, filter) in [("not-started", CombinedLibraries.ProgressFilter.notStarted), ("in-progress", .inProgress), ("finished", .finished)] {
            let batch = try await combined.items(sort: .title, descending: false, progress: filter).next(10_000)
            report["filter-\(name)"] = ["ids": batch.elements.map { $0.value.id }]
        }
        let series = combined.series()
        while !series.isFinished { if try await series.loadMore(50).isEmpty { break } }
        report["series"] = series.entities.map { ["name": $0.first.name, "ids": $0.members.map { $0.value.id }] }
        let authors = combined.authors()
        while !authors.isFinished { if try await authors.loadMore(50).isEmpty { break } }
        report["authors"] = authors.entities.map { ["name": $0.first.name, "ids": $0.members.map { $0.value.id }] }
        let shelves = try await combined.shelves(lastUpdate: lastUpdate)
        report["shelves"] = ["continueListening": shelves.continueListening.map { $0.id }, "recentlyAdded": shelves.recentlyAdded.map { $0.id }, "continueSeries": shelves.continueSeries.map { $0.id }, "discover": shelves.discover.map { $0.id }]
        let search = try await combined.search("wied")
        report["search"] = ["books": search.books.map { $0.title }, "series": search.series.map { [$0.first.name: $0.members.count] }, "authors": search.authors.map { [$0.first.name: $0.members.count] }]
        if let witcher = series.entities.first(where: { $0.first.name == "Wiedźmin" }) {
            report["witcherBooks"] = try await combined.books(of: witcher).value.map { $0.title }
        }
        if let lem = authors.entities.first(where: { $0.first.name == "Stanisław Lem" }) {
            report["lemBooks"] = try await combined.author(lem).value.books.map { $0.title }
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appending(path: "merged.json"))
    }
}
