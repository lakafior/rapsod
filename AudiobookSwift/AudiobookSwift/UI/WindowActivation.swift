import SwiftUI

extension OpenWindowAction {
    /// Otwiera okno i wysuwa je na wierzch. Aplikacja bez okien nie ma ikony w Docku i nie staje się
    /// aktywna sama z siebie, a `activate()` jest tylko prośbą — okno wysuwamy niezależnie.
    @MainActor
    func bringToFront(id: String) {
        // Ikona w Docku jest potrzebna, zanim aplikacja poprosi o aktywację: tylko w tej
        // chwili (zaraz po kliknięciu w menu) system ją przyzna. Dalej pilnuje `DockIcon`.
        DockIcon.shared.windowWillOpen()
        callAsFunction(id: id)
        NSApp.activate()
        Task {
            let window = NSApp.windows.first { $0.identifier?.rawValue == id }
            window?.orderFrontRegardless()
            window?.makeKey()
        }
    }
}

/// Treść okna istnieje tylko wtedy, gdy okno jest otwarte. Scena `Window` po zamknięciu
/// tylko chowa okno i trzyma jego widoki (z obserwacją modelu włącznie), więc puste
/// zamknięte okno zwalnia to, co zajmowały.
struct ReleasedWhenClosed<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var isOpen = true

    var body: some View {
        ZStack {
            if isOpen {
                content()
            }
        }
        .onAppear { isOpen = true }
        .onDisappear { isOpen = false }
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
