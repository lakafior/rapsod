// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Wszystkie biblioteki książek serwera jako jedna (etap 10d): lista pozycji z jednym
/// sortowaniem, serie i autorzy bez powtórzeń, wspólne półki strony startowej i wyszukiwanie.
/// Serwer odpowiada zawsze w obrębie jednej biblioteki — tu każda jest pytana osobno, a wyniki
/// scalane (`SortedMerge`). Bez interfejsu; używa tego klient iOS.
@MainActor
public final class CombinedLibraries {
    public typealias Client = AudiobookshelfClient

    /// Sortowanie wspólnej listy pozycji — tylko takie, które da się odtworzyć po stronie
    /// klienta z pól odpowiedzi (inaczej scalanie nie wiedziałoby, co jest pierwsze).
    public enum ItemSort: String, CaseIterable, Sendable, Codable {
        case title, author, addedAt, duration, lastListened

        /// Klucz sortowania w zapytaniu `/libraries/:id/items`.
        public var serverKey: String {
            switch self {
            case .title: "media.metadata.title"
            case .author: "media.metadata.authorName"
            case .addedAt: "addedAt"
            case .duration: "media.duration"
            case .lastListened: "progress"
            }
        }

        public var defaultDescending: Bool { self == .addedAt || self == .lastListened }
    }

    /// Filtr postępu (`progress.*` serwera).
    public enum ProgressFilter: String, CaseIterable, Sendable, Codable {
        case notStarted = "not-started"
        case inProgress = "in-progress"
        case finished
    }

    public let auth: ListeningAuth
    /// Biblioteki książek dostępne dla konta, w kolejności serwera.
    public let libraries: [Client.Library]
    /// Biblioteki podcastów (zakładka „Podcasty” w następnym etapie).
    public let podcastLibraries: [Client.Library]
    /// `sortingIgnorePrefix` serwera: tytuły i serie sortowane bez „The”, „A”…
    public let ignoresTitlePrefix: Bool

    public init(auth: ListeningAuth, libraries: [Client.Library], ignoresTitlePrefix: Bool) {
        self.auth = auth
        self.libraries = libraries.filter { $0.mediaType != "podcast" }
        podcastLibraries = libraries.filter { $0.mediaType == "podcast" }
        self.ignoresTitlePrefix = ignoresTitlePrefix
    }

    /// Biblioteki i ustawienia sortowania z serwera.
    public static func load(auth: ListeningAuth) async throws -> CombinedLibraries {
        async let libraries = auth.perform { try await $0.libraries(token: $1) }
        // Ustawienie sortowania nie jest konieczne do działania — bez niego sortujemy po pełnym tytule.
        async let settings = try? auth.perform { try await $0.sortingSettings(token: $1) }
        let ignores = await settings?.sortingIgnorePrefix ?? false
        return CombinedLibraries(auth: auth, libraries: try await libraries, ignoresTitlePrefix: ignores)
    }

    public var hasSeveralLibraries: Bool { libraries.count > 1 }

    public func libraryName(_ id: String) -> String? {
        (libraries + podcastLibraries).first { $0.id == id }?.name
    }

    private func scope(_ libraryID: String?) -> [Client.Library] {
        guard let libraryID else { return libraries }
        return libraries.filter { $0.id == libraryID }
    }

    // MARK: Pozycje

    /// Wspólna lista pozycji. `lastUpdate` — czas ostatniego słuchania pozycji (ms, z `/api/me`),
    /// potrzebny tylko przy `lastListened`: serwer sortuje wtedy po polu, którego nie ma w odpowiedzi.
    public func items(
        sort: ItemSort,
        descending: Bool,
        progress filter: ProgressFilter? = nil,
        serverFilter: String? = nil,
        libraryID: String? = nil,
        lastUpdate: [String: Double] = [:],
        pageSize: Int = 40
    ) -> SortedMerge<Client.LibraryItem> {
        // Serwer przyjmuje jeden filtr naraz: postęp albo inny (np. lektor `narrators.*`).
        let filterText = filter.map { Client.filter("progress", $0.rawValue) } ?? serverFilter
        let sources = scope(libraryID).map { library in
            MergeSource<Client.LibraryItem>(libraryID: library.id, libraryName: library.name) { [auth] page, limit in
                try await auth.perform {
                    try await $0.itemsPage(libraryID: library.id, page: page, limit: limit, sort: sort.serverKey, descending: descending, filter: filterText, token: $1)
                }
            }
        }
        return SortedMerge(sources: sources, pageSize: pageSize, areInIncreasingOrder: Self.itemOrder(sort: sort, descending: descending, ignoresPrefix: ignoresTitlePrefix, lastUpdate: lastUpdate))
    }

    /// Porządek pozycji zgodny z serwerem (`libraryItemsBookFilters.getOrder` w v2.38.0 —
    /// opisany tu słowami, nie przepisany): tytuł i autor przez `COLLATE NOCASE`, przy autorze
    /// tytuł jako drugi klucz; puste wartości (NULL) najmniejsze; „ostatnio słuchane” —
    /// pozycje bez postępu zawsze na końcu.
    public nonisolated static func itemOrder(sort: ItemSort, descending: Bool, ignoresPrefix: Bool, lastUpdate: [String: Double] = [:]) -> @Sendable (Client.LibraryItem, Client.LibraryItem) -> Bool {
        @Sendable func title(_ item: Client.LibraryItem) -> String {
            ServerCollation.titleKey(title: item.media.metadata.title, withPrefixAtEnd: item.media.metadata.titleIgnorePrefix, ignoresPrefix: ignoresPrefix)
        }
        @Sendable func ascending(_ a: Client.LibraryItem, _ b: Client.LibraryItem) -> Int {
            switch sort {
            case .title:
                return ServerCollation.compare(title(a), title(b))
            case .author:
                let byAuthor = ServerCollation.compare(a.media.metadata.authorName ?? "", b.media.metadata.authorName ?? "")
                return byAuthor != 0 ? byAuthor : ServerCollation.compare(title(a), title(b))
            case .addedAt:
                return compareNumbers(a.addedAt, b.addedAt)
            case .duration:
                return compareNumbers(a.media.duration, b.media.duration)
            case .lastListened:
                return compareNumbers(lastUpdate[a.id], lastUpdate[b.id])
            }
        }
        return { a, b in
            if sort == .lastListened {
                // NULLS LAST w obu kierunkach.
                switch (lastUpdate[a.id], lastUpdate[b.id]) {
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                default: break
                }
            }
            let result = ascending(a, b)
            return descending ? result > 0 : result < 0
        }
    }

    // MARK: Serie i autorzy

    /// Serie ze wszystkich bibliotek po nazwie; seria o tej samej nazwie w kilku bibliotekach to jedna pozycja.
    public func series(descending: Bool = false, pageSize: Int = 40) -> GroupedMerge<Client.Series> {
        let ignores = ignoresTitlePrefix
        let sources = libraries.map { library in
            MergeSource<Client.Series>(libraryID: library.id, libraryName: library.name) { [auth] page, limit in
                try await auth.perform {
                    try await $0.seriesPage(libraryID: library.id, page: page, limit: limit, sort: "name", descending: descending, token: $1)
                }
            }
        }
        let merge = SortedMerge(sources: sources, pageSize: pageSize) { (a: Client.Series, b: Client.Series) in
            let result = ServerCollation.compare(
                ServerCollation.titleKey(title: a.name, withPrefixAtEnd: a.nameIgnorePrefix, ignoresPrefix: ignores),
                ServerCollation.titleKey(title: b.name, withPrefixAtEnd: b.nameIgnorePrefix, ignoresPrefix: ignores)
            )
            return descending ? result > 0 : result < 0
        }
        return GroupedMerge(merge: merge) { $0.name }
    }

    /// Autorzy ze wszystkich bibliotek po nazwie, bez powtórzeń.
    public func authors(descending: Bool = false, pageSize: Int = 40) -> GroupedMerge<Client.Author> {
        let sources = libraries.map { library in
            MergeSource<Client.Author>(libraryID: library.id, libraryName: library.name) { [auth] page, limit in
                try await auth.perform {
                    try await $0.authorsPage(libraryID: library.id, page: page, limit: limit, sort: "name", descending: descending, token: $1)
                }
            }
        }
        let merge = SortedMerge(sources: sources, pageSize: pageSize) { (a: Client.Author, b: Client.Author) in
            let result = ServerCollation.compare(a.name, b.name)
            return descending ? result > 0 : result < 0
        }
        return GroupedMerge(merge: merge) { $0.name }
    }

    /// Wynik zebrany z kilku bibliotek z informacją o tych, które nie odpowiedziały.
    public struct Partial<Value: Sendable>: Sendable {
        public let value: Value
        public let failures: [LibraryFailure]
    }

    /// Książki serii (wszystkich członków o tej samej nazwie) w kolejności tomów.
    public func books(of series: MergedEntity<Client.Series>) async throws -> Partial<[Client.LibraryItem]> {
        let parts = try await fanOut(series.members.map { member in
            (member.libraryID, { @MainActor [auth] () async throws -> [Client.LibraryItem] in
                try await auth.perform {
                    try await $0.itemsPage(libraryID: member.libraryID, page: 0, limit: 0, sort: "sequence", descending: false,
                                           filter: Client.filter("series", member.value.id), token: $1)
                }.results.elements
            })
        })
        let seriesIDs = Set(series.members.map(\.value.id))
        let books = parts.value.flatMap(\.self).sorted { a, b in
            Self.compareSequence(Self.sequence(a, in: seriesIDs), Self.sequence(b, in: seriesIDs)) < 0
        }
        return Partial(value: books, failures: parts.failures)
    }

    private static func sequence(_ item: Client.LibraryItem, in ids: Set<String>) -> String? {
        (item.media.metadata.series?.values ?? []).first { ids.contains($0.id) }?.sequence
    }

    /// Tomy liczbowo („2” przed „10”, „1.5” między nimi); bez numeru na końcu.
    public nonisolated static func compareSequence(_ a: String?, _ b: String?) -> Int {
        switch (a.flatMap(Double.init), b.flatMap(Double.init)) {
        case (let x?, let y?): return x == y ? 0 : (x < y ? -1 : 1)
        case (nil, _?): return 1
        case (_?, nil): return -1
        case (nil, nil):
            switch (a, b) {
            case (nil, nil): return 0
            case (nil, _): return 1
            case (_, nil): return -1
            case (let x?, let y?): return x.localizedStandardCompare(y) == .orderedAscending ? -1 : (x == y ? 0 : 1)
            }
        }
    }

    /// Autor złożony z autorów o tej samej nazwie w kilku bibliotekach.
    public struct AuthorPage: Sendable {
        public let name: String
        public let description: String?
        /// Autor, którego zdjęcie pokazać (pierwszy z opisem albo zdjęciem).
        public let imageAuthorID: String?
        public let books: [Client.LibraryItem]
        /// Serie autora, połączone po nazwie, z książkami w kolejności tomów.
        public let series: [(name: String, books: [Client.LibraryItem])]
    }

    public func author(_ author: MergedEntity<Client.Author>) async throws -> Partial<AuthorPage> {
        let parts = try await fanOut(author.members.map { member in
            (member.libraryID, { @MainActor [auth] () async throws -> Client.AuthorDetail in
                try await auth.perform { try await $0.author(id: member.value.id, token: $1) }
            })
        })
        let details = parts.value
        let ignores = ignoresTitlePrefix
        let books = details.flatMap { $0.libraryItems?.elements ?? [] }.sorted { a, b in
            ServerCollation.compare(
                ServerCollation.titleKey(title: a.media.metadata.title, withPrefixAtEnd: a.media.metadata.titleIgnorePrefix, ignoresPrefix: ignores),
                ServerCollation.titleKey(title: b.media.metadata.title, withPrefixAtEnd: b.media.metadata.titleIgnorePrefix, ignoresPrefix: ignores)
            ) < 0
        }
        var seriesOrder: [String] = []
        var seriesByKey: [String: (name: String, books: [Client.LibraryItem], ids: Set<String>)] = [:]
        for detail in details {
            for series in detail.series?.elements ?? [] {
                let key = ServerCollation.key(series.name)
                if seriesByKey[key] == nil {
                    seriesOrder.append(key)
                    seriesByKey[key] = (series.name, [], [])
                }
                seriesByKey[key]!.books += series.items.elements
                seriesByKey[key]!.ids.insert(series.id)
            }
        }
        let series = seriesOrder.sorted { ServerCollation.compare($0, $1) < 0 }.compactMap { key -> (name: String, books: [Client.LibraryItem])? in
            guard let entry = seriesByKey[key] else { return nil }
            let sorted = entry.books.sorted { Self.compareSequence(Self.sequence($0, in: entry.ids), Self.sequence($1, in: entry.ids)) < 0 }
            return (entry.name, sorted)
        }
        let primary = details.first { $0.description?.isEmpty == false || $0.imagePath != nil } ?? details.first
        let page = AuthorPage(name: primary?.name ?? author.first.name, description: primary?.description, imageAuthorID: primary?.imagePath != nil ? primary?.id : nil, books: books, series: series)
        return Partial(value: page, failures: parts.failures)
    }

    /// Seria albo autor znani z jednej biblioteki (np. ze strony pozycji) razem z tymi
    /// o tej samej nazwie w pozostałych bibliotekach — szukanych wyszukiwarką serwera.
    /// Gdy wyszukiwanie zawiedzie, zostaje sama znana encja.
    public func seriesEntity(_ seed: Tagged<Client.Series>) async -> MergedEntity<Client.Series> {
        let key = ServerCollation.key(seed.value.name)
        var members = [seed]
        for (libraryID, found) in await searchOthers(than: seed.libraryID, for: seed.value.name) {
            for hit in found.series?.elements ?? [] where ServerCollation.key(hit.series.name) == key {
                members.append(Tagged(libraryID: libraryID, value: Client.Series(id: hit.series.id, name: hit.series.name, description: nil, books: nil)))
            }
        }
        return MergedEntity(id: key, members: members)
    }

    public func authorEntity(_ seed: Tagged<Client.Author>) async -> MergedEntity<Client.Author> {
        let key = ServerCollation.key(seed.value.name)
        var members = [seed]
        for (libraryID, found) in await searchOthers(than: seed.libraryID, for: seed.value.name) {
            for author in found.authors?.elements ?? [] where ServerCollation.key(author.name) == key {
                members.append(Tagged(libraryID: libraryID, value: author))
            }
        }
        return MergedEntity(id: key, members: members)
    }

    private func searchOthers(than libraryID: String, for name: String) async -> [(String, Client.SearchResults)] {
        let others = libraries.filter { $0.id != libraryID }
        guard !others.isEmpty, let parts = try? await fanOut(others.map { library in
            (library.id, { @MainActor [auth] () async throws -> Client.SearchResults in
                try await auth.perform { try await $0.search(libraryID: library.id, query: name, token: $1) }
            })
        }) else { return [] }
        return Array(zip(parts.libraryIDs, parts.value))
    }

    // MARK: Strona startowa

    public struct Shelves: Sendable {
        public var continueListening: [Client.LibraryItem] = []
        public var continueSeries: [Client.LibraryItem] = []
        public var recentlyAdded: [Client.LibraryItem] = []
        public var discover: [Client.LibraryItem] = []
        /// Ukończone, od ostatnio słuchanych (`listen-again`).
        public var listenAgain: [Client.LibraryItem] = []
        /// Ostatnio dodane serie (`recent-series`), połączone po nazwie z kilku bibliotek.
        public var recentSeries: [MergedEntity<Client.Series>] = []
        /// Nowi autorzy (`newest-authors`), połączeni po nazwie.
        public var newestAuthors: [MergedEntity<Client.Author>] = []
        public var failures: [LibraryFailure] = []

        public var isEmpty: Bool {
            continueListening.isEmpty && continueSeries.isEmpty && recentlyAdded.isEmpty && discover.isEmpty
                && listenAgain.isEmpty && recentSeries.isEmpty && newestAuthors.isEmpty
        }
    }

    /// Półki z `personalized` każdej biblioteki (równolegle), scalone:
    /// „Słuchaj dalej” po czasie ostatniego słuchania (`lastUpdate` z `/api/me`; półka serwera
    /// już pomija ukryte z „Słuchaj dalej”), „Ostatnio dodane” po dacie dodania, „Kolejne w serii”
    /// i „Odkrywaj” na przemian z bibliotek (ich kolejność ustala serwer, a „Odkrywaj” jest losowe).
    /// Pozycja pokazana na wcześniejszej półce nie powtarza się w „Odkrywaj”.
    public func shelves(lastUpdate: [String: Double], limit: Int = 12) async throws -> Shelves {
        let parts = try await fanOut(libraries.map { library in
            (library.id, { @MainActor [auth] () async throws -> [Client.Shelf] in
                try await auth.perform { try await $0.personalized(libraryID: library.id, token: $1) }
            })
        })
        func items(_ id: String) -> [[Client.LibraryItem]] {
            parts.value.map { shelves in
                guard let shelf = shelves.first(where: { $0.id == id }), case .items(let items) = shelf.entities else { return [] }
                return items
            }
        }
        var result = Shelves(failures: parts.failures)
        result.continueListening = Array(Self.unique(items("continue-listening").flatMap(\.self)).sorted {
            (lastUpdate[$0.id] ?? $0.progressLastUpdate ?? 0) > (lastUpdate[$1.id] ?? $1.progressLastUpdate ?? 0)
        }.prefix(limit))
        result.recentlyAdded = Array(Self.unique(items("recently-added").flatMap(\.self)).sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }.prefix(limit))
        result.continueSeries = Array(Self.unique(Self.interleave(items("continue-series"))).prefix(limit))
        let shown = Set((result.continueListening + result.recentlyAdded + result.continueSeries).map(\.id))
        result.discover = Array(Self.unique(Self.interleave(items("discover"))).filter { !shown.contains($0.id) }.prefix(limit))
        result.listenAgain = Array(Self.unique(items("listen-again").flatMap(\.self)).sorted {
            (lastUpdate[$0.id] ?? 0) > (lastUpdate[$1.id] ?? 0)
        }.prefix(limit))
        result.recentSeries = Array(Self.mergedByName(zip(parts.libraryIDs, parts.value).map { libraryID, shelves in
            shelves.first { $0.id == "recent-series" }.flatMap { shelf -> [Tagged<Client.Series>]? in
                guard case .series(let list) = shelf.entities else { return nil }
                return list.map { Tagged(libraryID: libraryID, value: $0) }
            } ?? []
        }, name: \.name).prefix(limit))
        result.newestAuthors = Array(Self.mergedByName(zip(parts.libraryIDs, parts.value).map { libraryID, shelves in
            shelves.first { $0.id == "newest-authors" }.flatMap { shelf -> [Tagged<Client.Author>]? in
                guard case .authors(let list) = shelf.entities else { return nil }
                return list.map { Tagged(libraryID: libraryID, value: $0) }
            } ?? []
        }, name: \.name).prefix(limit))
        return result
    }

    /// Encje z kilku bibliotek na przemian, połączone po nazwie (jak w wyszukiwaniu).
    nonisolated static func mergedByName<Element: Sendable>(_ lists: [[Tagged<Element>]], name: (Element) -> String) -> [MergedEntity<Element>] {
        var result: [MergedEntity<Element>] = []
        var index: [String: Int] = [:]
        for tagged in interleave(lists) {
            let key = ServerCollation.key(name(tagged.value))
            if let position = index[key] {
                result[position].members.append(tagged)
            } else {
                index[key] = result.count
                result.append(MergedEntity(id: key, members: [tagged]))
            }
        }
        return result
    }

    /// Na przemian: pierwszy z każdej listy, potem drugi…
    public nonisolated static func interleave<T>(_ lists: [[T]]) -> [T] {
        var out: [T] = []
        let longest = lists.map(\.count).max() ?? 0
        for index in 0..<longest {
            for list in lists where index < list.count { out.append(list[index]) }
        }
        return out
    }

    private nonisolated static func unique(_ items: [Client.LibraryItem]) -> [Client.LibraryItem] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }

    // MARK: Wyszukiwanie

    public struct SearchResults: Sendable {
        public var books: [Client.LibraryItem] = []
        public var series: [MergedEntity<Client.Series>] = []
        public var authors: [MergedEntity<Client.Author>] = []
        public var narrators: [(name: String, count: Int)] = []
        public var failures: [LibraryFailure] = []

        public var isEmpty: Bool { books.isEmpty && series.isEmpty && authors.isEmpty && narrators.isEmpty }
    }

    /// Szukanie we wszystkich bibliotekach naraz. Książki na przemian z bibliotek (każda ma
    /// własną kolejność trafności), serie i autorzy połączeni po nazwie, lektorzy z sumą książek.
    public func search(_ text: String) async throws -> SearchResults {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SearchResults() }
        let parts = try await fanOut(libraries.map { library in
            (library.id, { @MainActor [auth] () async throws -> Client.SearchResults in
                try await auth.perform { try await $0.search(libraryID: library.id, query: query, token: $1) }
            })
        })
        var result = SearchResults(failures: parts.failures)
        let libraryIDs = parts.libraryIDs
        result.books = Self.interleave(parts.value.map { ($0.book?.elements ?? []).map(\.libraryItem) })

        var seriesIndex: [String: Int] = [:]
        var authorIndex: [String: Int] = [:]
        var narratorIndex: [String: Int] = [:]
        for (libraryID, found) in zip(libraryIDs, parts.value) {
            for hit in found.series?.elements ?? [] {
                let series = Client.Series(id: hit.series.id, name: hit.series.name, description: nil, books: hit.books)
                let key = ServerCollation.key(series.name)
                if let index = seriesIndex[key] {
                    result.series[index].members.append(Tagged(libraryID: libraryID, value: series))
                } else {
                    seriesIndex[key] = result.series.count
                    result.series.append(MergedEntity(id: key, members: [Tagged(libraryID: libraryID, value: series)]))
                }
            }
            for author in found.authors?.elements ?? [] {
                let key = ServerCollation.key(author.name)
                if let index = authorIndex[key] {
                    result.authors[index].members.append(Tagged(libraryID: libraryID, value: author))
                } else {
                    authorIndex[key] = result.authors.count
                    result.authors.append(MergedEntity(id: key, members: [Tagged(libraryID: libraryID, value: author)]))
                }
            }
            for narrator in found.narrators?.elements ?? [] {
                let key = ServerCollation.key(narrator.name)
                if let index = narratorIndex[key] {
                    result.narrators[index].count += narrator.count
                } else {
                    narratorIndex[key] = result.narrators.count
                    result.narrators.append((narrator.name, narrator.count))
                }
            }
        }
        return result
    }

    // MARK: Pomocnicze

    struct FanOut<Value: Sendable>: Sendable {
        let value: [Value]
        /// Biblioteki, które odpowiedziały — w tej samej kolejności co `value`.
        let libraryIDs: [String]
        let failures: [LibraryFailure]
    }

    /// To samo zapytanie do kilku bibliotek naraz. Błąd jednej trafia do `failures`; gdy nie
    /// odpowie żadna — rzucany jest jej błąd. Anulowanie przerywa całość.
    func fanOut<Value: Sendable>(_ requests: [(String, @MainActor () async throws -> Value)]) async throws -> FanOut<Value> {
        let tasks = requests.map { request in
            let operation = request.1
            return Task { @MainActor () -> Result<Value, any Error> in
                do { return .success(try await operation()) } catch { return .failure(error) }
            }
        }
        let results = await concurrently(tasks).enumerated().map { ($0.offset, $0.element) }
        try Task.checkCancellation()
        var values: [Value] = []
        var ids: [String] = []
        var failures: [LibraryFailure] = []
        var firstError: (any Error)?
        for (index, result) in results {
            let libraryID = requests[index].0
            switch result {
            case .success(let value):
                values.append(value)
                ids.append(libraryID)
            case .failure(let error):
                if SortedMerge<Client.LibraryItem>.isCancellation(error) { throw CancellationError() }
                firstError = firstError ?? error
                failures.append(LibraryFailure(libraryID: libraryID, libraryName: libraryName(libraryID) ?? libraryID, message: error.localizedDescription))
            }
        }
        if values.isEmpty, let firstError { throw firstError }
        return FanOut(value: values, libraryIDs: ids, failures: failures)
    }
}

extension AudiobookshelfClient {
    /// Ustawienia serwera potrzebne do sortowania jak serwer (`POST /api/authorize`
    /// zwraca `serverSettings` każdemu zalogowanemu, także kluczowi API słuchacza).
    public struct SortingSettings: Decodable, Sendable {
        public let sortingIgnorePrefix: Bool?
        public let sortingPrefixes: [String]?
    }

    public func sortingSettings(token: String) async throws -> SortingSettings {
        struct Response: Decodable { let serverSettings: SortingSettings }
        return try decode(Response.self, from: await send("POST", "api/authorize", token: token)).serverSettings
    }
}

private func compareNumbers(_ a: Double?, _ b: Double?) -> Int {
    switch (a, b) {
    case (nil, nil): return 0
    case (nil, _): return -1
    case (_, nil): return 1
    case (let x?, let y?): return x == y ? 0 : (x < y ? -1 : 1)
    }
}
