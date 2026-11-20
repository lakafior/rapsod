import SwiftUI
import WebKit

/// Okno ze stronami agregatora (`/admin`, `/search-ui`): konfiguracja źródeł i wyszukiwarka.
/// Otwarcie budzi agregator i nie pozwala mu zasnąć; po zamknięciu widok jest zwalniany
/// (scena jest opakowana w `ReleasedWhenClosed`), a agregator zasypia po zwykłym czasie.
struct MetadataSourcesWindow: View {
    static let windowID = "metadata-sources"

    let sources: MetadataSourcesController

    private enum Content {
        case loading
        case page(URL)
        case failed(String)
    }

    @State private var content = Content.loading
    /// Rośnie przy „Spróbuj ponownie”, żeby wczytać stronę od nowa.
    @State private var attempt = 0

    private struct LoadKey: Equatable {
        let page: MetadataSourcesController.Page
        let isEnabled: Bool
        let attempt: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Strona", selection: Binding(get: { sources.page }, set: { sources.page = $0 })) {
                Text("Konfiguracja").tag(MetadataSourcesController.Page.configuration)
                Text("Wyszukiwarka").tag(MetadataSourcesController.Page.search)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(8)

            Divider()

            Group {
                if !sources.isEnabled {
                    ContentUnavailableView(
                        "Źródła metadanych są wyłączone",
                        systemImage: "text.book.closed",
                        description: Text("Włącz je w oknie „Status i logi”.")
                    )
                } else {
                    switch content {
                    case .loading:
                        ProgressView("Uruchamianie źródeł metadanych…")
                    case .page(let url):
                        AggregatorPageView(url: url)
                            // Zmiana strony albo ponowna próba wymaga nowego widoku.
                            .id(url)
                    case .failed(let message):
                        ContentUnavailableView {
                            Label("Źródła metadanych nie działają", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(message)
                        } actions: {
                            Button("Spróbuj ponownie") { attempt += 1 }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 520)
        .task(id: LoadKey(page: sources.page, isEnabled: sources.isEnabled, attempt: attempt)) {
            await load()
        }
        .onDisappear {
            content = .loading
            sources.closePage()
        }
    }

    private func load() async {
        guard sources.isEnabled else {
            sources.closePage()
            return
        }
        content = .loading
        do {
            let url = try await sources.openPage(sources.page)
            guard !Task.isCancelled else { return }
            content = .page(url)
        } catch {
            guard !Task.isCancelled else { return }
            content = .failed(error.localizedDescription)
        }
    }
}

/// `WKWebView` ze stroną agregatora. Adres zawiera klucz API, więc nie trafia do logu,
/// a dane strony żyją tylko w pamięci (magazyn nietrwały, znika razem z widokiem).
private struct AggregatorPageView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(origin: url)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        private let origin: URL

        init(origin: URL) {
            self.origin = origin
        }

        private func isOwnPage(_ url: URL) -> Bool {
            url.scheme == origin.scheme && url.host() == origin.host() && url.port == origin.port
        }

        /// W oknie zostają tylko strony agregatora; linki do serwisów (wyniki wyszukiwania)
        /// otwiera domyślna przeglądarka.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let target = navigationAction.request.url, navigationAction.targetFrame?.isMainFrame != false else { return .allow }
            if isOwnPage(target) || target.scheme == "about" { return .allow }
            NSWorkspace.shared.open(target)
            return .cancel
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let target = navigationAction.request.url {
                if isOwnPage(target) {
                    webView.load(navigationAction.request)
                } else {
                    NSWorkspace.shared.open(target)
                }
            }
            return nil
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
            let alert = NSAlert()
            alert.messageText = message
            await present(alert, for: webView)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Anuluj")
            return await present(alert, for: webView) == .alertFirstButtonReturn
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
