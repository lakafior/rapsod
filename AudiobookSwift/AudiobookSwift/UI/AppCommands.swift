import SwiftUI

/// Menu główne, widoczne wtedy, gdy aplikacja ma otwarte okno (i ikonę w Docku).
/// Menu Edycja, Okno i skrót ⌘W dodaje SwiftUI.
struct AppCommands: Commands {
    let account: ServerAccount
    let webMode: WebUIMode
    let settings: SettingsNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("O programie AudiobookSwift") {
                openWindow.bringToFront(id: AboutWindow.windowID)
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("\(SettingsWindow.title)…") {
                openWindow.openSettings(navigation: settings)
            }
            .keyboardShortcut(",")
        }

        CommandGroup(replacing: .appTermination) {
            Button("Zamknij okna (serwer działa dalej)") {
                DockIcon.closeAllWindows()
            }
            .keyboardShortcut("q")
            Button("Zakończ AudiobookSwift i wyłącz serwer") {
                AppQuit.quit()
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("Otwórz bibliotekę") {
                webMode.isManagement = false
                openWindow.bringToFront(id: WebUIWindow.windowID)
            }
            .keyboardShortcut("o")
            Button("Zarządzanie serwerem…") {
                webMode.isManagement = true
                openWindow.bringToFront(id: WebUIWindow.windowID)
            }
            .disabled(account.state != .ready)
        }
    }
}
