import AudiobookshelfKit
import SwiftUI

// Menu Plik, Okno, Widok i Pomoc (etap 14f, przegląd HIG `docs/hig-przeglad.md`, p. 2.1, 2.2, 2.5, 2.6).
// Pozycje dotyczące okna „Biblioteka” biorą jego stan z `focusedSceneValue(\.libraryBrowser)`;
// bez okna Biblioteka na pierwszym planie te, które mają sens także bez niego, otwierają je.

/// Plik: nowa pozycja bieżącej biblioteki, nowa biblioteka, skan i Finder.
struct LibraryFileCommands: Commands {
    let account: ServerAccount
    let libraryTasks: LibraryTasks
    let menuBar: MenuBarModel
    let settings: SettingsNavigation
    @FocusedValue(\.libraryBrowser) private var browser

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            FileMenuItems(account: account, libraryTasks: libraryTasks, menuBar: menuBar, settings: settings, browser: browser)
        }
    }
}

private struct FileMenuItems: View {
    let account: ServerAccount
    let libraryTasks: LibraryTasks
    let menuBar: MenuBarModel
    let settings: SettingsNavigation
    let browser: LibraryBrowser?
    @Environment(\.openWindow) private var openWindow

    /// Biblioteka okna na pierwszym planie (z konta root — tam są foldery), a bez okna pierwsza.
    private var library: AudiobookshelfClient.Library? {
        if let id = browser?.libraryID, let library = account.libraries.first(where: { $0.id == id }) { return library }
        return browser == nil ? nil : account.libraries.first
    }

    private var hasPodcastLibrary: Bool { account.libraries.contains { $0.mediaType == "podcast" } }
    private var ready: Bool { account.state == .ready }

    var body: some View {
        Button("Wgraj książkę…") {
            if let browser, browser.manager.isAvailable, !browser.isPodcastLibrary {
                browser.upload([])
            } else {
                menuBar.openLibrary(.upload([]))
            }
        }
        .keyboardShortcut("n")
        .disabled(!ready)

        Button("Dodaj podcast…") {
            if let browser, browser.isPodcastLibrary {
                browser.searchText = ""
                browser.section = .items
                browser.path = []
                browser.addPodcastRequested = true
            } else {
                menuBar.openLibrary(.addPodcast)
            }
        }
        .keyboardShortcut("n", modifiers: [.shift, .command])
        .disabled(!ready || !hasPodcastLibrary)

        Button("Dodaj bibliotekę…") {
            openWindow.openSettings(.libraries, navigation: settings)
        }

        Divider()

        Button(library.map { "Skanuj „\($0.name)”" } ?? "Skanuj bibliotekę") {
            if let library { libraryTasks.scan(library, force: false) }
        }
        .disabled(!ready || library == nil || library.map { libraryTasks.isRunning($0.id) } == true)

        Button("Pokaż w Finderze") {
            let urls = (library?.folders ?? []).map { URL(fileURLWithPath: $0.fullPath) }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        .keyboardShortcut("r", modifiers: [.option, .command])
        .disabled(library?.folders.isEmpty ?? true)
    }
}

/// Okno: „Biblioteka” obok listy okien; web UI pod Option (wyjście awaryjne, etap 9i).
/// ⌘1 i ⌘2 zajmuje widok kafelki/lista (jak w Finderze), ⌘0 — rzeczywisty rozmiar tekstu.
struct LibraryWindowCommands: Commands {
    let account: ServerAccount
    let webMode: WebUIMode
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button(LibraryWindow.title) {
                openWindow.bringToFront(id: LibraryWindow.windowID)
            }
            .keyboardShortcut("l", modifiers: [.option, .command])
            .modifierKeyAlternate(.option) {
                Button("\(WebUIWindow.title)…") {
                    webMode.isManagement = false
                    openWindow.bringToFront(id: WebUIWindow.windowID)
                }
                .disabled(account.state != .ready)
            }
            Divider()
        }
    }
}

/// Widok: pasek boczny (system), panel odtwarzacza, Wstecz i Dalej.
struct LibraryNavigationCommands: Commands {
    @FocusedValue(\.libraryBrowser) private var browser

    var body: some Commands {
        SidebarCommands()
        CommandGroup(after: .sidebar) {
            NavigationMenuItems(browser: browser)
        }
    }
}

private struct NavigationMenuItems: View {
    let browser: LibraryBrowser?

    var body: some View {
        Button(browser?.showsPlayer == true ? "Schowaj odtwarzacz" : "Pokaż odtwarzacz") {
            browser?.showsPlayer.toggle()
        }
        .keyboardShortcut("i", modifiers: [.option, .command])
        .disabled(browser == nil)
        Divider()
        // ⌘[ i ⌘] to w całym systemie Wstecz i Dalej (Finder, Safari, Muzyka).
        Button("Wstecz") { browser?.goBack() }
            .keyboardShortcut("[")
            .disabled(browser?.canGoBack != true)
        Button("Dalej") { browser?.goForward() }
            .keyboardShortcut("]")
            .disabled(browser?.canGoForward != true)
        Divider()
    }
}

/// Pomoc: dokumentacja i zgłaszanie problemów zamiast pustej pozycji „Rapsod Pomoc”.
struct HelpCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            if let source = HelpLinks.source {
                Link("Pomoc Rapsodu", destination: source.appending(path: "blob/main/README.md"))
                Link("Zgłoś problem…", destination: source.appending(path: "issues/new"))
                Divider()
            }
            Link("Strona Rapsodu", destination: HelpLinks.website)
            Link("Dokumentacja audiobookshelf", destination: HelpLinks.audiobookshelfDocs)
        }
    }
}

enum HelpLinks {
    static let website = URL(string: "https://rapsod.smigi.net")!
    static let audiobookshelfDocs = URL(string: "https://www.audiobookshelf.org/docs")!

    /// Repozytorium ze źródłami (`ABSSourceURL` w Info.plist); puste, dopóki nie jest publiczne.
    static var source: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "ABSSourceURL") as? String, !text.isEmpty else { return nil }
        return URL(string: text)
    }
}
