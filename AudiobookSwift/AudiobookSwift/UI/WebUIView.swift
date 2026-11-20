import OSLog
import SwiftUI
import WebKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "WebUI")

/// `WKWebView` z web UI serwera. Sesja (token w localStorage) żyje w domyślnym
/// magazynie danych WebKit, więc przetrwa zamknięcie okna i restart aplikacji.
///
/// Z `login` web UI loguje się samo: klient web trzyma access token w
/// `localStorage['token']`, a refresh token w ciasteczku `refresh_token`
/// (`client/store/user.js`, `server/auth/TokenManager.js` upstreamu). Ustawiamy oba,
/// zanim strona się załaduje.
struct WebUIView: NSViewRepresentable {
    let url: URL
    var login: AudiobookshelfClient.Login?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let login {
            configuration.userContentController.addUserScript(Self.tokenScript(accessToken: login.accessToken))
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.allowsBackForwardNavigationGestures = true
        let request = URLRequest(url: url)
        if let refreshToken = login?.refreshToken, let cookie = Self.refreshCookie(refreshToken, for: url) {
            Task {
                await configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
                logger.notice("Ładuję \(url.absoluteString, privacy: .public) z automatycznym logowaniem")
                webView.load(request)
            }
        } else {
            logger.notice("Ładuję \(url.absoluteString, privacy: .public)")
            webView.load(request)
        }
        return webView
    }

    /// Ustawia token przed uruchomieniem skryptów strony; tylko przy pierwszym załadowaniu
    /// dokumentu, żeby nie nadpisywać tokenu odświeżonego później przez samo web UI.
    private static func tokenScript(accessToken: String) -> WKUserScript {
        let literal = (try? String(decoding: JSONEncoder().encode(accessToken), as: UTF8.self)) ?? "\"\""
        let source = """
        if (!sessionStorage.getItem('audiobookswift-login')) {
          localStorage.setItem('token', \(literal));
          sessionStorage.setItem('audiobookswift-login', '1');
        }
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    private static func refreshCookie(_ token: String, for url: URL) -> HTTPCookie? {
        guard let host = url.host() else { return nil }
        return HTTPCookie(properties: [
            .name: "refresh_token",
            .value: token,
            .domain: host,
            .path: "/",
            .expires: Date.now.addingTimeInterval(30 * 24 * 60 * 60),
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
            .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax.rawValue,
        ])
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    /// Bez delegata `WKWebView` po cichu ignoruje `alert()`, `confirm()`,
    /// wybór plików i linki otwierane w nowym oknie.
    @MainActor
    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            logger.notice("Załadowano \(webView.url?.absoluteString ?? "?", privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            logger.error("Nie udało się załadować strony: \(error.localizedDescription, privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            logger.error("Błąd nawigacji: \(error.localizedDescription, privacy: .public)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            logger.error("Proces WebContent zakończył się; przeładowuję")
            webView.reload()
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let target = navigationAction.request.url {
                if target.host() == webView.url?.host(), target.port == webView.url?.port {
                    webView.load(navigationAction.request)
                } else {
                    NSWorkspace.shared.open(target)
                }
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo
        ) async {
            let alert = NSAlert()
            alert.messageText = message
            await present(alert, for: webView)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo
        ) async -> Bool {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Anuluj")
            return await present(alert, for: webView) == .alertFirstButtonReturn
        }

        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo
        ) async -> [URL]? {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            let response: NSApplication.ModalResponse
            if let window = webView.window {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            return response == .OK ? panel.urls : nil
        }

        @discardableResult
        private func present(_ alert: NSAlert, for webView: WKWebView) async -> NSApplication.ModalResponse {
            if let window = webView.window {
                await alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }
}
