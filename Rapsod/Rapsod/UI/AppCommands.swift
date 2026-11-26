import SwiftUI

/// Menu główne, widoczne wtedy, gdy aplikacja ma otwarte okno (i ikonę w Docku).
/// Menu Edycja, Okno i skrót ⌘W dodaje SwiftUI.
struct AppCommands: Commands {
    let account: ServerAccount
    let webMode: WebUIMode
    let settings: SettingsNavigation
    let updates: UpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("O programie Rapsod") {
                openWindow.bringToFront(id: AboutWindow.windowID)
            }
            UpdateMenuItem(updates: updates)
        }

        CommandGroup(replacing: .appSettings) {
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
        }

        CommandGroup(replacing: .appTermination) {
            Button("Zakończ Rapsod") {
                AppQuit.quit()
            }
            .keyboardShortcut("q")
        }

        // Czerwony przycisk i ⌘W chowają okno; to samo dla wszystkich okien naraz.
        // Serwer i ikona na pasku menu zostają.
        CommandGroup(after: .windowArrangement) {
            Button("Zamknij wszystkie okna") {
                DockIcon.closeAllWindows()
            }
            .keyboardShortcut("w", modifiers: [.option, .command])
        }

        CommandGroup(replacing: .newItem) {
            Button("Otwórz bibliotekę") {
                openWindow.bringToFront(id: LibraryWindow.windowID)
            }
            .keyboardShortcut("o")
            // Web UI tylko jako wyjście awaryjne pod Option (etap 9i).
            .modifierKeyAlternate(.option) {
                Button("\(WebUIWindow.title)…") {
                    webMode.isManagement = false
                    openWindow.bringToFront(id: WebUIWindow.windowID)
                }
                .disabled(account.state != .ready)
            }
        }
    }
}
