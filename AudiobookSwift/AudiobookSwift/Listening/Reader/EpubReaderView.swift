import AppKit
import OSLog
import SwiftUI
import WebKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Reader")

/// Czytnik EPUB: WKWebView z epub.js (ta sama wersja i opcje co web UI — pozycja CFI jest
/// zgodna z web UI i aplikacjami na telefon). Własny parser musiałby odtworzyć CFI epub.js
/// co do znaku, inaczej pozycje rozjeżdżałyby się między urządzeniami.
///
/// Bezpieczeństwo: treść e-booka jest obca. Strona i książka przychodzą ze schematu `absreader:`,
/// który podaje tylko stałą listę plików; skrypty w książce są wyłączone (`allowScriptedContent`),
/// magazyn danych jest ulotny, a reguła treści blokuje wszystko z http(s). Linki zewnętrzne
/// otwierają się w domyślnej przeglądarce. Token konta nie trafia do WebKitu — plik czytamy z dysku.
@MainActor
@Observable
final class EpubController {
    struct TocItem: Identifiable, Hashable {
        let id: Int
        let label: String
        let href: String
        let depth: Int
    }

    struct Position: Equatable {
        var cfi: String
        /// Znany dopiero po policzeniu lokacji przez epub.js.
        var percentage: Double?
        var chapter: String?
    }

    private(set) var toc: [TocItem] = []
    private(set) var position: Position?
    private(set) var isOpened = false
    private(set) var hasLocations = false
    private(set) var error: String?

    let fileURL: URL
    let startLocation: String?
    /// Lokacje epub.js zapamiętane z poprzedniego otwarcia (liczenie trwa przy dużych książkach).
    private let locationsCache: URL
    /// Wywoływane przy każdej zmianie miejsca czytania (zapis postępu).
    var onRelocated: ((Position) -> Void)?

    @ObservationIgnored fileprivate weak var webView: WKWebView?
    @ObservationIgnored private var pendingSettings: ReaderSettings?
    @ObservationIgnored fileprivate var isPageReady = false

    init(fileURL: URL, cacheKey: String, startLocation: String?) {
        self.fileURL = fileURL
        self.startLocation = startLocation
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.main.bundleIdentifier ?? "AudiobookSwift", directoryHint: .isDirectory)
            .appending(path: "ReaderLocations", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // Klucz z rozmiarem: podmieniony plik pod tym samym `ino` liczy lokacje od nowa.
        locationsCache = directory.appending(path: "\(cacheKey.replacingOccurrences(of: "/", with: "_"))-\(size).json")
    }

    func left() { call("reader.left()") }
    func right() { call("reader.right()") }
    func next() { call("reader.next()") }
    func previous() { call("reader.prev()") }
    func go(to item: TocItem) { call("reader.display(\(Self.json(item.href)))") }
    func seek(_ fraction: Double) { call("reader.seek(\(fraction))") }

    func apply(_ settings: ReaderSettings) {
        guard isPageReady else { pendingSettings = settings; return }
        call("reader.apply(\(settings.json))")
    }

    fileprivate func pageReady(settings: ReaderSettings) {
        isPageReady = true
        let locations = try? String(contentsOf: locationsCache, encoding: .utf8)
        var options = "{settings: \((pendingSettings ?? settings).json)"
        if let startLocation { options += ", location: \(Self.json(startLocation))" }
        if let locations, !locations.isEmpty { options += ", locations: \(Self.json(locations))" }
        options += "}"
        #if DEBUG
        Self.debugLog(["type": "start", "message": startLocation ?? "(brak)"])
        #endif
        call("reader.open(\(options))")
        pendingSettings = nil
    }

    fileprivate func handle(_ body: [String: Any]) {
        #if DEBUG
        Self.debugLog(body)
        #endif
        switch body["type"] as? String {
        case "opened":
            isOpened = true
            let items = body["toc"] as? [[String: Any]] ?? []
            toc = items.enumerated().map { index, entry in
                TocItem(id: index, label: entry["label"] as? String ?? "", href: entry["href"] as? String ?? "", depth: entry["depth"] as? Int ?? 0)
            }
        case "relocated":
            guard let cfi = body["cfi"] as? String else { return }
            let next = Position(cfi: cfi, percentage: body["percentage"] as? Double, chapter: body["chapter"] as? String)
            guard next != position else { return }
            position = next
            onRelocated?(next)
        case "locations":
            // `book.locations.save()` to tekst JSON — zapisujemy go wprost, bez przeglądania.
            if let json = body["json"] as? String { try? json.write(to: locationsCache, atomically: true, encoding: .utf8) }
        case "log":
            logger.notice("EPUB: \(body["message"] as? String ?? "", privacy: .public)")
        case "locationsReady":
            hasLocations = true
        case "error":
            let message = body["message"] as? String ?? "nieznany błąd"
            logger.error("EPUB: \(message, privacy: .public)")
            if !isOpened { error = message }
        default:
            break
        }
    }

    private func call(_ script: String) {
        webView?.evaluateJavaScript(script) { _, error in
            if let error { logger.debug("EPUB JS: \(error.localizedDescription, privacy: .public)") }
        }
    }

    #if DEBUG
    /// Diagnostyka czytnika w wersji Debug (`$TMPDIR/AudiobookSwift-reader.log`).
    private static func debugLog(_ body: [String: Any]) {
        let url = FileManager.default.temporaryDirectory.appending(path: "AudiobookSwift-reader.log")
        let line = "\(Date()) \(body["type"] as? String ?? "?") \(String(describing: body["message"] ?? body["cfi"] ?? ""))\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
    #endif

    static func json(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }
}

struct EpubReaderView: NSViewRepresentable {
    let controller: EpubController
    let settings: ReaderSettings

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, settings: settings) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator.files, forURLScheme: ReaderFiles.scheme)
        configuration.userContentController.add(WeakMessageHandler(context.coordinator), name: "reader")
        configuration.preferences.isTextInteractionEnabled = true
        let webView = ReaderWebView(frame: .zero, configuration: configuration)
        webView.onKey = { [weak controller] key in
            switch key {
            case .left: controller?.left()
            case .right: controller?.right()
            case .previous: controller?.previous()
            case .next: controller?.next()
            }
        }
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        controller.webView = webView
        context.coordinator.load(into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.settings != settings {
            context.coordinator.settings = settings
            controller.apply(settings)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        webView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let controller: EpubController
        var settings: ReaderSettings
        let files: ReaderFiles

        init(controller: EpubController, settings: ReaderSettings) {
            self.controller = controller
            self.settings = settings
            files = ReaderFiles(book: controller.fileURL)
        }

        func load(into webView: WKWebView) {
            // Wszystko z http(s) zablokowane — także obrazki i czcionki, do których odwołuje się książka.
            let rules = #"[{"trigger":{"url-filter":"^(https?|wss?|ftp)://"},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "AudiobookSwiftReaderOffline", encodedContentRuleList: rules) { list, error in
                MainActor.assumeIsolated {
                    if let list {
                        webView.configuration.userContentController.add(list)
                    } else if let error {
                        logger.error("Reguła treści czytnika: \(error.localizedDescription, privacy: .public)")
                    }
                    webView.load(URLRequest(url: ReaderFiles.pageURL))
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if body["type"] as? String == "ready" {
                controller.pageReady(settings: settings)
            } else {
                controller.handle(body)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
            if [ReaderFiles.scheme, "about", "blob", "data"].contains(scheme) { return .allow }
            if navigationAction.navigationType == .linkActivated { Self.openExternally(url) }
            return .cancel
        }

        // Linki zewnętrzne w treści epub.js dostają `target="_blank"`.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { Self.openExternally(url) }
            return nil
        }

        private static func openExternally(_ url: URL) {
            guard ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(url)
        }
    }
}

/// WKWebView, który sam obsługuje klawisze przewracania stron — zanim trafią do WebKitu.
final class ReaderWebView: WKWebView {
    enum Key { case left, right, previous, next }
    var onKey: ((Key) -> Void)?

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 123: onKey?(.left)
        case 124: onKey?(.right)
        case 116: onKey?(.previous) // Page Up
        case 121, 49: onKey?(event.modifierFlags.contains(.shift) ? .previous : .next) // Page Down, spacja
        default: super.keyDown(with: event)
        }
    }
}

/// Pośrednik bez silnej referencji — `WKUserContentController` trzyma swoje obsługi na stałe.
@MainActor
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Schemat `absreader:` — strona czytnika, epub.js, JSZip i jeden e-book. Nic więcej.
@MainActor
final class ReaderFiles: NSObject, WKURLSchemeHandler {
    static let scheme = "absreader"
    static let pageURL = URL(string: "absreader://local/reader.html")!

    private let book: URL

    init(book: URL) {
        self.book = book
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let source: (URL, String)? = switch url.path {
        case "/reader.html": Bundle.main.url(forResource: "reader", withExtension: "html").map { ($0, "text/html; charset=utf-8") }
        case "/reader.js": Bundle.main.url(forResource: "reader", withExtension: "js").map { ($0, "text/javascript; charset=utf-8") }
        case "/epub.min.js": Bundle.main.url(forResource: "epub.min", withExtension: "js").map { ($0, "text/javascript; charset=utf-8") }
        case "/jszip.min.js": Bundle.main.url(forResource: "jszip.min", withExtension: "js").map { ($0, "text/javascript; charset=utf-8") }
        case "/book.epub": (book, "application/epub+zip")
        default: nil
        }
        guard let (file, type) = source, let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
            task.didReceive(response)
            task.didFinish()
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": type,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
