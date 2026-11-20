import AppKit
import ImageIO

/// Okładki w rozmiarze, w jakim są pokazywane. Plik okładki czytany jest wprost z dysku
/// (serwer działa na tym samym Macu); gdy się nie da — serwer skaluje ją przez HTTP.
///
/// Pamięć ma limit (`NSCache` z kosztem w bajtach), więc przewijanie biblioteki z tysiącami
/// okładek nie rośnie bez końca: najdawniej oglądane wypadają i w razie potrzeby są czytane
/// z dysku od nowa. Po zamknięciu okna wszystko jest zwalniane
/// (zob. `ListeningController.windowClosed`).
@MainActor
final class CoverCache {
    /// Ok. 150 okładek siatki (280 × 280 px) — kilka ekranów wstecz.
    static let memoryLimit = 48 * 1024 * 1024

    private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = memoryLimit
        return cache
    }()
    /// Pozycje bez okładki — żeby nie pytać serwera przy każdym przewinięciu listy.
    private var missing: Set<String> = []
    /// Trwające wczytania, żeby ta sama okładka nie była dekodowana dwa razy naraz.
    private var loading: [String: Task<NSImage?, Never>] = [:]

    func image(itemID: String, path: String?, pixels: Int, fetch: @escaping (Int) async -> Data?) async -> NSImage? {
        let key = "\(itemID)@\(pixels)"
        if let image = images.object(forKey: key as NSString) { return image }
        if missing.contains(key) { return nil }
        if let task = loading[key] { return await task.value }
        let task = Task<NSImage?, Never> {
            var image: NSImage?
            if let path, FileManager.default.isReadableFile(atPath: path) {
                image = await Self.thumbnail(url: URL(filePath: path), pixels: pixels)
            }
            if image == nil, !Task.isCancelled, let data = await fetch(pixels) {
                image = await Self.thumbnail(data: data, pixels: pixels)
            }
            return image
        }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height) * 4 * 4
            images.setObject(image, forKey: key as NSString, cost: cost)
        } else {
            missing.insert(key)
        }
        return image
    }

    /// Zwalnia wszystko (okładka bieżącej książki żyje dalej w odtwarzaczu — `AudiobookPlayer.artwork`).
    func purge() {
        images.removeAllObjects()
        missing = []
    }

    nonisolated private static func thumbnail(url: URL, pixels: Int) async -> NSImage? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary).flatMap { thumbnail(source: $0, pixels: pixels) }
    }

    nonisolated private static func thumbnail(data: Data, pixels: Int) async -> NSImage? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary).flatMap { thumbnail(source: $0, pixels: pixels) }
    }

    nonisolated private static func thumbnail(source: CGImageSource, pixels: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }
}
