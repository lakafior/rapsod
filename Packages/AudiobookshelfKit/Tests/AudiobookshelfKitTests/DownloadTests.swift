// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
import AudiobookshelfKit

private func file(_ ino: String, _ index: Int, size: Int64? = 100, state: DownloadedFile.State = .queued) -> DownloadedFile {
    DownloadedFile(ino: ino, index: index, fileName: DownloadedFile.localName(index: index, ino: ino, originalName: "\(index).m4a"),
                   title: "Plik \(index)", startOffset: Double(index - 1) * 10, duration: 10, expectedSize: size, state: state)
}

private func book(_ files: [DownloadedFile]) -> DownloadedItem {
    DownloadedItem(scope: "serwer", itemID: "li", episodeID: nil, libraryID: "lib", mediaType: "book", title: "Książka",
                   author: "Autor", duration: 30, chapters: [], files: files)
}

@Suite struct DownloadIndexTests {
    private let open = DownloadGate.open(baseURL: URL(string: "http://mac.local:13378/audiobookshelf")!, allowsCellular: false)

    @Test func statusFollowsFilesAndNetwork() {
        let queued = book([file("1", 1), file("2", 2)])
        #expect(DownloadIndex.status(of: nil, gate: open) == .notDownloaded)
        #expect(DownloadIndex.status(of: queued, gate: open) == .queued)
        #expect(DownloadIndex.status(of: queued, gate: .closed(.wifi)) == .waiting(.wifi))
        let half = book([file("1", 1, state: .done), file("2", 2, state: .downloading)])
        #expect(DownloadIndex.status(of: half, gate: open, written: ["2": 50]) == .downloading(0.75))
        var paused = half
        paused.isPaused = true
        #expect(DownloadIndex.status(of: paused, gate: open) == .paused(0.5))
        let failed = book([file("1", 1, state: .done), file("2", 2, state: .failed("Pliku nie ma"))])
        #expect(DownloadIndex.status(of: failed, gate: open) == .failed("Pliku nie ma"))
        let done = book([file("1", 1, state: .done), file("2", 2, state: .done)])
        #expect(DownloadIndex.status(of: done, gate: .closed(.connection)) == .downloaded, "pobrane są pobrane także bez sieci")
        #expect(DownloadStatus.downloading(0.426).text == "Pobieranie 42 %")
    }

    @Test func fractionWithoutSizesCountsFiles() {
        let item = book([file("1", 1, size: nil, state: .done), file("2", 2, size: nil), file("3", 3, size: nil), file("4", 4, size: nil)])
        #expect(DownloadIndex.fraction(of: item) == 0.25)
    }

    @Test func policyGate() {
        let url = URL(string: "https://abs.example.com")!
        let defaults = DownloadPolicy()
        #expect(defaults.wifiOnly && !defaults.allowsTunnel)
        #expect(defaults.gate(baseURL: nil, isLocalAddress: true, onWiFi: true) == .closed(.connection))
        #expect(defaults.gate(baseURL: url, isLocalAddress: true, onWiFi: true) == .open(baseURL: url, allowsCellular: false))
        #expect(defaults.gate(baseURL: url, isLocalAddress: false, onWiFi: true) == .closed(.homeNetwork), "tunel domyślnie wyłączony")
        #expect(defaults.gate(baseURL: url, isLocalAddress: false, onWiFi: false) == .closed(.wifi))
        let tunnel = DownloadPolicy(wifiOnly: true, allowsTunnel: true)
        #expect(tunnel.gate(baseURL: url, isLocalAddress: false, onWiFi: true) == .open(baseURL: url, allowsCellular: false))
        let anywhere = DownloadPolicy(wifiOnly: false, allowsTunnel: true)
        #expect(anywhere.gate(baseURL: url, isLocalAddress: false, onWiFi: false) == .open(baseURL: url, allowsCellular: true))
    }

    @Test func reconcileAfterCrash() {
        let item = book([file("1", 1, state: .done), file("2", 2, state: .done), file("3", 3, state: .downloading)])
        let names = item.files.map(\.fileName)
        let disk: [String: [String: Int64]] = [
            // Plik 1 jest, plik 2 ma zły rozmiar (urwany zapis), do tego śmieć i katalog bez wpisu.
            // Mapa tekstu (etap 11b) i znaczniki segmentów (etap 13a) to nie śmieci.
            item.folder: [names[0]: 100, names[1]: 40, "obcy.tmp": 5, DownloadedItem.textSyncFileName: 30, DownloadedItem.skipFileName: 2],
            "deadbeef": ["x.m4a": 10],
        ]
        let result = DownloadIndex.reconcile([item], disk: disk)
        let fixed = try! #require(result.items.first)
        #expect(fixed.files.map(\.state) == [.done, .queued, .queued])
        #expect(Set(result.orphans) == ["deadbeef", item.folder + "/obcy.tmp"])
        // Brak plików w ogóle (system wyczyścił katalog) — wszystko do kolejki.
        #expect(DownloadIndex.reconcile([item], disk: [:]).items.first?.files.allSatisfy { $0.state == .queued } == true)
        // Zadanie wciąż działa w sesji tła — plik zostaje „w trakcie”.
        let running = DownloadIndex.reconcile([item], disk: disk, runningFiles: ["li|3"])
        #expect(running.items.first?.files.last?.state == .downloading)
    }

    @Test func namesSpaceAndRetries() {
        #expect(DownloadedFile.localName(index: 2, ino: "123/../x", originalName: "Rozdział 2.M4B") == "002-123x.m4b")
        #expect(DownloadedFile.localName(index: 1, ino: "9", originalName: nil) == "001-9")
        #expect(DownloadIndex.hasRoom(for: 100, available: 100 + 200 * 1_048_576))
        #expect(!DownloadIndex.hasRoom(for: 100, available: 200 * 1_048_576))
        #expect(DownloadIndex.retryDelay(attempts: 1) == .seconds(5))
        #expect(DownloadIndex.retryDelay(attempts: 3) == .seconds(20))
        #expect(DownloadIndex.retryDelay(attempts: 9) == .seconds(60))
        #expect(DownloadTaskID("li/ep|ino1") == DownloadTaskID(itemKey: "li/ep", ino: "ino1"))
        #expect(DownloadTaskID("bez-kreski") == nil)
        #expect(book([]).folder == DownloadedItem.folderName(for: "li"))
    }
}

/// Menedżer na zwykłej sesji z zaślepką serwera (sesji tła nie da się użyć w testach).
extension Stubbed {
@Suite @MainActor struct DownloadManagerTests {
    init() { StubServer.reset() }

    private func makeManager() -> (DownloadManager, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pobrane-\(UUID().uuidString)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        let manager = DownloadManager(configuration: configuration, directory: directory, indexURL: directory.appending(path: "indeks.json"))
        manager.authorization = { "KLUCZ" }
        manager.activeScope = "serwer"
        return (manager, directory)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(30)) }
    }

    @Test func downloadsAllFilesAndChecksSize() async throws {
        let (manager, directory) = makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        StubServer.on("GET api/items/li/file/1/download", .init(status: 200, body: Data(repeating: 1, count: 100)))
        StubServer.on("GET api/items/li/file/2/download", .init(status: 200, body: Data(repeating: 2, count: 100)))
        let entry = manager.entry(itemID: "li", episodeID: nil)
        try manager.enqueue(book([file("1", 1), file("2", 2)]), cover: Data([0xFF, 0xD8]))
        #expect(entry.status == .waiting(.connection), "bez połączenia czeka")
        #expect(StubServer.requests.isEmpty)

        manager.setGate(.open(baseURL: URL(string: "http://abs.test/audiobookshelf")!, allowsCellular: false))
        await waitUntil { manager.completeItem(itemID: "li", episodeID: nil) != nil }
        let item = try #require(manager.completeItem(itemID: "li", episodeID: nil))
        #expect(entry.status == .downloaded)
        #expect(manager.usedBytes() == 200)
        #expect(manager.coverURL(item) != nil)
        let first = try #require(StubServer.requests.first)
        #expect(first.request.value(forHTTPHeaderField: "Authorization") == "Bearer KLUCZ")
        #expect(first.request.allowsCellularAccess == false)
        for file in item.files { #expect(FileManager.default.fileExists(atPath: manager.fileURL(item, file).path)) }

        // Po „ponownym uruchomieniu” indeks i pliki są na miejscu.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        let reopened = DownloadManager(configuration: configuration, directory: directory, indexURL: directory.appending(path: "indeks.json"))
        await waitUntil { reopened.revision > 0 || reopened.completeItem(itemID: "li", episodeID: nil) != nil }
        #expect(reopened.completeItem(itemID: "li", episodeID: nil) != nil)

        manager.remove(key: "li")
        #expect(manager.item(itemID: "li", episodeID: nil) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: item.folder).path))
        #expect(entry.status == .notDownloaded)
    }

    @Test func refusalAndTruncationAreHandled() async throws {
        let (manager, directory) = makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        StubServer.on("GET api/items/li/file/1/download", .status(403))
        // Urwany plik: 60 B zamiast 100 — ponawiany, nie oznaczany jako pobrany.
        StubServer.on("GET api/items/li/file/2/download", .init(status: 200, body: Data(repeating: 2, count: 60)))
        try manager.enqueue(book([file("1", 1), file("2", 2)]))
        manager.setGate(.open(baseURL: URL(string: "http://abs.test/audiobookshelf")!, allowsCellular: true))
        await waitUntil {
            let item = manager.item(itemID: "li", episodeID: nil)
            return item?.files.first?.state != .queued && item?.files.first?.state != .downloading && (item?.files.last?.attempts ?? 0) > 0
        }
        let item = try #require(manager.item(itemID: "li", episodeID: nil))
        guard case .failed(let reason) = item.files[0].state else { Issue.record("brak błędu dla 403"); return }
        #expect(reason.contains("uprawnienia"))
        #expect(item.files[1].state != .done)
        #expect(item.files[1].attempts >= 1)
        manager.removeAll()
    }

    @Test func unreadableIndexKeepsFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pobrane-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appending(path: "abc123")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.appending(path: "001-1.m4a"))
        try Data("{nie json".utf8).write(to: directory.appending(path: "indeks.json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        let reopened = DownloadManager(configuration: configuration, directory: directory, indexURL: directory.appending(path: "indeks.json"))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(reopened.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "001-1.m4a").path), "pliki zostają, gdy indeks jest nieczytelny")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.hasPrefix("indeks.json.nieczytelny-") }, "nieczytelny indeks odłożony na bok: \(names)")
    }

    @Test func atMostTwoFilesAtOnce() async throws {
        let (manager, directory) = makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        for ino in ["1", "2", "3", "4"] {
            StubServer.on("GET api/items/li/file/\(ino)/download", .init(status: 200, body: Data(repeating: 1, count: 100)))
        }
        try manager.enqueue(book([file("1", 1), file("2", 2), file("3", 3), file("4", 4)]))
        manager.setGate(.open(baseURL: URL(string: "http://abs.test/audiobookshelf")!, allowsCellular: false))
        // Najwięcej plików „w trakcie” naraz, próbkowane do końca pobierania.
        var most = 0
        await waitUntil {
            let downloading = manager.item(itemID: "li", episodeID: nil)?.files.count { $0.state == .downloading } ?? 0
            most = max(most, downloading)
            return manager.completeItem(itemID: "li", episodeID: nil) != nil
        }
        #expect(most <= 2, "najwyżej dwa pliki naraz, było \(most)")
        #expect(manager.completeItem(itemID: "li", episodeID: nil) != nil, "kolejne startują po zakończeniu poprzednich")
        manager.removeAll()
    }

    @Test func refusesWithoutSpace() throws {
        let (manager, directory) = makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        manager.availableSpace = { 50 }
        #expect(throws: DownloadManager.DownloadError.self) { try manager.enqueue(book([file("1", 1)])) }
        #expect(manager.item(itemID: "li", episodeID: nil) == nil)
    }
}
}
