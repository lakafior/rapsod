import SwiftUI

/// Przełącznik siatka/lista w pasku narzędzi (etap 14c), jak w Finderze. Tryb pamięta każdy
/// widok osobno (`LibraryBrowser.viewModes`); ⌘1 i ⌘2 w menu Widok robią to samo.
struct ViewModePicker: View {
    let browser: LibraryBrowser
    let context: LibraryBrowser.ViewContext

    var body: some View {
        Picker("Widok", selection: Binding(get: { browser.viewMode(context) }, set: { browser.setViewMode($0, for: context) })) {
            Label("Kafelki", systemImage: "square.grid.2x2").tag(LibraryBrowser.ViewMode.grid)
            Label("Lista", systemImage: "list.bullet").tag(LibraryBrowser.ViewMode.list)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .help("Pokaż jako kafelki albo listę (⌘1, ⌘2)")
        .accessibilityIdentifier("viewMode")
    }
}

extension FocusedValues {
    /// Stan przeglądania okna „Biblioteka” na pierwszym planie — dla menu Widok.
    @Entry var libraryBrowser: LibraryBrowser?
}

/// Pozycje „Jako kafelki” i „Jako lista” w menu Widok (⌘1, ⌘2). Działają w widokach z przełącznikiem.
struct LibraryViewCommands: Commands {
    @FocusedValue(\.libraryBrowser) private var browser

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            ViewModeMenuItems(browser: browser)
            Divider()
        }
    }
}

/// Osobny widok, żeby menu obserwowało zmianę strony i trybu w `LibraryBrowser`.
private struct ViewModeMenuItems: View {
    let browser: LibraryBrowser?

    var body: some View {
        let context = browser?.currentViewContext
        item("Jako kafelki", .grid, "1", context)
        item("Jako lista", .list, "2", context)
    }

    private func item(_ title: String, _ mode: LibraryBrowser.ViewMode, _ key: KeyEquivalent, _ context: LibraryBrowser.ViewContext?) -> some View {
        Toggle(title, isOn: Binding(get: { context.map { browser?.viewMode($0) == mode } ?? false }, set: { _ in
            if let browser, let context { browser.setViewMode(mode, for: context) }
        }))
        .keyboardShortcut(key)
        .disabled(context == nil)
    }
}
