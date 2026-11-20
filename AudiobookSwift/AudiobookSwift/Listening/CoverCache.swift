import AppKit
import ImageIO

/// Okładki w rozmiarze, w jakim są pokazywane. Plik okładki czytany jest wprost z dysku
/// (serwer działa na tym samym Macu); gdy się nie da — serwer skaluje ją przez HTTP.
/// Pamięć podręczna jest czyszczona po zamknięciu okna (zob. `ListeningController.windowClosed`).
@MainActor
final class CoverCache {
    private var images: [String: NSImage] = [:]
    /// Pozycje bez okładki — żeby nie pytać serwera przy każdym przewinięciu listy.
    private var missing: Set<String> = []

    func image(itemID: String, path: String?, pixels: Int, fetch: (Int) async -> Data?) async -> NSImage? {
        let key = "\(itemID)@\(pixels)"
        if let image = images[key] { return image }
        if missing.contains(key) { return nil }
        var image: NSImage?
        if let path, FileManager.default.isReadableFile(atPath: path) {
            image = await Self.thumbnail(url: URL(filePath: path), pixels: pixels)
        }
        if image == nil, let data = await fetch(pixels) {
            image = await Self.thumbnail(data: data, pixels: pixels)
        }
        if let image { images[key] = image } else { missing.insert(key) }
        return image
    }

    /// Zwalnia wszystko poza okładkami bieżącej książki („Teraz odtwarzane”).
    func purge(keeping itemID: String?) {
        images = images.filter { key, _ in itemID.map { key.hasPrefix($0 + "@") } ?? false }
        missing = []
    }

    nonisolated private static func thumbnail(url: URL, pixels: Int) async -> NSImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { thumbnail(source: $0, pixels: pixels) }
    }

    nonisolated private static func thumbnail(data: Data, pixels: Int) async -> NSImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { thumbnail(source: $0, pixels: pixels) }
    }

    nonisolated private static func thumbnail(source: CGImageSource, pixels: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }
}
