#if DEBUG
import AppKit
import AudiobookshelfKit
import SwiftUI

/// Zrzuty do README na wymyślonej bibliotece (tylko Debug, kopia testowa z `-ABSDataRoot`).
///
/// `-ABSDemoTour <folder>` — folder z `Audiobooki/` i `Podcasty/` z `scripts/demo/make-library.py`.
/// Tryb zakłada konto „Ola” i dwie biblioteki, ustawia postęp słuchania, dodaje dwie osoby
/// z awatarami, gra jedną książkę w połowie rozdziału (nagrania są ciche) i po kolei pokazuje:
/// Start z panelem odtwarzacza, siatkę książek, stronę książki, panel z paska menu (ten sam widok
/// `MenuBarPanel` w zwykłym oknie — prawdziwy panel otwiera tylko kliknięcie) i Ustawienia ›
/// Użytkownicy, każde w jasnym i ciemnym wyglądzie. Zrzut ogłasza wiersz
/// `DEMO shot <nazwa> <numer okna>`, a robi go `scripts/demo/capture-mac.sh` z zewnątrz
/// (`screencapture -l`). `-ABSDemoTourPairing <plik>` — tryb zapisuje tam adres `rapsod://pair…`
/// dla symulatora (serwer „Mac mini”, adres `http://localhost:<port>`). Na końcu `DEMO OK`;
/// aplikacja działa dalej (serwer dla symulatora), a stan okien w `UserDefaults` wraca do
/// tego sprzed trybu.
@MainActor
enum DemoTour {
    static var folder: String? { UserDefaults.standard.string(forKey: "ABSDemoTour") }
    static var isRequested: Bool { folder != nil }

    /// Okno Biblioteka w punktach (zrzut 2×, potem skalowany do 1600 px).
    static let librarySize = NSSize(width: 1280, height: 800)

    static func run(_ app: AppDelegate) async {
        guard let folder else { return }
        let root = URL(filePath: folder, directoryHint: .isDirectory)
        let defaults = UserDefaults.standard
        let prefixes = ["libraryWindow.", "settings.lastPage", "NSWindow Frame", "NSSplitView Subview Frames", "updates.lastCheck", BookTextSettings.panelKey]
        let stored = defaults.dictionaryRepresentation().filter { entry in prefixes.contains { entry.key.hasPrefix($0) } }
        defer {
            for key in defaults.dictionaryRepresentation().keys where prefixes.contains(where: key.hasPrefix) { defaults.removeObject(forKey: key) }
            for (key, value) in stored { defaults.set(value, forKey: key) }
        }
        let account = app.account, listening = app.listening
        // Panel odtwarzacza z dużą okładką, nie w trybie „Tekst” (książki demo nie mają e-booków).
        defaults.set(false, forKey: BookTextSettings.panelKey)

        guard await wait(240, { account.state == .ready }) else { log("FAIL serwer"); return }
        closeWindow(WelcomeWindow.windowID)
        _ = await wait(20) { if case .unknown = account.userState { false } else { true } }
        // `.invalid`: w pęku kluczy zostało konto z poprzedniego przebiegu w tym samym folderze danych.
        if case .ready = account.userState {} else {
            do { try await account.setUpUser(username: "Ola", password: "") } catch { log("FAIL konto \(error)") }
        }
        if account.libraries.isEmpty {
            await account.addLibrary(folder: root.appending(path: "Audiobooki"))
            await account.addLibrary(folder: root.appending(path: "Podcasty"), kind: .podcasts)
            log("biblioteki: \(account.libraries.map(\.name))")
        }
        closeWindow(WelcomeWindow.windowID)
        await listening.refresh()
        guard await wait(120, { listening.availability == .ready && listening.libraries.count >= 2 }),
              let books = listening.libraries.first(where: { $0.mediaType != "podcast" }) else { log("FAIL słuchanie"); return }

        // Pozycje po tytułach.
        guard let page = try? await listening.api({
            try await $0.itemsPage(libraryID: books.id, page: 0, limit: 100, sort: "media.metadata.title", descending: false, filter: nil, token: $1)
        }) else { log("FAIL lista"); return }
        let items = Dictionary(page.results.elements.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        log("pozycje: \(items.count)")

        // Postęp: najpierw ukończone, potem zaczęte (kolejność = „Słuchaj dalej”, najnowsze na końcu).
        let finished = ["Latarnik z Szarej Zatoki", "Krótka historia herbaty", "Smok z ulicy Kwiatowej", "Pięć minut ciszy"]
        let started: [(String, Double)] = [("Czwarty pokój", 0.09), ("Rok w Bieszczadach", 0.47), ("Ogród pani Leokadii", 0.18),
                                           ("Zegarmistrz z Kazimierza", 0.81), ("Dryf", 0.35), ("Cisza nad Wartą", 0.62)]
        for title in finished {
            guard let item = items[title], let duration = item.media.duration else { continue }
            try? await listening.api { try await $0.updateProgress(itemID: item.id, episodeID: nil, currentTime: duration, duration: duration, isFinished: true, token: $1) }
        }
        for (title, fraction) in started {
            guard let item = items[title], let duration = item.media.duration else { continue }
            try? await listening.api { try await $0.updateProgress(itemID: item.id, episodeID: nil, currentTime: duration * fraction, duration: duration, token: $1) }
            try? await Task.sleep(for: .milliseconds(300))
        }

        await setUpPeople(app)

        // Gra „Sól i popiół”: rozdział 5, kilkanaście minut w środku (cisza).
        let playing = items["Sól i popiół"]
        if let playing {
            await listening.play(itemID: playing.id, at: 5 * 41 * 60 + 17 * 60 + 23)
            _ = await wait(20) { listening.player.isPlaying && listening.player.currentChapter != nil }
            // Środek bieżącego rozdziału.
            if let chapter = listening.player.currentChapter {
                listening.player.seek(to: chapter.start + chapter.duration * 0.42)
            }
        }
        await listening.refreshMe()

        // Okno Biblioteka.
        app.menuBar.open(.library)
        guard await wait(20, { app.menuBar.browser != nil && window(LibraryWindow.windowID) != nil }),
              let browser = app.menuBar.browser, let library = window(LibraryWindow.windowID) else { log("FAIL okno"); return }
        closeWindow(WelcomeWindow.windowID)
        center(library, size: librarySize)
        browser.showsPlayer = true
        browser.libraryID = books.id
        browser.section = .home
        await pause(4)
        // Półki Startu jeszcze raz, już z postępem grającej książki.
        browser.section = .items
        await pause(2)
        browser.section = .home
        await pause(4)

        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            browser.path = []
            browser.section = .home
            await pause(4)
            await shot("mac-home-\(suffix)", library, dark: dark)

            browser.section = .items
            browser.setViewMode(.grid, for: .books)
            browser.itemSort = .init(key: "media.metadata.title", descending: false)
            await pause(4)
            await shot("mac-grid-\(suffix)", library, dark: dark)

            if let book = items["Zegarmistrz z Kazimierza"] ?? playing {
                browser.path = [.item(book.id)]
                await pause(4)
                await shot("mac-book-\(suffix)", library, dark: dark)
            }
        }
        browser.path = []
        browser.section = .home

        // Panel z paska menu w zwykłym oknie.
        app.menuBar.panelOpened()
        await pause(3)
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let panel = makePanel(app, dark: dark)
            panel.orderFrontRegardless()
            await pause(3)
            await shot("mac-menubar-\(dark ? "dark" : "light")", panel, dark: dark)
            panel.orderOut(nil)
        }

        // Ustawienia › Użytkownicy.
        app.settingsNavigation.page = .users
        app.menuBar.open(.settings(nil))
        if await wait(20, { window(SettingsWindow.windowID) != nil }), let settings = window(SettingsWindow.windowID) {
            center(settings, size: NSSize(width: 900, height: 600))
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                // Lista osób wczytana od nowa (pierwsze wczytanie bywa przerwane otwarciem okna).
                app.settingsNavigation.page = .general
                await pause(2)
                app.settingsNavigation.page = .users
                await pause(5)
                await shot("mac-settings-\(dark ? "dark" : "light")", settings, dark: dark)
            }
            settings.close()
        }

        NSApp.appearance = nil
        listening.player.pause()
        await pause(2)
        log("OK")
    }

    // MARK: Osoby i telefon

    private static func setUpPeople(_ app: AppDelegate) async {
        let account = app.account
        do {
            var users = try await account.withAdminToken { try await $0.users(token: $1) }
            for name in ["Tomek", "Babcia Halina"] where !users.contains(where: { $0.username == name }) {
                _ = try await account.withAdminToken {
                    try await $0.createUser(.init(username: name, password: UUID().uuidString), token: $1)
                }
            }
            users = try await account.withAdminToken { try await $0.users(token: $1) }
            let symbols = ["Ola": ("🦊", 3), "Tomek": ("🚲", 6), "Babcia Halina": ("🌻", 1)]
            for user in users {
                if let (symbol, color) = symbols[user.username] { try? app.avatars.setSymbol(symbol, color: color, for: user.id) }
            }
            guard let ola = users.first(where: { $0.username == "Ola" }) else { return }
            let created = try await account.withAdminToken {
                try await $0.createApiKey(name: PhonePairing.keyPrefix + "iPhone Oli", userID: ola.id, expiresIn: nil, isActive: true, token: $1)
            }
            if let path = UserDefaults.standard.string(forKey: "ABSDemoTourPairing") {
                let payload = PairingPayload(
                    server: .init(id: "demo-mac-mini", name: "Mac mini"),
                    addresses: [.init(url: URL(string: "http://localhost:\(ServerEnvironment.port)")!, kind: .local)],
                    account: .init(id: ola.id, username: ola.username),
                    device: .init(keyID: created.key.id, name: "iPhone Oli"),
                    key: created.secret
                )
                try payload.url().absoluteString.write(toFile: path, atomically: true, encoding: .utf8)
            }
            await app.pairing.refresh()
            log("osoby: \(users.map(\.username))")
        } catch {
            log("FAIL osoby \(error)")
        }
    }

    // MARK: Panel

    private static func makePanel(_ app: AppDelegate, dark: Bool) -> NSPanel {
        let view = MenuBarPanel(supervisor: app.supervisor, account: app.account, loginItem: app.loginItem, webMode: app.webMode,
                                settings: app.settingsNavigation, listening: app.listening, updates: app.updates,
                                libraryTasks: app.libraryTasks, menuBar: app.menuBar)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        panel.contentView = effect
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - size.width - 80, y: screen.maxY - 10))
        }
        return panel
    }

    // MARK: Pomocnicze

    /// Tło pod oknem (przezroczyste materiały pokazują je zamiast tego, co akurat jest na ekranie).
    private static var backdrop: NSWindow?

    private static func shot(_ name: String, _ window: NSWindow, dark: Bool) async {
        let frame = window.frame.insetBy(dx: -60, dy: -60)
        let back = backdrop ?? NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop = back
        back.isReleasedWhenClosed = false
        back.setFrame(frame, display: true)
        back.backgroundColor = dark ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.16, alpha: 1) : NSColor(srgbRed: 0.86, green: 0.88, blue: 0.92, alpha: 1)
        back.order(.below, relativeTo: window.windowNumber)
        // Aktywne okno (kolorowe przyciski, akcent w pasku bocznym), jak po otwarciu z menu.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        back.order(.below, relativeTo: window.windowNumber)
        await pause(1)
        log("shot \(name) \(window.windowNumber)")
        await pause(3)
        back.orderOut(nil)
    }

    private static func window(_ id: String) -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains(id) == true && $0.isVisible }
    }

    private static func closeWindow(_ id: String) {
        window(id)?.close()
    }

    private static func center(_ window: NSWindow, size: NSSize) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        window.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: true)
    }

    private static func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return condition()
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    static func log(_ text: String) {
        print("DEMO \(text)")
        fflush(stdout)
    }
}
#endif
