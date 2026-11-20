import SwiftUI

extension OpenWindowAction {
    /// Otwiera okno i wysuwa je na wierzch. Aplikacja bez ikony w Docku nie staje się
    /// aktywna sama z siebie, a `activate()` jest tylko prośbą — okno wysuwamy niezależnie.
    @MainActor
    func bringToFront(id: String) {
        callAsFunction(id: id)
        NSApp.activate()
        Task {
            let window = NSApp.windows.first { $0.identifier?.rawValue == id }
            window?.orderFrontRegardless()
            window?.makeKey()
        }
    }
}

/// Systemowe okno wyboru folderu biblioteki.
@MainActor
func chooseLibraryFolder() async -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = "Wybierz"
    panel.message = "Wybierz folder z audiobookami. Każdy audiobook najlepiej w osobnym podfolderze (np. Autor/Tytuł)."
    NSApp.activate()
    let response = await panel.begin()
    return response == .OK ? panel.url : nil
}
