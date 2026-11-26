import Foundation

/// Wyszukiwanie w Spotlight (etap 14f): identyfikatory wpisów i plan zmian indeksu.
///
/// Indeks Spotlight jest wspólny dla wszystkich kopii aplikacji o tym samym identyfikatorze
/// pakietu — kopia testowa (`-ABSDataRoot`) i prawdziwa aplikacja piszą do jednego. Dlatego każdy
/// wpis niesie „zakres” wyliczony ze ścieżki folderu danych: domena `<prefiks>.<zakres>.<biblioteka>`
/// i identyfikator `rapsod:<zakres>:<rodzaj>:<pozycja>[:<odcinek>]`. Kopia usuwa tylko swoje
/// domeny i ignoruje wyniki z cudzym zakresem.
public enum SpotlightKind: String, Sendable, Codable {
    case book, podcast, episode
}

public struct SpotlightKey: Hashable, Sendable {
    public static let domainPrefix = "net.smigi.rapsod.spotlight"

    public let scope: String
    public let kind: SpotlightKind
    public let itemID: String
    public let episodeID: String?

    public init(scope: String, kind: SpotlightKind, itemID: String, episodeID: String? = nil) {
        self.scope = scope
        self.kind = kind
        self.itemID = itemID
        self.episodeID = episodeID
    }

    public var uniqueIdentifier: String {
        (["rapsod", scope, kind.rawValue, itemID] + (episodeID.map { [$0] } ?? [])).joined(separator: ":")
    }

    /// Identyfikator wpisu z indeksu albo `nil`, gdy to nie wpis Rapsodu.
    public init?(uniqueIdentifier: String) {
        let parts = uniqueIdentifier.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 || parts.count == 5, parts[0] == "rapsod", !parts[1].isEmpty, !parts[3].isEmpty,
              let kind = SpotlightKind(rawValue: parts[2]) else { return nil }
        if kind == .episode {
            guard parts.count == 5, !parts[4].isEmpty else { return nil }
        } else if parts.count != 4 {
            return nil
        }
        self.init(scope: parts[1], kind: kind, itemID: parts[3], episodeID: parts.count == 5 ? parts[4] : nil)
    }

    /// Domena wszystkich wpisów jednego folderu danych (usunięcie jej czyści cały indeks tej kopii).
    public static func domain(scope: String) -> String { "\(domainPrefix).\(scope)" }

    /// Domena jednej biblioteki (usunięcie biblioteki).
    public static func domain(scope: String, libraryID: String) -> String {
        "\(domain(scope: scope)).\(libraryID.replacingOccurrences(of: ".", with: "_"))"
    }

    /// Zakres z folderu danych: 12 znaków szesnastkowych skrótu FNV-1a ścieżki (bez kropek
    /// i dwukropków, stały między uruchomieniami — `hashValue` Swifta jest losowany).
    public static func scope(dataRoot: String) -> String {
        let path = (dataRoot as NSString).standardizingPath
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(String(hash, radix: 16).suffix(12))
    }
}

/// Co jest w indeksie tej kopii: pozycja → biblioteka, chwila ostatniej zmiany na serwerze
/// i odcinki (podcasty). Zapisywany w folderze danych, więc kopia testowa ma własny.
public struct SpotlightManifest: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var libraryID: String
        public var kind: SpotlightKind
        public var updatedAt: Double
        public var episodes: [String]

        public init(libraryID: String, kind: SpotlightKind, updatedAt: Double, episodes: [String] = []) {
            self.libraryID = libraryID
            self.kind = kind
            self.updatedAt = updatedAt
            self.episodes = episodes
        }
    }

    /// Konto słuchacza, dla którego zbudowano indeks — inne konto widzi inne biblioteki.
    public var userID: String?
    public var items: [String: Entry]

    public init(userID: String? = nil, items: [String: Entry] = [:]) {
        self.userID = userID
        self.items = items
    }

    public var libraries: Set<String> { Set(items.values.map(\.libraryID)) }
}

/// Stan pozycji na serwerze (z listy biblioteki).
public struct SpotlightSource: Sendable, Equatable {
    public let itemID: String
    public let libraryID: String
    public let kind: SpotlightKind
    public let updatedAt: Double

    public init(itemID: String, libraryID: String, kind: SpotlightKind, updatedAt: Double) {
        self.itemID = itemID
        self.libraryID = libraryID
        self.kind = kind
        self.updatedAt = updatedAt
    }
}

public struct SpotlightChanges: Sendable, Equatable {
    /// Nowe albo zmienione od ostatniego indeksowania, w kolejności z serwera.
    public var toIndex: [SpotlightSource]
    /// Pozycje do usunięcia z indeksu razem z odcinkami (zniknęły z listy swojej biblioteki).
    public var removedItems: [String: SpotlightManifest.Entry]
    /// Biblioteki, których już nie ma (albo konto ich nie widzi) — usuwa się całą domenę.
    public var removedLibraries: Set<String>

    public var isEmpty: Bool { toIndex.isEmpty && removedItems.isEmpty && removedLibraries.isEmpty }
}

public enum SpotlightPlan {
    /// Porównanie indeksu z serwerem. `listed` to biblioteki przejrzane w całości — pozycje
    /// z innych bibliotek manifestu zostają (np. przegląd tylko biblioteki ze zdarzenia).
    /// `libraries` to wszystkie biblioteki widoczne dla konta: spoza niej idą do usunięcia.
    public static func changes(manifest: SpotlightManifest, current: [SpotlightSource],
                               listed: Set<String>, libraries: Set<String>) -> SpotlightChanges {
        let removedLibraries = manifest.libraries.subtracting(libraries)
        var toIndex: [SpotlightSource] = []
        var seen = Set<String>()
        for source in current where listed.contains(source.libraryID) && seen.insert(source.itemID).inserted {
            if let entry = manifest.items[source.itemID], entry.libraryID == source.libraryID,
               entry.kind == source.kind, entry.updatedAt >= source.updatedAt {
                continue
            }
            toIndex.append(source)
        }
        let libraryOf = Dictionary(current.map { ($0.itemID, $0.libraryID) }, uniquingKeysWith: { first, _ in first })
        var removedItems: [String: SpotlightManifest.Entry] = [:]
        for (id, entry) in manifest.items where !removedLibraries.contains(entry.libraryID) {
            if listed.contains(entry.libraryID), !seen.contains(id) {
                removedItems[id] = entry
            } else if let library = libraryOf[id], library != entry.libraryID {
                // Pozycja przeniesiona do innej biblioteki: stary wpis ma starą domenę.
                removedItems[id] = entry
            }
        }
        return SpotlightChanges(toIndex: toIndex, removedItems: removedItems, removedLibraries: removedLibraries)
    }

    /// Odcinki, które zniknęły z podcastu od ostatniego indeksowania.
    public static func removedEpisodes(old: [String], new: [String]) -> [String] {
        let kept = Set(new)
        return old.filter { !kept.contains($0) }
    }

    /// Paczki stałej wielkości (indeksowanie po kawałku, z zapisem manifestu po każdej).
    public static func batches<T>(_ elements: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [elements] }
        return stride(from: 0, to: elements.count, by: size).map { Array(elements[$0 ..< min($0 + size, elements.count)]) }
    }

    /// Słowa kluczowe wpisu: autorzy, lektorzy, seria, gatunki — bez pustych i powtórzeń.
    public static func keywords(_ groups: [String?]...) -> [String] {
        var result: [String] = []
        for group in groups {
            for value in group {
                for part in (value ?? "").split(separator: ",") {
                    let word = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !word.isEmpty, !result.contains(word) { result.append(word) }
                }
            }
        }
        return result
    }
}
