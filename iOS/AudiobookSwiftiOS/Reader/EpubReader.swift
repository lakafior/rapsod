// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 10g).

import SwiftUI
import WebKit
import OSLog
import AudiobookshelfKit

private let logger = Logger(subsystem: "net.smigi.abswift.ios", category: "Reader")

/// Wygląd strony EPUB-a.
struct ReaderLook: Codable, Equatable {
    enum Theme: String, Codable, CaseIterable, Identifiable {
        case light, sepia, dark
        var id: String { rawValue }
        var name: String {
            switch self {
            case .light: "Jasny"
            case .sepia: "Sepia"
            case .dark: "Ciemny"
            }
        }
        var page: Color { Color(hex: pageHex) }
        var ink: Color { Color(hex: inkHex) }
        var pageHex: String {
            switch self {
            case .light: "#ffffff"
            case .sepia: "#f4ecd8"
            case .dark: "#1c1c1e"
            }
        }
        var inkHex: String {
            switch self {
            case .light: "#1c1c1e"
            case .sepia: "#5b4636"
            case .dark: "#e5e5ea"
            }
        }
        var linkHex: String {
            switch self {
            case .light: "#0a60c2"
            case .sepia: "#8a4b0f"
            case .dark: "#64a8ff"
            }
        }
        var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    }

    enum Font: String, Codable, CaseIterable, Identifiable {
        case publisher, serif, sans
        var id: String { rawValue }
        var name: String {
            switch self {
            case .publisher: "Wydawcy"
            case .serif: "Szeryfowy"
            case .sans: "Bezszeryfowy"
            }
        }
        var css: String {
            switch self {
            case .publisher: ""
            case .serif: "ui-serif, 'New York', Georgia, serif"
            case .sans: "-apple-system, system-ui, sans-serif"
            }
        }
    }

    enum Margins: String, Codable, CaseIterable, Identifiable {
        case narrow, medium, wide
        var id: String { rawValue }
        var name: String {
            switch self {
            case .narrow: "Wąskie"
            case .medium: "Średnie"
            case .wide: "Szerokie"
            }
        }
        var points: Double {
            switch self {
            case .narrow: 12
            case .medium: 24
            case .wide: 44
            }
        }
    }

    var theme: Theme = .light
    var font: Font = .publisher
    /// Zmiana rozmiaru względem Dynamic Type, w krokach po 10%.
    var sizeStep: Int = 0
    var margins: Margins = .medium

    static let sizeSteps = -4...10
    static let storageKey = "reader.look"

    static func load() -> ReaderLook {
        guard let data = UserDefaults.standard.data(forKey: storageKey), let look = try? JSONDecoder().decode(ReaderLook.self, from: data) else {
            return ReaderLook()
        }
        return look
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }

    /// Rozmiar tekstu w procentach: Dynamic Type (tekst „body” względem domyślnych 17 pt) i krok użytkownika.
    func fontPercent(dynamicType: UIContentSizeCategory) -> Int {
        let traits = UITraitCollection(preferredContentSizeCategory: dynamicType)
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize
        return Int((body / 17 * 100 * (1 + Double(sizeStep) / 10)).rounded())
    }

    func javaScript(dynamicType: UIContentSizeCategory) -> [String: Any] {
        ["page": theme.pageHex, "ink": theme.inkHex, "link": theme.linkHex, "font": font.css,
         "size": fontPercent(dynamicType: dynamicType), "leading": 1.5]
    }
}

extension Color {
    init(hex: String) {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}

/// Pozycja w spisie treści.
struct ReaderTocItem: Identifiable, Hashable {
    let id: Int
    let label: String
    let href: String
    let depth: Int
}

/// Sterowanie stroną z epub.js: polecenia do `window.book`, zdarzenia z `webkit.messageHandlers.book`.
@MainActor @Observable
final class EpubController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    struct Place: Equatable {
        var cfi: String
        var href: String?
        var progress: Double?
        var chapter: String?
        var atStart: Bool
        var atEnd: Bool
    }

    private(set) var toc: [ReaderTocItem] = []
    private(set) var place: Place?
    private(set) var hasLocations = false
    private(set) var isRightToLeft = false
    private(set) var failure: String?

    /// Nowe miejsce w książce (po pierwszym wyświetleniu zapisanego miejsca).
    @ObservationIgnored var onMove: ((Place) -> Void)?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let files: BookFiles
    @ObservationIgnored private var startLocation: String?
    @ObservationIgnored private var look: [String: Any]
    @ObservationIgnored private var layout: [String: Any]
    @ObservationIgnored private var spread: String
    @ObservationIgnored private let locationsFile: URL

    /// - Parameters:
    ///   - book: plik EPUB na telefonie.
    ///   - cacheKey: pozycja i wersja pliku — klucz zapamiętanych lokacji epub.js.
    init(book: URL, cacheKey: String, startLocation: String?, look: [String: Any], layout: [String: Any], spread: String) {
        files = BookFiles(book: book)
        self.startLocation = startLocation
        self.look = look
        self.layout = layout
        self.spread = spread
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "EbookLocations", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        locationsFile = caches.appending(path: cacheKey.filter { $0.isLetter || $0.isNumber || $0 == "-" } + ".json")

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(files, forURLScheme: BookFiles.scheme)
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.dataDetectorTypes = []
        configuration.allowsInlineMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let controller = WKUserContentController()
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        #if DEBUG
        webView.isInspectable = true
        #endif
        super.init()
        controller.add(WeakMessageHandler(self), name: "book")
        webView.navigationDelegate = self
        Self.offlineRules { [weak self] rules in
            guard let self else { return }
            if let rules { controller.add(rules) }
            webView.load(URLRequest(url: URL(string: "\(BookFiles.scheme)://local/book-reader.html")!))
        }
    }

    // MARK: - Polecenia

    func next() { call("book.next()") }
    func previous() { call("book.prev()") }
    func go(_ item: ReaderTocItem) { call("book.go(\(Self.json(item.href)))") }
    func go(cfi: String) { call("book.go(\(Self.json(cfi)))") }
    func seek(_ fraction: Double) { call("book.seek(\(fraction))") }

    /// Etap 11c: rozdział i tekst od początku bieżącej strony.
    func pageText() async -> (href: String, text: String)? {
        let result = try? await webView.callAsyncJavaScript("return book.here()", contentWorld: .page)
        guard let body = result as? [String: Any], let href = body["href"] as? String, let text = body["text"] as? String else { return nil }
        return (href, text)
    }

    /// Etap 11c: przejście do fragmentu rozdziału; `false` — nie ma go w e-booku.
    func show(_ passage: EbookAudioSync.Passage) async -> Bool {
        let result = try? await webView.callAsyncJavaScript("return await book.find(href, key, occurrence)",
                                                            arguments: ["href": passage.href, "key": passage.key, "occurrence": passage.occurrence],
                                                            contentWorld: .page)
        logger.debug("Fragment \(passage.href, privacy: .public) zdanie \(passage.sentence) → \(String(describing: result), privacy: .public)")
        return result is String
    }

    func setLook(_ look: [String: Any]) {
        self.look = look
        call("book.setLook(\(Self.json(look)))")
    }

    func setLayout(_ layout: [String: Any]) {
        guard !NSDictionary(dictionary: layout).isEqual(to: self.layout) else { return }
        self.layout = layout
        call("book.setLayout(\(Self.json(layout)))")
    }

    func setSpread(_ spread: String) {
        guard spread != self.spread else { return }
        self.spread = spread
        call("book.setSpread(\(Self.json(spread)))")
    }

    func call(_ script: String) {
        webView.evaluateJavaScript(script) { _, error in
            if let error { logger.debug("JS \(script.prefix(40), privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: - Zdarzenia strony

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let payload = SendableBody(body)
        MainActor.assumeIsolated { handle(type, payload.value) }
    }

    private func handle(_ type: String, _ body: [String: Any]) {
        logger.debug("Strona czytnika: \(type, privacy: .public)")
        switch type {
        case "ready":
            var options: [String: Any] = ["look": look, "layout": layout, "spread": spread]
            if let startLocation { options["location"] = startLocation }
            if let saved = try? String(contentsOf: locationsFile, encoding: .utf8), !saved.isEmpty { options["locations"] = saved }
            call("book.open(\(Self.json(options)))")
        case "opened":
            isRightToLeft = body["rtl"] as? Bool ?? false
            let items = body["toc"] as? [[String: Any]] ?? []
            toc = items.enumerated().map { index, item in
                ReaderTocItem(id: index, label: item["label"] as? String ?? "", href: item["href"] as? String ?? "", depth: item["depth"] as? Int ?? 0)
            }
        case "moved":
            guard let cfi = body["cfi"] as? String else { return }
            let next = Place(cfi: cfi, href: body["href"] as? String, progress: body["progress"] as? Double, chapter: body["chapter"] as? String,
                             atStart: body["atStart"] as? Bool ?? false, atEnd: body["atEnd"] as? Bool ?? false)
            guard next != place else { return }
            place = next
            onMove?(next)
        case "locations":
            // `locations.save()` to tekst JSON — zapisujemy go wprost.
            if let json = body["json"] as? String { try? json.write(to: locationsFile, atomically: true, encoding: .utf8) }
        case "locationsReady":
            hasLocations = true
        case "error":
            let message = body["message"] as? String ?? ""
            logger.error("Czytnik: \(message, privacy: .public)")
            if place == nil, failure == nil, message.contains("wyświetlenie") || message.lowercased().contains("zip") {
                failure = "Nie udało się otworzyć tego EPUB-a (uszkodzony plik albo nieobsługiwana budowa)."
            }
        default:
            logger.debug("Czytnik \(type, privacy: .public): \(String(describing: body["message"] ?? ""), privacy: .public)")
        }
    }

    // MARK: - Nawigacja: tylko strona czytnika; link w treści → rozdział książki

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
        let isMainPage = navigationAction.targetFrame?.isMainFrame == true
        if navigationAction.navigationType == .linkActivated {
            // Link wewnętrzny książki przechodzi przez epub.js; zewnętrzne linki z niezaufanej
            // treści nie otwierają się (czytnik działa bez sieci).
            if scheme == BookFiles.scheme || scheme == "blob" { call("book.link(\(Self.json(url.absoluteString)))") }
            return .cancel
        }
        if isMainPage { return scheme == BookFiles.scheme && url.path == "/book-reader.html" ? .allow : .cancel }
        return [BookFiles.scheme, "about", "blob", "data"].contains(scheme) ? .allow : .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Proces treści zabity przez system (pamięć) — wczytujemy od bieżącego miejsca.
        startLocation = place?.cfi ?? startLocation
        webView.reload()
    }

    // MARK: - Pomocnicze

    static func json(_ value: Any) -> String {
        if let string = value as? String {
            let data = (try? JSONSerialization.data(withJSONObject: [string], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
            return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
        }
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Reguły treści blokujące adresy sieciowe (treść książki nie ma dostępu do sieci).
    private static func offlineRules(_ done: @escaping @MainActor (WKContentRuleList?) -> Void) {
        // Treść książki nie ma dostępu do sieci (do tego CSP strony i ramka bez skryptów).
        let rules = """
        [{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "AudiobookSwiftBookOffline", encodedContentRuleList: rules) { list, error in
            if let error { logger.error("Reguły czytnika: \(error.localizedDescription, privacy: .public)") }
            let list = SendableBox(list)
            Task { @MainActor in done(list.value) }
        }
    }
}

private struct SendableBody: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

private struct SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// `WKUserContentController` trzyma obsługę wiadomości mocno — pośrednik zapobiega cyklowi.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Schemat `abook:` — strona czytnika, jej skrypty (z pakietu aplikacji) i jeden e-book z dysku.
/// Nic poza tą listą: treść książki nie dostanie żadnego innego pliku.
final class BookFiles: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    static let scheme = "abook"
    private let book: URL

    init(book: URL) {
        self.book = book
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let found: (URL, String)? = switch url.path {
        case "/book-reader.html": Bundle.main.url(forResource: "book-reader", withExtension: "html").map { ($0, "text/html; charset=utf-8") }
        case "/book-reader.js": Bundle.main.url(forResource: "book-reader", withExtension: "js").map { ($0, "text/javascript; charset=utf-8") }
        case "/epub.min.js": Bundle.main.url(forResource: "epub.min", withExtension: "js").map { ($0, "text/javascript; charset=utf-8") }
        case "/jszip.min.js": Bundle.main.url(forResource: "jszip.min", withExtension: "js").map { ($0, "text/javascript; charset=utf-8") }
        case "/book.epub": (book, "application/epub+zip")
        default: nil
        }
        guard let (file, type) = found, let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Content-Length": String(data.count), "Cache-Control": "no-store"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Strona EPUB-a z gestami: przesunięcie i dotknięcie brzegu przewracają kartkę, środek
/// pokazuje i chowa paski. Ramka z treścią nie uruchamia skryptów, więc gesty są natywne.
struct EpubPageView: UIViewRepresentable {
    let controller: EpubController
    let toggleChrome: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, toggleChrome: toggleChrome) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = controller.webView
        let left = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipe(_:)))
        left.direction = .left
        let right = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipe(_:)))
        right.direction = .right
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.cancelsTouchesInView = false
        for gesture in [left, right, tap] {
            gesture.delegate = context.coordinator
            webView.addGestureRecognizer(gesture)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.toggleChrome = toggleChrome
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let controller: EpubController
        var toggleChrome: () -> Void

        init(controller: EpubController, toggleChrome: @escaping () -> Void) {
            self.controller = controller
            self.toggleChrome = toggleChrome
        }

        @MainActor @objc func swipe(_ gesture: UISwipeGestureRecognizer) {
            // Przesunięcie w lewo — dalej (w książce od prawej do lewej odwrotnie).
            let forward = (gesture.direction == .left) != controller.isRightToLeft
            forward ? controller.next() : controller.previous()
        }

        @MainActor @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let x = gesture.location(in: view).x / max(1, view.bounds.width)
            if x < 0.25 { controller.isRightToLeft ? controller.next() : controller.previous() }
            else if x > 0.75 { controller.isRightToLeft ? controller.previous() : controller.next() }
            else { toggleChrome() }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
