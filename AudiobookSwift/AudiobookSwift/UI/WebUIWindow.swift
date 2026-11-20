import SwiftUI

/// Okno z web UI audiobookshelf; gdy serwer nie działa, pokazuje jego stan.
struct WebUIWindow: View {
    static let windowID = "web-ui"

    let supervisor: ServerSupervisor

    var body: some View {
        Group {
            switch supervisor.state {
            case .running:
                if let url = supervisor.webURL {
                    WebUIView(url: url)
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
                    if let lastLine = supervisor.recentLog.last(where: { !$0.isEmpty }) {
                        Text(lastLine)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                } actions: {
                    Button("Uruchom ponownie") { supervisor.start() }
                }
            }
        }
        .frame(minWidth: 800, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
    }
}
