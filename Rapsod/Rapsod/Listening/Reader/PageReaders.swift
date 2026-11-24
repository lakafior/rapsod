import AppKit
import ImageIO
import PDFKit
import SwiftUI

/// Ustawienia czytnika jak w web UI (motyw, rozmiar czcionki, interlinia, krój, układ stron).
/// Zapamiętane na tym Macu (`@AppStorage`), jak `ereaderSettings` w localStorage web UI.
struct ReaderSettings: Codable, Equatable, RawRepresentable {
    enum Theme: String, Codable, CaseIterable, Identifiable {
        case light, sepia, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .light: "Jasny"
            case .sepia: "Sepia"
            case .dark: "Ciemny"
            }
        }
        var background: Color {
            switch self {
            case .light: .white
            case .sepia: Color(red: 244 / 255, green: 236 / 255, blue: 216 / 255)
            case .dark: Color(red: 35 / 255, green: 35 / 255, blue: 35 / 255)
            }
        }
    }

    var theme: Theme = .light
    /// Procent, 50…300.
    var fontScale = 100
    /// Procent, 80…240.
    var lineSpacing = 115
    /// `serif` albo `sans`.
    var font = "serif"
    /// `auto` (dwie strony w szerokim oknie) albo `none` (zawsze jedna).
    var spread = "auto"

    init() {}

    // Jawne kodowanie: przy `RawRepresentable` syntezowane `Codable` koduje przez `rawValue`,
    // a `rawValue` przez `Codable` — nieskończona rekurencja.
    private enum CodingKeys: String, CodingKey { case theme, fontScale, lineSpacing, font, spread }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? c.decode(Theme.self, forKey: .theme)) ?? .light
        fontScale = (try? c.decode(Int.self, forKey: .fontScale)) ?? 100
        lineSpacing = (try? c.decode(Int.self, forKey: .lineSpacing)) ?? 115
        font = (try? c.decode(String.self, forKey: .font)) ?? "serif"
        spread = (try? c.decode(String.self, forKey: .spread)) ?? "auto"
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(theme, forKey: .theme)
        try c.encode(fontScale, forKey: .fontScale)
        try c.encode(lineSpacing, forKey: .lineSpacing)
        try c.encode(font, forKey: .font)
        try c.encode(spread, forKey: .spread)
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8), let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = value
    }

    var rawValue: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Obiekt dla `reader.apply` w `reader.js`.
    var json: String {
        let object: [String: Any] = ["theme": theme.rawValue, "fontScale": fontScale, "lineSpacing": lineSpacing, "font": font, "spread": spread]
        return (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// Czytnik stron (PDF i komiksy): pozycja to numer strony od 1, postęp `(strona − 1) / liczba stron`
/// — dokładnie jak `PdfReader.vue` i `ComicReader.vue`, żeby web UI i telefon rozumiały zapis.
@MainActor
@Observable
final class PageController {
    struct OutlineItem: Identifiable, Hashable {
        let id: Int
        let label: String
        let page: Int
        let depth: Int
    }

    /// Bieżąca strona, od 1.
    private(set) var page = 1
    private(set) var pageCount = 0
    private(set) var outline: [OutlineItem] = []
    var onPageChange: ((Int, Int) -> Void)?

    @ObservationIgnored fileprivate weak var pdfView: PDFView?

    var fraction: Double { pageCount > 0 ? Double(page - 1) / Double(pageCount) : 0 }

    func setPage(_ value: Int) {
        let clamped = min(max(1, value), max(1, pageCount))
        if let pdfView, let document = pdfView.document, let target = document.page(at: clamped - 1) {
            if pdfView.currentPage != target { pdfView.go(to: target) }
        }
        guard clamped != page else { return }
        page = clamped
        onPageChange?(page, pageCount)
    }

    func next() {
        if let pdfView { pdfView.goToNextPage(nil) } else { setPage(page + 1) }
    }

    func previous() {
        if let pdfView { pdfView.goToPreviousPage(nil) } else { setPage(page - 1) }
    }

    fileprivate func loaded(pageCount: Int, outline: [OutlineItem], start: Int) {
        self.pageCount = pageCount
        self.outline = outline
        page = min(max(1, start), max(1, pageCount))
    }

    fileprivate func pdfMoved(to index: Int) {
        let value = index + 1
        guard value != page else { return }
        page = value
        onPageChange?(page, pageCount)
    }

    // MARK: Komiksy

    /// Wypakowane strony komiksu (posortowane jak w Finderze).
    private(set) var images: [URL] = []

    func loadComic(pages: [URL], start: Int) {
        images = pages
        loaded(pageCount: pages.count, outline: [], start: start)
    }
}

// MARK: - PDF

struct PDFReaderView: NSViewRepresentable {
    let controller: PageController
    let fileURL: URL
    let startPage: Int
    let twoPages: Bool

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> PDFView {
        let view = FocusingPDFView()
        view.autoScales = true
        view.displayMode = twoPages ? .twoUp : .singlePage
        view.displaysPageBreaks = true
        view.backgroundColor = .windowBackgroundColor
        let document = PDFDocument(url: fileURL)
        view.document = document
        controller.pdfView = view
        if let document {
            controller.loaded(pageCount: document.pageCount, outline: Self.outline(of: document), start: startPage)
            if let page = document.page(at: controller.page - 1) { view.go(to: page) }
        }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        let mode: PDFDisplayMode = twoPages ? .twoUp : .singlePage
        if view.displayMode != mode {
            view.displayMode = mode
            view.autoScales = true
        }
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    static func outline(of document: PDFDocument) -> [PageController.OutlineItem] {
        var items: [PageController.OutlineItem] = []
        func walk(_ node: PDFOutline, depth: Int) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                if let page = child.destination?.page {
                    items.append(.init(id: items.count, label: child.label ?? "", page: document.index(for: page) + 1, depth: depth))
                }
                walk(child, depth: depth + 1)
            }
        }
        if let root = document.outlineRoot { walk(root, depth: 0) }
        return items
    }

    @MainActor
    final class Coordinator: NSObject {
        let controller: PageController
        init(controller: PageController) { self.controller = controller }

        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView, let page = view.currentPage, let document = view.document else { return }
            controller.pdfMoved(to: document.index(for: page))
        }
    }
}

/// `PDFView`, który po pokazaniu bierze fokus — strzałki działają od razu po otwarciu okna.
final class FocusingPDFView: PDFView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            if let self { self.window?.makeFirstResponder(self) }
        }
    }
}

// MARK: - Komiksy (CBZ/CBR)

/// Rozpakowanie komiksu systemowym `bsdtar` (libarchive w macOS: ZIP i RAR; RAR5 tylko częściowo)
/// do folderu tymczasowego — web UI robi to samo libarchive.js w przeglądarce.
enum ComicArchive {
    static let imageTypes: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "bmp", "tif", "tiff", "heic"]

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func extract(_ archive: URL) async throws -> (folder: URL, pages: [URL]) {
        try await Task.detached(priority: .userInitiated) {
            let folder = FileManager.default.temporaryDirectory.appending(path: "Rapsod-komiks-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/bsdtar")
            process.arguments = ["-x", "-f", archive.path, "-C", folder.path]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let output = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let pages = images(in: folder)
            if pages.isEmpty {
                try? FileManager.default.removeItem(at: folder)
                let detail = String(decoding: output.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure(message: process.terminationStatus == 0
                    ? "W archiwum nie ma obrazów stron."
                    : "Nie udało się rozpakować archiwum" + (detail.isEmpty ? "." : ": \(detail)"))
            }
            return (folder, pages)
        }.value
    }

    private static func images(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where imageTypes.contains(url.pathExtension.lowercased()) {
            // Pliki z `__MACOSX` to zasoby Findera, nie strony.
            if url.pathComponents.contains("__MACOSX") { continue }
            result.append(url)
        }
        let base = folder.standardizedFileURL.path
        return result.sorted {
            String($0.standardizedFileURL.path.dropFirst(base.count)).localizedStandardCompare(String($1.standardizedFileURL.path.dropFirst(base.count))) == .orderedAscending
        }
    }
}

/// Strony komiksu zdekodowane poza głównym wątkiem, w rozmiarze ekranu (skan 6000 px nie trafia
/// do pamięci w całości). Trzyma kilka ostatnich stron i z wyprzedzeniem czyta następną.
@MainActor
final class ComicPageCache {
    /// Dłuższy bok strony w pikselach — wystarcza na ekran 5K.
    nonisolated static let maxPixels = 4096

    private let images: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 6
        return cache
    }()
    private var loading: [URL: Task<NSImage?, Never>] = [:]

    func image(for url: URL) async -> NSImage? {
        if let image = images.object(forKey: url as NSURL) { return image }
        if let task = loading[url] { return await task.value }
        let task = Task<NSImage?, Never> { await Self.decode(url) }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { images.setObject(image, forKey: url as NSURL) }
        return image
    }

    func prefetch(_ url: URL) {
        guard images.object(forKey: url as NSURL) == nil, loading[url] == nil else { return }
        Task { _ = await image(for: url) }
    }

    nonisolated private static func decode(_ url: URL) async -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

struct ComicReaderView: View {
    let controller: PageController
    @State private var image: NSImage?
    @State private var cache = ComicPageCache()

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
            // Kliknięcie w lewą albo prawą część strony przewraca kartkę (jak w web UI).
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture { controller.previous() }
                Color.clear.contentShape(Rectangle()).onTapGesture { controller.next() }
            }
        }
        .task(id: controller.page) {
            let index = controller.page - 1
            guard controller.images.indices.contains(index) else { image = nil; return }
            let loaded = await cache.image(for: controller.images[index])
            // Szybkie przewracanie: wczytanie starej strony nie nadpisuje nowszej.
            guard !Task.isCancelled else { return }
            image = loaded
            if controller.images.indices.contains(index + 1) { cache.prefetch(controller.images[index + 1]) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Strona komiksu")
        .accessibilityValue("\(controller.page) z \(controller.pageCount)")
        // VoiceOver: strony przewraca się gestem zwiększania i zmniejszania wartości.
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: controller.next()
            case .decrement: controller.previous()
            @unknown default: break
            }
        }
    }
}
