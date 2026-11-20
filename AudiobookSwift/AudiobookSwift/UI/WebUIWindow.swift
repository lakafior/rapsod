import SwiftUI

/// Okno z web UI audiobookshelf; gdy serwer nie działa, pokazuje jego stan.
struct WebUIWindow: View {
    static let windowID = "web-ui"

    let supervisor: ServerSupervisor
    let account: ServerAccount

    /// Gotowość do załadowania: z sesją (automatyczne logowanie) albo bez (ręczne).
    private enum WebSession: Equatable {
        case pending
        case ready(AudiobookshelfClient.Login?)

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.pending, .pending): true
            case let (.ready(a), .ready(b)): a?.accessToken == b?.accessToken
            default: false
            }
        }
    }

    @State private var session: WebSession = .pending
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch supervisor.state {
            case .running:
                if let url = supervisor.webURL, case .ready(let login) = session {
                    WebUIView(url: url, login: login)
                } else {
                    ProgressView("Logowanie…")
                }
            case .starting:
                ProgressView("Uruchamianie serwera…")
            case .stopping:
                ProgressView("Zatrzymywanie serwera…")
            case .stopped:
                ContentUnavailableView {
                    Label("Serwer zatrzymany", systemImage: "books.vertical")
                } actions: {
                    Button("Uruchom serwer") { supervisor.start() }
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Serwer nie działa", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Uruchom ponownie") { supervisor.start() }
                    Button("Status i logi…") { openWindow.bringToFront(id: StatusWindow.windowID) }
                }
            }
        }
        .frame(minWidth: 800, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        .task(id: account.state) { await prepareSession() }
        .onChange(of: supervisor.state) {
            if supervisor.state != .running { session = .pending }
        }
    }

    private func prepareSession() async {
        switch account.state {
        case .disconnected, .connecting:
            // Czekamy — po połączeniu `task(id:)` uruchomi się ponownie.
            return
        case .ready:
            // Raz załadowanej strony nie przeładowujemy przy zmianach stanu konta.
            guard session == .pending else { return }
            let login = try? await account.webSession()
            session = .ready(login)
        case .needsPassword, .failed:
            // Bez danych logowania web UI pokaże własny formularz logowania.
            if session == .pending { session = .ready(nil) }
        }
    }
}
