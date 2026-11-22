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
    /// Pozycje bez okładki — żeby nie pytać serwera przy każdym przewinięciu listy. Wpis wygasa
    /// po minucie: chwilowy błąd sieci nie zostawia pustej okładki do zamknięcia okna.
    private var missing: [String: ContinuousClock.Instant] = [:]
    private static let missingLifetime = Duration.seconds(60)
    /// Trwające wczytania, żeby ta sama okładka nie była dekodowana dwa razy naraz. Licznik
    /// czekających: wczytanie jest przerywane dopiero, gdy zniknie ostatnia komórka, która go chce.
    private var loading: [String: (task: Task<NSImage?, Never>, waiters: Int)] = [:]
    /// Wersja okładki pozycji (rośnie po zmianie): stare wpisy wypadają z `NSCache` same.
    private var versions: [String: Int] = [:]

    func image(itemID: String, path: String?, pixels: Int, fetch: @escaping (Int) async -> Data?) async -> NSImage? {
        // Ścieżka w kluczu: po zmianie okładki widok z jeszcze starą ścieżką (plik zostaje na dysku)
        // nie może podsunąć starego obrazka widokowi, który ma już nową.
        let key = "\(itemID)#\(versions[itemID] ?? 0)@\(pixels)|\(path ?? "")"
        if let image = images.object(forKey: key as NSString) { return image }
        if let since = missing[key] {
            if ContinuousClock.now - since < Self.missingLifetime { return nil }
            missing[key] = nil
        }
        let task: Task<NSImage?, Never>
        if let current = loading[key] {
            task = current.task
            loading[key]?.waiters += 1
        } else {
            task = Task<NSImage?, Never> {
                guard !Task.isCancelled else { return nil }
                var image: NSImage?
                if let path, FileManager.default.isReadableFile(atPath: path) {
                    image = await Self.thumbnail(url: URL(filePath: path), pixels: pixels)
                }
                if image == nil, !Task.isCancelled, let data = await fetch(pixels) {
                    image = await Self.thumbnail(data: data, pixels: pixels)
                }
                return image
            }
            loading[key] = (task, 1)
        }
        // Komórka zniknęła z ekranu (szybkie przewijanie): przestaje czekać, a wczytanie bez
        // czekających jest przerywane, zanim zacznie dekodować.
        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor in self.abandon(key, task) }
        }
        if Task.isCancelled { return nil }
        if loading[key]?.task == task { loading[key] = nil }
        if let image {
            let cost = Int(image.size.width * image.size.height) * 4 * 4
            images.setObject(image, forKey: key as NSString, cost: cost)
        } else if !task.isCancelled {
            missing[key] = .now
        }
        return image
    }

    private func abandon(_ key: String, _ task: Task<NSImage?, Never>) {
        guard let current = loading[key], current.task == task else { return }
        if current.waiters <= 1 {
            task.cancel()
            loading[key] = nil
        } else {
            loading[key]?.waiters = current.waiters - 1
        }
    }

    /// Okładka pozycji się zmieniła (zapis z edycji albo zdarzenie serwera) — następne pytanie czyta ją od nowa.
    func forget(itemID: String) {
        versions[itemID, default: 0] += 1
    }

    /// Zwalnia wszystko (okładka bieżącej książki żyje dalej w odtwarzaczu — `AudiobookPlayer.artwork`).
    func purge() {
        images.removeAllObjects()
        missing = [:]
    }

    nonisolated private static func thumbnail(url: URL, pixels: Int) async -> NSImage? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary).flatMap { thumbnail(source: $0, pixels: pixels) }
    }

    nonisolated static func thumbnail(data: Data, pixels: Int) async -> NSImage? {
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
