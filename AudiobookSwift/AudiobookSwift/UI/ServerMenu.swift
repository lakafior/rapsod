import SwiftUI

struct ServerMenu: View {
    let supervisor: ServerSupervisor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(supervisor.state.title)

        Divider()

        Button("Otwórz") {
            openWindow(id: WebUIWindow.windowID)
            // Aplikacja bez ikony w Docku nie staje się aktywna sama z siebie,
            // a `activate()` jest tylko prośbą — okno wysuwamy na wierzch niezależnie.
            NSApp.activate()
            Task {
                let window = NSApp.windows.first { $0.identifier?.rawValue == WebUIWindow.windowID }
                window?.orderFrontRegardless()
                window?.makeKey()
            }
        }
        .keyboardShortcut("o")

        Divider()

        Button("Uruchom serwer") {
            supervisor.start()
        }
        .disabled(!supervisor.state.canStart)

        Button("Zatrzymaj serwer") {
            Task { await supervisor.stop() }
        }
        .disabled(!supervisor.state.canStop)

        Button("Uruchom ponownie") {
            Task { await supervisor.restart() }
        }
        .disabled(!supervisor.state.canStop)

        Divider()

        Button("Zakończ") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

extension ServerState {
    var title: String {
        switch self {
        case .stopped: "Serwer zatrzymany"
        case .starting: "Uruchamianie serwera…"
        case .running: "Serwer działa"
        case .stopping: "Zatrzymywanie serwera…"
        case .failed(let message): "Błąd: \(message)"
        }
    }

    var symbolName: String {
        switch self {
        case .running: "books.vertical.fill"
        case .failed: "exclamationmark.triangle"
        case .stopped, .starting, .stopping: "books.vertical"
        }
    }

    var canStart: Bool {
        switch self {
        case .stopped, .failed: true
        case .starting, .running, .stopping: false
        }
    }

    var canStop: Bool {
        switch self {
        case .starting, .running: true
        case .stopped, .stopping, .failed: false
        }
    }
}
