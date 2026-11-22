// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 11b).

import Foundation
import OSLog

private let logger = Logger(subsystem: "net.smigi.abswift", category: "TextSync")

extension AudiobookshelfClient {
    /// Zawartość pliku pozycji (`GET /api/items/:id/file/:ino`). W przeciwieństwie do `…/download`
    /// serwer nie wymaga uprawnienia do pobierania, więc mapę tekstu dostanie każde konto z dostępem.
    public func libraryFile(itemID: String, ino: String, token: String) async throws -> Data {
        try await send("GET", "api/items/\(itemID)/file/\(ino)", token: token, timeout: 120)
    }
}

/// Mapy tekstu zapamiętane na dysku. Klucz: pozycja, `ino`, rozmiar i czas zmiany pliku mapy,
/// więc nowa synchronizacja na Macu (nowy plik albo nowy rozmiar) unieważnia wpis. Ostatnia
/// mapa pozycji zostaje też pod osobną nazwą — na wypadek braku sieci.
public struct TextSyncCache: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Katalog w `Caches` aplikacji (system może go wyczyścić; pobrana książka ma własną kopię).
    public static func standard() -> TextSyncCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return TextSyncCache(directory: caches.appending(path: "TextSync", directoryHint: .isDirectory))
    }

    static func key(_ file: AudiobookshelfClient.ItemDetail.LibraryFile) -> String {
        let size = file.metadata.size.map { String(Int64($0)) } ?? "0"
        let mtime = file.metadata.mtimeMs.map { String(Int64($0)) } ?? "0"
        return "\(file.ino)-\(size)-\(mtime)"
    }

    private func folder(_ itemID: String) -> URL {
        directory.appending(path: DownloadedItem.folderName(for: itemID), directoryHint: .isDirectory)
    }

    func data(itemID: String, key: String) -> Data? {
        try? Data(contentsOf: folder(itemID).appending(path: key + ".json"))
    }

    func latest(itemID: String) -> Data? {
        try? Data(contentsOf: folder(itemID).appending(path: "latest.json"))
    }

    func store(_ data: Data, itemID: String, key: String) {
        let folder = folder(itemID)
        do {
            // Starsze wersje mapy tej pozycji nie są już potrzebne.
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appending(path: key + ".json"), options: .atomic)
            try data.write(to: folder.appending(path: "latest.json"), options: .atomic)
        } catch {
            logger.error("Zapis mapy tekstu w pamięci podręcznej: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func remove(itemID: String) {
        try? FileManager.default.removeItem(at: folder(itemID))
    }
}

/// Skąd wziąć mapę pozycji: serwer (pozycja i plik), kopia pobrana z książką (iOS) i jej odświeżenie.
public struct TextSyncSource: Sendable {
    public var itemID: String
    public var fetchItem: @MainActor @Sendable () async throws -> AudiobookshelfClient.ItemDetail
    public var fetchFile: @MainActor @Sendable (_ ino: String) async throws -> Data
    /// Mapa pobrana razem z książką (działa bez sieci).
    public var downloadedCopy: @MainActor @Sendable () -> Data?
    /// Mapa z serwera po wczytaniu — pobrana książka zapisuje ją (albo podmienia starszą) obok
    /// plików audio; także książki pobrane przed etapem 11b dostają tak tekst bez sieci.
    public var updateDownloadedCopy: @MainActor @Sendable (Data) -> Void

    public init(
        itemID: String,
        fetchItem: @escaping @MainActor @Sendable () async throws -> AudiobookshelfClient.ItemDetail,
        fetchFile: @escaping @MainActor @Sendable (_ ino: String) async throws -> Data,
        downloadedCopy: @escaping @MainActor @Sendable () -> Data? = { nil },
        updateDownloadedCopy: @escaping @MainActor @Sendable (Data) -> Void = { _ in }
    ) {
        self.itemID = itemID
        self.fetchItem = fetchItem
        self.fetchFile = fetchFile
        self.downloadedCopy = downloadedCopy
        self.updateDownloadedCopy = updateDownloadedCopy
    }
}

public enum TextSyncLoadResult: Sendable {
    /// `isStale` — pliki zmieniły się od synchronizacji; `isOffline` — mapa z urządzenia bez sprawdzenia serwera.
    case ready(TextSyncDocument, isStale: Bool, isOffline: Bool)
    case unavailable(TextSyncUnavailable)
    case failed(String)
}

public enum TextSyncLoader {
    public struct Damaged: LocalizedError {
        public var errorDescription: String? { "Plik mapy tekstu jest uszkodzony albo pochodzi z nowszej wersji aplikacji. Zsynchronizuj e-book na Macu jeszcze raz." }
    }

    /// Mapa z danych pliku — z kontrolą, że to naprawdę mapa (wersja, niepuste zdania).
    public static func decode(_ data: Data) throws -> TextSyncMap {
        guard let map = try? TextSyncMap.decode(data), map.version >= 1, !map.sentences.isEmpty else { throw Damaged() }
        return map
    }

    /// Wczytuje mapę: z serwera (z pamięcią podręczną), a bez sieci — kopię pobraną z książką
    /// albo ostatnią zapamiętaną. Dekodowanie poza wątkiem głównym (mapa książki to kilka MB).
    @concurrent
    public static func load(_ source: TextSyncSource, cache: TextSyncCache) async -> TextSyncLoadResult {
        let item: AudiobookshelfClient.ItemDetail
        do {
            item = try await source.fetchItem()
        } catch is CancellationError {
            return .failed("Przerwano.")
        } catch {
            // Bez serwera: pobrana kopia, potem pamięć podręczna.
            if let data = await source.downloadedCopy() ?? cache.latest(itemID: source.itemID), let map = try? decode(data) {
                return .ready(TextSyncDocument(map: map), isStale: false, isOffline: true)
            }
            if AddressSelection.isConnectionError(error) { return .unavailable(.offline) }
            return .failed(error.localizedDescription)
        }
        guard let file = TextSyncMap.file(in: item) else {
            return .unavailable(TextSyncMap.unavailableReason(item))
        }
        let key = TextSyncCache.key(file)
        var data = cache.data(itemID: source.itemID, key: key)
        if data == nil {
            do {
                let fetched = try await source.fetchFile(file.ino)
                _ = try decode(fetched)
                cache.store(fetched, itemID: source.itemID, key: key)
                data = fetched
            } catch let error as Damaged {
                return .failed(error.localizedDescription)
            } catch {
                if let data = await source.downloadedCopy() ?? cache.latest(itemID: source.itemID), let map = try? decode(data) {
                    return .ready(TextSyncDocument(map: map), isStale: map.isStale(for: item), isOffline: true)
                }
                return .failed("Nie udało się pobrać tekstu: \(error.localizedDescription)")
            }
        }
        guard let data, let map = try? decode(data) else {
            cache.remove(itemID: source.itemID)
            return .failed(Damaged().localizedDescription)
        }
        await source.updateDownloadedCopy(data)
        return .ready(TextSyncDocument(map: map), isStale: map.isStale(for: item), isOffline: false)
    }
}
