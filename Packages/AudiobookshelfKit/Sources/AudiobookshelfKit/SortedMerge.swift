// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Scalanie list z kilku bibliotek (etap 10d). Serwer nie ma zapytań przekrojowych: każda
// biblioteka jest pytana osobno o kolejne strony, z tym samym sortowaniem, a klient scala
// posortowane strumienie (jak w sortowaniu przez scalanie). Zasada: element wychodzi dopiero
// wtedy, gdy każda niewyczerpana biblioteka ma w buforze swój następny element — wtedy
// najmniejsza z głów jest na pewno następna. Bufory nigdy nie są przestawiane, więc nawet gdy
// porównanie klienta minimalnie różni się od kolejności serwera, nic nie ginie ani się nie
// powtarza — najwyżej przeplot dwóch bibliotek jest o włos inny.

/// Porównanie tekstu tak, jak robi to serwer (SQLite, `COLLATE NOCASE`): litery A–Z ASCII
/// zrównane z a–z, poza tym zwykłe porównanie bajtów UTF-8. Polskie litery spoza ASCII
/// („Ł”, „Ś”) wypadają więc za „z” — tak samo jak w jednej bibliotece na serwerze.
/// Napisane od zera według opisu sortowania NOCASE w dokumentacji SQLite.
public enum ServerCollation {
    public static func compare(_ a: String, _ b: String) -> Int {
        var left = a.utf8.makeIterator()
        var right = b.utf8.makeIterator()
        while true {
            switch (left.next(), right.next()) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case (let x?, let y?):
                let l = fold(x), r = fold(y)
                if l != r { return l < r ? -1 : 1 }
            }
        }
    }

    /// Klucz równości w tym samym sensie (do łączenia serii i autorów o tej samej nazwie).
    public static func key(_ text: String) -> String {
        String(decoding: text.trimmingCharacters(in: .whitespacesAndNewlines).utf8.map(fold), as: UTF8.self)
    }

    private static func fold(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    /// Klucz sortowania tytułu przy włączonym „ignoruj przedrostki” serwera. Serwer sortuje po
    /// tytule bez przedrostka („Hobbit”), a w odpowiedzi podaje go przeniesionego na koniec
    /// („Hobbit, The”) — z tej pary odtwarzamy tytuł bez przedrostka.
    public static func titleKey(title: String?, withPrefixAtEnd moved: String?, ignoresPrefix: Bool) -> String {
        let title = title ?? ""
        guard ignoresPrefix, let moved, moved != title, let comma = moved.range(of: ", ", options: .backwards) else { return title }
        let prefix = moved[comma.upperBound...]
        guard !prefix.isEmpty, title.count > prefix.count,
              title.prefix(prefix.count).lowercased() == prefix.lowercased(),
              title.dropFirst(prefix.count).first == " " else { return title }
        return String(title.dropFirst(prefix.count + 1))
    }
}

/// Element listy z identyfikatorem biblioteki, z której pochodzi.
public struct Tagged<Element: Sendable>: Sendable {
    public let libraryID: String
    public let value: Element

    public init(libraryID: String, value: Element) {
        self.libraryID = libraryID
        self.value = value
    }
}

extension Tagged: Identifiable where Element: Identifiable, Element.ID == String {
    public var id: String { libraryID + "/" + value.id }
}

/// Biblioteka, która nie odpowiedziała. Pozostałe działają dalej.
public struct LibraryFailure: Sendable, Hashable, Identifiable {
    public let libraryID: String
    public let libraryName: String
    public let message: String
    public var id: String { libraryID }

    public init(libraryID: String, libraryName: String, message: String) {
        self.libraryID = libraryID
        self.libraryName = libraryName
        self.message = message
    }
}

/// Jedno źródło scalania: biblioteka i pobieranie jej kolejnych stron (od 0).
public struct MergeSource<Element: Decodable & Sendable> {
    public let libraryID: String
    public let libraryName: String
    public let fetch: @MainActor (_ page: Int, _ limit: Int) async throws -> AudiobookshelfClient.Page<Element>

    public init(libraryID: String, libraryName: String, fetch: @escaping @MainActor (_ page: Int, _ limit: Int) async throws -> AudiobookshelfClient.Page<Element>) {
        self.libraryID = libraryID
        self.libraryName = libraryName
        self.fetch = fetch
    }
}

/// Scalanie posortowanych, stronicowanych list z kilku bibliotek.
///
/// Koszt: pierwsze wywołanie pyta każdą bibliotekę o jedną stronę (równolegle); później
/// biblioteka jest pytana dopiero wtedy, gdy jej bufor się opróżni — średnio jedno zapytanie
/// na `pageSize` wydanych elementów, najwyżej tyle zapytań na raz, ile bibliotek.
///
/// Błędy: biblioteka, która nie odpowie na pierwszą stronę, wypada z listy (jest w `failures`).
/// Błąd dalszej strony zatrzymuje scalanie (`stalled`) — pominięcie biblioteki w środku
/// zepsułoby kolejność po jej powrocie; kolejne `next` próbuje ją pobrać od nowa.
/// Anulowanie zadania nie zmienia stanu: niepobrana strona zostanie pobrana przy następnym `next`.
@MainActor
public final class SortedMerge<Element: Decodable & Sendable & Identifiable> where Element.ID == String {
    public struct Batch: Sendable {
        public let elements: [Tagged<Element>]
        /// Wszystkie biblioteki wyczerpane.
        public let isFinished: Bool
        /// Biblioteka, której następna strona się nie pobrała — dalsze elementy czekają na nią.
        public let stalled: LibraryFailure?
    }

    private struct Stream {
        let source: MergeSource<Element>
        var buffer: [Element] = []
        var head = 0
        var nextPage = 0
        var fetched = 0
        var total: Int?
        var isDone = false
        /// Nie odpowiedziała na pierwszą stronę — pominięta.
        var isExcluded = false
        var pendingError: LibraryFailure?

        var hasHead: Bool { head < buffer.count }
        var needsFetch: Bool { !isDone && !isExcluded && !hasHead }
    }

    public let pageSize: Int
    private var streams: [Stream]
    private let areInIncreasingOrder: (Element, Element) -> Bool
    private var seen: Set<String> = []
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Biblioteki pominięte, bo nie odpowiedziały na pierwsze zapytanie.
    public private(set) var failures: [LibraryFailure] = []
    /// Wszystkie biblioteki wyczerpane.
    public var isFinished: Bool { streams.allSatisfy { ($0.isDone || $0.isExcluded) && !$0.hasHead } }
    /// Suma liczników bibliotek (gdy każda już odpowiedziała).
    public var total: Int? {
        var sum = 0
        for stream in streams where !stream.isExcluded {
            guard let total = stream.total else { return nil }
            sum += total
        }
        return sum
    }
    /// Liczba wysłanych zapytań (do testów i pomiarów).
    public private(set) var requestCount = 0

    /// `areInIncreasingOrder` — porządek docelowej listy (z kierunkiem), taki sam jak serwera.
    /// Przy remisie wygrywa biblioteka wcześniejsza na liście `sources`.
    public init(sources: [MergeSource<Element>], pageSize: Int = 40, areInIncreasingOrder: @escaping (Element, Element) -> Bool) {
        self.pageSize = pageSize
        streams = sources.map { Stream(source: $0) }
        self.areInIncreasingOrder = areInIncreasingOrder
    }

    /// Następne (najwyżej) `count` elementów w scalonej kolejności.
    public func next(_ count: Int) async throws -> Batch {
        await lock()
        defer { unlock() }
        var out: [Tagged<Element>] = []
        out.reserveCapacity(count)
        while out.count < count {
            try await refill()
            if let stalled = streams.first(where: { $0.pendingError != nil })?.pendingError {
                return Batch(elements: out, isFinished: false, stalled: stalled)
            }
            guard let index = smallestHead() else { break }
            let element = streams[index].buffer[streams[index].head]
            streams[index].head += 1
            if streams[index].head == streams[index].buffer.count {
                // Zjedzony bufor — zwalniamy pamięć (lista w interfejsie ma swoją kopię).
                streams[index].buffer.removeAll(keepingCapacity: true)
                streams[index].head = 0
            }
            let libraryID = streams[index].source.libraryID
            // Przesunięcia stron przy zmianach w bibliotece w trakcie przewijania: bez powtórek.
            guard seen.insert(libraryID + "/" + element.id).inserted else { continue }
            out.append(Tagged(libraryID: libraryID, value: element))
        }
        return Batch(elements: out, isFinished: isFinished, stalled: nil)
    }

    private func smallestHead() -> Int? {
        var best: Int?
        for index in streams.indices where streams[index].hasHead {
            guard let current = best else {
                best = index
                continue
            }
            // Ostra nierówność: przy remisie zostaje wcześniejsza biblioteka.
            if areInIncreasingOrder(streams[index].buffer[streams[index].head], streams[current].buffer[streams[current].head]) {
                best = index
            }
        }
        return best
    }

    /// Dociąga strony bibliotek z pustym buforem — wszystkie naraz.
    private func refill() async throws {
        let needed = streams.indices.filter { streams[$0].needsFetch }
        guard !needed.isEmpty else { return }
        let requests = needed.map { (index: $0, page: streams[$0].nextPage, fetch: streams[$0].source.fetch) }
        let limit = pageSize
        requestCount += requests.count
        let tasks = requests.map { request in
            Task { @MainActor () -> Result<AudiobookshelfClient.Page<Element>, any Error> in
                do {
                    return .success(try await request.fetch(request.page, limit))
                } catch {
                    return .failure(error)
                }
            }
        }
        let results = await concurrently(tasks).enumerated().map { (requests[$0.offset].index, $0.element) }
        var cancelled = Task.isCancelled
        for (index, result) in results {
            switch result {
            case .success(let page):
                // Strona pobrana poprawnie przydaje się także po anulowaniu — zostaje w buforze.
                let elements = page.results.elements
                streams[index].buffer.append(contentsOf: elements)
                streams[index].nextPage += 1
                streams[index].fetched += elements.count
                streams[index].total = page.total
                streams[index].pendingError = nil
                if elements.count < limit || (page.total.map { streams[index].fetched >= $0 } ?? false) {
                    streams[index].isDone = true
                }
            case .failure(let error):
                if Self.isCancellation(error) {
                    cancelled = true
                    continue
                }
                let failure = LibraryFailure(libraryID: streams[index].source.libraryID, libraryName: streams[index].source.libraryName, message: error.localizedDescription)
                if streams[index].nextPage == 0 {
                    streams[index].isExcluded = true
                    failures.append(failure)
                } else {
                    streams[index].pendingError = failure
                }
            }
        }
        if cancelled { throw CancellationError() }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError, error.code == .cancelled { return true }
        return false
    }

    private func lock() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func unlock() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Czeka na zadania uruchomione równolegle; anulowanie wołającego anuluje je wszystkie.
@MainActor
func concurrently<T: Sendable>(_ tasks: [Task<T, Never>]) async -> [T] {
    await withTaskCancellationHandler {
        var out: [T] = []
        out.reserveCapacity(tasks.count)
        for task in tasks { out.append(await task.value) }
        return out
    } onCancel: {
        for task in tasks { task.cancel() }
    }
}

/// Encje o tej samej nazwie w kilku bibliotekach (serie, autorzy) jako jedna pozycja listy.
public struct MergedEntity<Element: Sendable>: Sendable, Identifiable {
    /// Klucz nazwy (`ServerCollation.key`) — ten sam dla wszystkich członków.
    public let id: String
    public internal(set) var members: [Tagged<Element>]

    public var first: Element { members[0].value }
    public var libraryIDs: [String] { members.map(\.libraryID) }
}

extension MergedEntity: Hashable, Equatable where Element: Identifiable, Element.ID == String {
    public static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.members.map(\.id) == b.members.map(\.id) }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Scalanie z łączeniem encji o tej samej nazwie. Encja z innej biblioteki o już widzianej
/// nazwie dołącza do istniejącej pozycji (także z wcześniejszej strony), więc `entities` zawsze
/// trzeba brać w całości.
@MainActor
public final class GroupedMerge<Element: Decodable & Sendable & Identifiable> where Element.ID == String {
    private let merge: SortedMerge<Element>
    private let name: (Element) -> String
    private var indexByKey: [String: Int] = [:]
    public private(set) var entities: [MergedEntity<Element>] = []
    public private(set) var isFinished = false
    public private(set) var stalled: LibraryFailure?
    public var failures: [LibraryFailure] { merge.failures }
    public var requestCount: Int { merge.requestCount }

    public init(merge: SortedMerge<Element>, name: @escaping (Element) -> String) {
        self.merge = merge
        self.name = name
    }

    /// Dociąga co najmniej `count` nowych pozycji (albo do końca); zwraca całą listę.
    @discardableResult
    public func loadMore(_ count: Int) async throws -> [MergedEntity<Element>] {
        var added = 0
        while added < count, !isFinished {
            let batch = try await merge.next(count - added)
            stalled = batch.stalled
            for element in batch.elements {
                let key = ServerCollation.key(name(element.value))
                if let index = indexByKey[key] {
                    entities[index].members.append(element)
                } else {
                    indexByKey[key] = entities.count
                    entities.append(MergedEntity(id: key, members: [element]))
                    added += 1
                }
            }
            isFinished = batch.isFinished
            if batch.stalled != nil || batch.elements.isEmpty { break }
        }
        return entities
    }
}
