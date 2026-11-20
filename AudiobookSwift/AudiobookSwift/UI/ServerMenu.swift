import SwiftUI

struct ServerMenu: View {
    let supervisor: ServerSupervisor
    let account: ServerAccount
    let loginItem: LoginItem
    let webMode: WebUIMode
    let settings: SettingsNavigation
    let player: AudiobookPlayer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(supervisor.state.title)

        Divider()

        MenuPlayerControls(player: player)

        Button("Otwórz bibliotekę") {
            openWindow.bringToFront(id: LibraryWindow.windowID)
        }
        .keyboardShortcut("o")

        // Przeglądanie i słuchanie są w oknie „Biblioteka”; web UI słuchacza zostaje jako wyjście
        // awaryjne pod Option (i w menu aplikacji), zarządzanie na koncie root — bez zmian.
        Button("Zarządzanie serwerem…") {
            webMode.isManagement = true
            openWindow.bringToFront(id: WebUIWindow.windowID)
        }
        .disabled(account.state != .ready)
        .modifierKeyAlternate(.option) {
            Button("\(WebUIWindow.title)…") {
                webMode.isManagement = false
                openWindow.bringToFront(id: WebUIWindow.windowID)
            }
        }

        Button("\(SettingsWindow.title)…") {
            openWindow.openSettings(navigation: settings)
        }
        .keyboardShortcut(",")

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

        Toggle("Uruchamiaj przy logowaniu", isOn: Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.setEnabled($0) }
        ))
        if loginItem.requiresApproval {
            Button("Wymaga zgody — otwórz Ustawienia systemowe…") {
                loginItem.openSystemSettings()
            }
        }

        Divider()

        Button("O programie AudiobookSwift") {
            openWindow.bringToFront(id: AboutWindow.windowID)
        }

        // Jedyne miejsce (poza menu aplikacji) pełnego zakończenia razem z serwerem.
        Button("Zakończ") {
            AppQuit.quit()
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
        case .failed: "Błąd serwera — szczegóły w ustawieniach"
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
