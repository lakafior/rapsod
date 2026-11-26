import AudiobookshelfPlayback
import SwiftUI

struct ServerMenu: View {
    let supervisor: ServerSupervisor
    let account: ServerAccount
    let loginItem: LoginItem
    let webMode: WebUIMode
    let settings: SettingsNavigation
    let player: AudiobookPlayer
    let updates: UpdateController
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MenuOptions.showsPairPhoneKey) private var showsPairPhone = false

    var body: some View {
        Text(supervisor.state.title)

        Divider()

        MenuPlayerControls(player: player)

        // Codzienna praca jest natywna (okno „Biblioteka” i „Ustawienia”); web UI zostaje
        // jako wyjście awaryjne pod Option (etap 9i): przy bibliotece — web UI słuchacza, przy
        // ustawieniach — zarządzanie serwerem na koncie root.
        Button("Otwórz bibliotekę") {
            openWindow.bringToFront(id: LibraryWindow.windowID)
        }
        .keyboardShortcut("o")
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
        .modifierKeyAlternate(.option) {
            Button("Zarządzanie serwerem (web UI)…") {
                webMode.isManagement = true
                openWindow.bringToFront(id: WebUIWindow.windowID)
            }
            .disabled(account.state != .ready)
        }

        // Opcja z Ogólne › Aplikacja (decyzja z części 9 planu): domyślnie wyłączona.
        if showsPairPhone {
            Button("Podłącz telefon…") {
                settings.pendingMacPairing = true
                openWindow.openSettings(.users, navigation: settings)
            }
            .disabled(account.state != .ready)
        }

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

        Button("O programie Rapsod") {
            openWindow.bringToFront(id: AboutWindow.windowID)
        }
        UpdateMenuItem(updates: updates)

        // Zakończenie razem z serwerem, tak jak ⌘Q w menu aplikacji.
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

/// Opcje menu na pasku menu ustawiane w Ogólne › Aplikacja.
enum MenuOptions {
    static let showsPairPhoneKey = "menu.showsPairPhone"
}
