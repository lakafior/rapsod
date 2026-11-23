// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import AudiobookshelfKit

@Suite struct EbookReadingTests {
    @Test func formats() {
        #expect(EbookFormat(format: "epub", filename: "x.pdf") == .epub)
        #expect(EbookFormat(format: nil, filename: "Książka.PDF") == .pdf)
        #expect(EbookFormat(format: "", filename: "a.epub") == .epub)
        #expect(EbookFormat(format: "mobi", filename: nil) == .unsupported("MOBI"))
        #expect(EbookFormat(format: "mobi", filename: nil).unsupportedMessage?.contains("MOBI") == true)
        #expect(EbookFormat.epub.unsupportedMessage == nil)
        #expect(EbookFormat(format: nil, filename: nil).unsupportedMessage?.hasPrefix("Ten format") == true)
        #expect(EbookFormat.pdf.fileExtension == "pdf")
    }

    @Test func locations() {
        #expect(EbookLocationValue.pdfPage("12") == 12)
        #expect(EbookLocationValue.pdfPage("3.7") == 3)
        #expect(EbookLocationValue.pdfPage("0") == nil)
        #expect(EbookLocationValue.pdfPage("inf") == nil)
        #expect(EbookLocationValue.pdfPage("epubcfi(/6/2!/4/2:0)") == nil)
        #expect(EbookLocationValue.epubCFI("epubcfi(/6/2!/4/2:0)") == "epubcfi(/6/2!/4/2:0)")
        #expect(EbookLocationValue.epubCFI("12") == nil)
        #expect(EbookLocationValue.pdfProgress(page: 1, count: 10) == 0)
        #expect(EbookLocationValue.pdfProgress(page: 6, count: 10) == 0.5)
        #expect(EbookLocationValue.pdfProgress(page: 1, count: 0) == nil)
    }

    @MainActor @Test func positionStore() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ebook-\(UUID().uuidString)/pos.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = EbookPositionStore(url: url)
        // Nic na telefonie — pozycja z serwera; bez sieci i bez niczego — nil.
        #expect(store.startLocation(itemID: "a", server: "epubcfi(/6/4!/4/2:0)", serverReachable: true) == "epubcfi(/6/4!/4/2:0)")
        #expect(store.startLocation(itemID: "a", server: nil, serverReachable: false) == nil)

        store.update(itemID: "a", location: "epubcfi(/6/8!/4/2:0)", progress: 0.2)
        // Niewysłany zapis wygrywa z serwerem.
        #expect(store.startLocation(itemID: "a", server: "epubcfi(/6/4!/4/2:0)", serverReachable: true) == "epubcfi(/6/8!/4/2:0)")
        #expect(store.unsent.map(\.itemID) == ["a"])
        // Potwierdzenie starszego zapisu nie odhacza nowszego.
        store.markSent(itemID: "a", location: "epubcfi(/6/2!/4/2:0)")
        #expect(store.unsent.count == 1)
        store.markSent(itemID: "a", location: "epubcfi(/6/8!/4/2:0)")
        #expect(store.unsent.isEmpty)
        // Wysłany: serwer wie lepiej (inne urządzenie), a bez sieci — ostatnie znane miejsce.
        #expect(store.startLocation(itemID: "a", server: "epubcfi(/6/10!/4/2:0)", serverReachable: true) == "epubcfi(/6/10!/4/2:0)")
        #expect(store.startLocation(itemID: "a", server: nil, serverReachable: false) == "epubcfi(/6/8!/4/2:0)")
        // Trwałość.
        #expect(EbookPositionStore(url: url).record(itemID: "a")?.progress == 0.2)
    }

    @Test func fileCache() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ebook-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = EbookFileCache(directory: dir)
        let key = EbookFileCache.key(ino: "12/../3", size: 100, mtimeMs: 5)
        #expect(key == "123-100-5")
        #expect(cache.file(itemID: "li", key: key, ext: "epub") == nil)
        cache.store(Data([1]), itemID: "li", key: "old", ext: "epub")
        let url = try #require(cache.store(Data([1, 2]), itemID: "li", key: key, ext: "epub"))
        #expect(cache.file(itemID: "li", key: key, ext: "epub") == url)
        #expect(cache.file(itemID: "li", key: "old", ext: "epub") == nil)
        #expect(cache.latest(itemID: "li")?.lastPathComponent == url.lastPathComponent)
    }
}
