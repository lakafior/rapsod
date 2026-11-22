import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AudiobookshelfKit

/// Okładki: pobranie przez HTTP jako droga domyślna, skalowanie i pamięć podręczna.
@MainActor
struct CoverCacheTests {
    /// PNG o zadanym rozmiarze.
    private func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func fetchesOverHTTPByDefaultAndCaches() async throws {
        let data = try png(width: 800, height: 400)
        let cache = CoverCache()
        var fetches = 0
        let image = try #require(await cache.image(itemID: "li1", pixels: 200) { _ in
            fetches += 1
            return data
        })
        // 200 px na dłuższym boku przy skali 2 → 100 × 50 punktów.
        #expect(image.size.width == 100)
        #expect(image.size.height == 50)
        _ = await cache.image(itemID: "li1", pixels: 200) { _ in
            fetches += 1
            return data
        }
        #expect(fetches == 1)
        cache.forget(itemID: "li1")
        _ = await cache.image(itemID: "li1", pixels: 200) { _ in
            fetches += 1
            return data
        }
        #expect(fetches == 2)
    }

    @Test func missingCoverIsRemembered() async {
        let cache = CoverCache()
        var fetches = 0
        #expect(await cache.image(itemID: "brak", pixels: 100) { _ in fetches += 1; return nil } == nil)
        #expect(await cache.image(itemID: "brak", pixels: 100) { _ in fetches += 1; return nil } == nil)
        #expect(fetches == 1)
    }

    @Test func localFileIsPreferredWhenGiven() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "okladka-\(UUID().uuidString).png")
        try png(width: 300, height: 300).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = CoverCache()
        let image = await cache.image(itemID: "li2", path: url.path, pixels: 100) { _ in
            Issue.record("Plik lokalny był czytelny — HTTP niepotrzebne")
            return nil
        }
        #expect(image?.size.width == 50)
    }
}
