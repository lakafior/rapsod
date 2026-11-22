// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import AudiobookshelfKit

/// Porównanie jak `COLLATE NOCASE` serwera.
@Suite struct ServerCollationTests {
    @Test func foldsOnlyASCII() {
        #expect(ServerCollation.compare("abc", "ABD") < 0)
        #expect(ServerCollation.compare("Ala", "ala") == 0)
        #expect(ServerCollation.compare("a", "ab") < 0)
        // Litery spoza ASCII za „z” i bez zrównania wielkości.
        #expect(ServerCollation.compare("Zebra", "Łódź") < 0)
        #expect(ServerCollation.compare("łódź", "Łódź") != 0)
        #expect(ServerCollation.key("  Wiedźmin ") == ServerCollation.key("WIEDźMIN"))
    }

    @Test func titleWithoutPrefix() {
        #expect(ServerCollation.titleKey(title: "The Hobbit", withPrefixAtEnd: "Hobbit, The", ignoresPrefix: true) == "Hobbit")
        #expect(ServerCollation.titleKey(title: "The Hobbit", withPrefixAtEnd: "Hobbit, The", ignoresPrefix: false) == "The Hobbit")
        #expect(ServerCollation.titleKey(title: "Ogniem i mieczem", withPrefixAtEnd: "Ogniem i mieczem", ignoresPrefix: true) == "Ogniem i mieczem")
        // Przecinek w samym tytule bez przedrostka nie myli.
        #expect(ServerCollation.titleKey(title: "Ja, robot", withPrefixAtEnd: "Ja, robot", ignoresPrefix: true) == "Ja, robot")
    }

    @Test func sequenceOrder() {
        let order = ["10", nil, "2", "1.5", "1"].sorted { CombinedLibraries.compareSequence($0, $1) < 0 }
        #expect(order == ["1", "1.5", "2", "10", nil])
    }
}

/// Zaślepka biblioteki: pozycje, które serwer sortuje sam (tu: tym samym porządkiem co klient,
/// bo sprawdzamy scalanie, nie zgodność sortowania — tę sprawdza test na prawdziwym serwerze).
private struct FakeItem {
    let id: String
    let title: String
    let author: String
    let addedAt: Double
    let duration: Double?

    var json: String {
        let duration = self.duration.map { String($0) } ?? "null"
        return #"{"id":"\#(id)","libraryId":"LIB","mediaType":"book","addedAt":\#(addedAt),"media":{"duration":\#(duration),"metadata":{"title":"\#(title)","authorName":"\#(author)"}}}"#
    }
}

private func seriesJSON(_ id: String, _ name: String, library: String) -> String {
    #"{"id":"\#(id)","name":"\#(name)","libraryId":"\#(library)","books":[]}"#
}

private func query(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
}

extension Stubbed {
@MainActor
@Suite struct CombinedLibrariesTests {
    init() { StubServer.reset() }

    private func libraries(_ ids: [String]) -> String {
        let list = ids.map { #"{"id":"\#($0)","name":"Biblioteka \#($0)","mediaType":"book","folders":[]}"# }.joined(separator: ",")
        return #"{"libraries":[\#(list)]}"#
    }

    private func catalog(_ ids: [String]) -> CombinedLibraries {
        let auth = ListeningAuth(client: StubServer.client(), apiKey: "K")
        let libraries = ids.map { AudiobookshelfClient.Library(id: $0, name: "Biblioteka \($0)", mediaType: "book", folders: []) }
        return CombinedLibraries(auth: auth, libraries: libraries, ignoresTitlePrefix: false)
    }

    /// Biblioteka odpowiadająca stronami posortowanymi tak, jak prosi zapytanie.
    private func serve(_ libraryID: String, _ items: [FakeItem], failing: Set<Int> = []) {
        StubServer.handle("GET api/libraries/\(libraryID)/items") { request in
            let q = query(request)
            let page = Int(q["page"] ?? "0") ?? 0
            let limit = Int(q["limit"] ?? "0") ?? 0
            if failing.contains(page) { return .json("awaria", status: 500) }
            let descending = q["desc"] == "1"
            let order = CombinedLibraries.itemOrder(sort: q["sort"] == "addedAt" ? .addedAt : (q["sort"] == "media.duration" ? .duration : .title), descending: descending, ignoresPrefix: false)
            let decoded = items.map { try! JSONDecoder().decode(AudiobookshelfClient.LibraryItem.self, from: Data($0.json.utf8)) }
            let sorted = zip(items, decoded).sorted { order($0.1, $1.1) }.map(\.0)
            let slice = limit == 0 ? sorted[...] : sorted.dropFirst(page * limit).prefix(limit)
            let body = slice.map(\.json).joined(separator: ",")
            return .json(#"{"results":[\#(body)],"total":\#(items.count)}"#)
        }
    }

    private func items(_ prefix: String, count: Int, addedStart: Double) -> [FakeItem] {
        (0..<count).map { index in
            // Tytuły przeplatają się między bibliotekami: A0, B0, A1…
            FakeItem(id: "\(prefix)\(index)", title: String(format: "Tom %03d %@", index, prefix), author: "Autor", addedAt: addedStart + Double(index) * 2, duration: index % 3 == 0 ? nil : Double(index * 10))
        }
    }

    @Test func mergesTitlesAcrossLibrariesPageByPage() async throws {
        let a = items("A", count: 23, addedStart: 0)
        let b = items("B", count: 17, addedStart: 1)
        serve("A", a)
        serve("B", b)
        let merge = catalog(["A", "B"]).items(sort: .title, descending: false, pageSize: 5)

        let first = try await merge.next(5)
        // Tylko po jednej stronie z każdej biblioteki — bez wczytywania całości.
        #expect(merge.requestCount == 2)
        #expect(first.elements.map(\.value.id) == ["A0", "B0", "A1", "B1", "A2"])
        #expect(merge.total == 40)

        var all = first.elements
        while !merge.isFinished {
            let batch = try await merge.next(5)
            #expect(batch.stalled == nil)
            all += batch.elements
            if batch.elements.isEmpty { break }
        }
        let expected = (a + b).sorted { $0.title.utf8.lexicographicallyPrecedes($1.title.utf8) }.map(\.id)
        #expect(all.map(\.value.id) == expected)
        #expect(Set(all.map(\.libraryID)) == ["A", "B"])
        // 23/5 → 5 stron, 17/5 → 4 strony: ani jednego zapytania więcej.
        #expect(merge.requestCount == 9)
    }

    @Test func mergesDescendingByAddedAtAndDuration() async throws {
        let a = items("A", count: 8, addedStart: 0)
        let b = items("B", count: 8, addedStart: 1)
        serve("A", a)
        serve("B", b)
        let byAdded = try await catalog(["A", "B"]).items(sort: .addedAt, descending: true, pageSize: 3).next(100)
        #expect(byAdded.isFinished)
        #expect(byAdded.elements.map(\.value.id) == (a + b).sorted { $0.addedAt > $1.addedAt }.map(\.id))

        let byDuration = try await catalog(["A", "B"]).items(sort: .duration, descending: true, pageSize: 3).next(100)
        let durations = byDuration.elements.map(\.value.media.duration)
        // Bez czasu (NULL) na końcu przy malejącym.
        #expect(durations.suffix(6).allSatisfy { $0 == nil })
        #expect(durations.compactMap(\.self) == durations.compactMap(\.self).sorted(by: >))
        #expect(byDuration.elements.count == 16)
    }

    @Test func libraryFailingAtStartIsSkipped() async throws {
        serve("A", items("A", count: 4, addedStart: 0))
        serve("B", items("B", count: 4, addedStart: 0), failing: [0])
        let merge = catalog(["A", "B"]).items(sort: .title, descending: false, pageSize: 10)
        let batch = try await merge.next(10)
        #expect(batch.elements.map(\.value.id) == ["A0", "A1", "A2", "A3"])
        #expect(batch.isFinished)
        #expect(merge.failures.map(\.libraryID) == ["B"])
        #expect(merge.failures.first?.libraryName == "Biblioteka B")
    }

    @Test func failureMidScrollStallsAndRecovers() async throws {
        let a = items("A", count: 6, addedStart: 0)
        let b = items("B", count: 6, addedStart: 0)
        serve("A", a)
        serve("B", b, failing: [1])
        let merge = catalog(["A", "B"]).items(sort: .title, descending: false, pageSize: 2)
        let first = try await merge.next(10)
        // B0, B1 z pierwszej strony B; dalej trzeba by znać B2 — scalanie staje zamiast go pominąć.
        #expect(first.elements.map(\.value.id) == ["A0", "B0", "A1", "B1"])
        #expect(first.stalled?.libraryID == "B")
        #expect(!first.isFinished)

        serve("B", b)
        let rest = try await merge.next(10)
        #expect(rest.stalled == nil)
        #expect((first.elements + rest.elements).map(\.value.id) == ["A0", "B0", "A1", "B1", "A2", "B2", "A3", "B3", "A4", "B4", "A5", "B5"])
    }

    @Test func lastListenedPutsUnlistenedLast() async throws {
        // Serwer zwraca pozycje już posortowane po postępie; tu podajemy je w tej kolejności.
        let a = [FakeItem(id: "a1", title: "x", author: "", addedAt: 0, duration: 1), FakeItem(id: "a2", title: "y", author: "", addedAt: 0, duration: 1), FakeItem(id: "a3", title: "z", author: "", addedAt: 0, duration: 1)]
        let b = [FakeItem(id: "b1", title: "x", author: "", addedAt: 0, duration: 1), FakeItem(id: "b2", title: "y", author: "", addedAt: 0, duration: 1)]
        for (id, list) in [("A", a), ("B", b)] {
            StubServer.handle("GET api/libraries/\(id)/items") { _ in
                .json(#"{"results":[\#(list.map(\.json).joined(separator: ","))],"total":\#(list.count)}"#)
            }
        }
        let lastUpdate: [String: Double] = ["a1": 300, "b1": 500, "a2": 100]
        let merged = try await catalog(["A", "B"]).items(sort: .lastListened, descending: true, lastUpdate: lastUpdate, pageSize: 10).next(10)
        #expect(merged.elements.map(\.value.id) == ["b1", "a1", "a2", "a3", "b2"])
    }

    @Test func filterAndLibraryScope() async throws {
        serve("A", items("A", count: 2, addedStart: 0))
        serve("B", items("B", count: 2, addedStart: 0))
        let merged = try await catalog(["A", "B"]).items(sort: .title, descending: false, progress: .inProgress, libraryID: "B").next(10)
        #expect(merged.elements.map(\.value.id) == ["B0", "B1"])
        let request = try #require(StubServer.requests.first?.request)
        #expect(request.url?.path().hasSuffix("libraries/B/items") == true)
        #expect(query(request)["filter"] == AudiobookshelfClient.filter("progress", "in-progress"))
        #expect(StubServer.requests.count == 1)
    }

    @Test func cancellationKeepsState() async throws {
        serve("A", items("A", count: 4, addedStart: 0))
        let merge = catalog(["A"]).items(sort: .title, descending: false, pageSize: 2)
        let task = Task { @MainActor in try await merge.next(2) }
        task.cancel()
        // Anulowanie mogło zdążyć albo nie — w obu przypadkach nic nie ginie i nic się nie powtarza.
        let early = (try? await task.value)?.elements ?? []
        var ids = early.map(\.value.id)
        while !merge.isFinished {
            let batch = try await merge.next(10)
            ids += batch.elements.map(\.value.id)
            if batch.elements.isEmpty { break }
        }
        #expect(ids == ["A0", "A1", "A2", "A3"])
    }

    // MARK: Serie i autorzy

    @Test func seriesWithTheSameNameAreOne() async throws {
        let a = [("sa1", "Diuna"), ("sa2", "Kroniki"), ("sa3", "Wiedźmin")]
        let b = [("sb1", "Achaja"), ("sb2", "kroniki"), ("sb3", "Wiedźmin"), ("sb4", "Zew")]
        for (library, list) in [("A", a), ("B", b)] {
            StubServer.handle("GET api/libraries/\(library)/series") { request in
                let q = query(request)
                let page = Int(q["page"] ?? "0") ?? 0, limit = Int(q["limit"] ?? "0") ?? 0
                let slice = list.dropFirst(page * limit).prefix(limit)
                return .json(#"{"results":[\#(slice.map { seriesJSON($0.0, $0.1, library: library) }.joined(separator: ","))],"total":\#(list.count)}"#)
            }
        }
        let grouped = catalog(["A", "B"]).series(pageSize: 2)
        _ = try await grouped.loadMore(2)
        var all = try await grouped.loadMore(100)
        #expect(grouped.isFinished)
        all = grouped.entities
        #expect(all.map(\.first.name) == ["Achaja", "Diuna", "Kroniki", "Wiedźmin", "Zew"])
        let witcher = try #require(all.first { $0.first.name == "Wiedźmin" })
        #expect(Set(witcher.members.map(\.value.id)) == ["sa3", "sb3"])
        #expect(Set(witcher.libraryIDs) == ["A", "B"])
        let chronicles = try #require(all.first { $0.first.name == "Kroniki" })
        #expect(chronicles.members.count == 2)
    }

    @Test func seriesBooksFromBothLibrariesInVolumeOrder() async throws {
        func book(_ id: String, _ library: String, _ series: String, _ sequence: String) -> String {
            #"{"id":"\#(id)","libraryId":"\#(library)","mediaType":"book","media":{"metadata":{"title":"\#(id)","series":{"id":"\#(series)","name":"Wiedźmin","sequence":"\#(sequence)"}}}}"#
        }
        let bodyA = #"{"results":[\#(book("a1", "A", "sa", "1")),\#(book("a3", "A", "sa", "3"))],"total":2}"#
        let bodyB = #"{"results":[\#(book("b2", "B", "sb", "2")),\#(book("b10", "B", "sb", "10"))],"total":2}"#
        StubServer.on("GET api/libraries/A/items", .json(bodyA))
        StubServer.on("GET api/libraries/B/items", .json(bodyB))
        let entity = MergedEntity(id: "wiedźmin", members: [
            Tagged(libraryID: "A", value: AudiobookshelfClient.Series(id: "sa", name: "Wiedźmin", description: nil, books: nil)),
            Tagged(libraryID: "B", value: AudiobookshelfClient.Series(id: "sb", name: "Wiedźmin", description: nil, books: nil)),
        ])
        let books = try await catalog(["A", "B"]).books(of: entity)
        #expect(books.value.map(\.id) == ["a1", "b2", "a3", "b10"])
        let filters = StubServer.requests.compactMap { query($0.request)["filter"] }
        #expect(Set(filters) == [AudiobookshelfClient.filter("series", "sa"), AudiobookshelfClient.filter("series", "sb")])
    }

    // MARK: Półki i wyszukiwanie

    @Test func shelvesMergedAndDeduplicated() async throws {
        func shelf(_ id: String, _ items: [(String, Double)]) -> String {
            let entities = items.map { #"{"id":"\#($0.0)","libraryId":"X","mediaType":"book","addedAt":\#($0.1),"media":{"metadata":{"title":"\#($0.0)"}}}"# }
            return #"{"id":"\#(id)","label":"\#(id)","type":"book","entities":[\#(entities.joined(separator: ","))]}"#
        }
        StubServer.on("GET api/libraries/A/personalized", .json("[" + [
            shelf("continue-listening", [("a1", 1)]),
            shelf("recently-added", [("a1", 10), ("a2", 30)]),
            shelf("discover", [("a1", 0), ("a5", 0)]),
        ].joined(separator: ",") + "]"))
        StubServer.on("GET api/libraries/B/personalized", .json("[" + [
            shelf("continue-listening", [("b1", 1)]),
            shelf("recently-added", [("b2", 20)]),
            shelf("discover", [("b5", 0)]),
        ].joined(separator: ",") + "]"))
        StubServer.on("GET api/libraries/C/personalized", .status(500))
        let shelves = try await catalog(["A", "B", "C"]).shelves(lastUpdate: ["a1": 100, "b1": 200])
        #expect(shelves.continueListening.map(\.id) == ["b1", "a1"])
        #expect(shelves.recentlyAdded.map(\.id) == ["a2", "b2", "a1"])
        // a1 jest już wyżej — nie powtarza się w „Odkrywaj”.
        #expect(shelves.discover.map(\.id) == ["b5", "a5"] || shelves.discover.map(\.id) == ["a5", "b5"])
        #expect(shelves.failures.map(\.libraryID) == ["C"])
    }

    @Test func searchGroupsAcrossLibraries() async throws {
        func item(_ id: String) -> String { #"{"libraryItem":{"id":"\#(id)","libraryId":"X","mediaType":"book","media":{"metadata":{"title":"\#(id)"}}}}"# }
        StubServer.on("GET api/libraries/A/search", .json(#"{"book":[\#(item("a1")),\#(item("a2"))],"series":[{"series":{"id":"sa","name":"Wiedźmin"},"books":[]}],"authors":[{"id":"au1","name":"Andrzej Sapkowski"}],"narrators":[{"name":"Krzysztof Gosztyła","numBooks":2}]}"#))
        StubServer.on("GET api/libraries/B/search", .json(#"{"book":[\#(item("b1"))],"series":[{"series":{"id":"sb","name":"wiedźmin"},"books":[]}],"authors":[{"id":"au2","name":"Andrzej Sapkowski"}],"narrators":[{"name":"Krzysztof Gosztyła","numBooks":3}]}"#))
        let results = try await catalog(["A", "B"]).search("wied")
        #expect(results.books.map(\.id) == ["a1", "b1", "a2"])
        #expect(results.series.count == 1)
        #expect(results.series.first?.members.count == 2)
        #expect(results.authors.count == 1)
        #expect(Set(results.authors.first?.members.map(\.value.id) ?? []) == ["au1", "au2"])
        #expect(results.narrators.first?.count == 5)
        #expect(results.failures.isEmpty)
    }

    @Test func searchFailsOnlyWhenEveryLibraryFails() async throws {
        StubServer.on("GET api/libraries/A/search", .status(500))
        StubServer.on("GET api/libraries/B/search", .status(500))
        await #expect(throws: AudiobookshelfClient.APIError.self) { try await catalog(["A", "B"]).search("x") }
    }

    @Test func loadReadsSortingSetting() async throws {
        StubServer.on("GET api/libraries", .json(#"{"libraries":[{"id":"A","name":"Książki","mediaType":"book","folders":[]},{"id":"P","name":"Podcasty","mediaType":"podcast","folders":[]}]}"#))
        StubServer.on("POST api/authorize", .json(#"{"user":{},"serverSettings":{"sortingIgnorePrefix":true,"sortingPrefixes":["the","a"]}}"#))
        let combined = try await CombinedLibraries.load(auth: ListeningAuth(client: StubServer.client(), apiKey: "K"))
        #expect(combined.libraries.map(\.id) == ["A"])
        #expect(combined.podcastLibraries.map(\.id) == ["P"])
        #expect(combined.ignoresTitlePrefix)
        #expect(!combined.hasSeveralLibraries)
        _ = libraries([])
    }
}
}
