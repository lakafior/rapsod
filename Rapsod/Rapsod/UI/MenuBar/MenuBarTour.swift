#if DEBUG
import AppKit
import AudiobookshelfKit
import SwiftUI

/// Tryb sprawdzający panel na pasku menu (etap 14d, tylko testowa kopia w Debug): z argumentem
/// `-ABSMenuBarTour YES` aplikacja czeka na serwer z biblioteką, słucha chwilę dwóch książek (żeby
/// było „Słuchaj dalej” i „Teraz odtwarzane”), otwiera panel w jasnym i ciemnym wyglądzie, zleca skan
/// (stan zadania w panelu) i pokazuje okno po upuszczeniu folderu `-ABSMenuBarTourDrop <folder>`.
/// Każdy zrzut tryb ogłasza wierszem `MTOUR shot <nazwa> <numer okna>` i czeka 2 s — zrzut robi
/// się z zewnątrz (`screencapture -x -o -l <numer> plik.png`). Na końcu `MTOUR OK`.
@MainActor
enum MenuBarTour {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "ABSMenuBarTour") }
    private static var started = false

    static func run(account: ServerAccount, listening: ListeningController, libraryTasks: LibraryTasks, menuBar: MenuBarModel) async {
        guard isRequested, !started else { return }
        started = true
        // Kopia testowa dzieli `UserDefaults` z prawdziwą aplikacją: okno Biblioteka zapamiętuje
        // wybraną bibliotekę („libraryWindow.*”) — na koniec wraca stan sprzed sprawdzenia.
        let defaults = UserDefaults.standard
        let stored = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("libraryWindow.") }
        defer {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("libraryWindow.") { defaults.removeObject(forKey: key) }
            for (key, value) in stored { defaults.set(value, forKey: key) }
        }
        for _ in 0..<240 where !(account.state == .ready && listening.availability == .ready && !listening.libraries.isEmpty) { await pause(0.5) }
        log("ready libraries=\(listening.libraries.count)")
        guard let library = listening.libraries.first(where: { $0.mediaType != "podcast" }),
              let page = try? await listening.api({ try await $0.itemsPage(libraryID: library.id, page: 0, limit: 10, sort: "media.metadata.title", descending: false, filter: nil, token: $1) })
        else { log("no items"); return }
        let items = page.results.elements
        log("items=\(items.count)")

        // Dwie książki zaczęte, trzecia gra — w panelu „Teraz odtwarzane” i „Słuchaj dalej”.
        for item in items.prefix(3) {
            await listening.play(itemID: item.id, at: 120)
            await pause(3)
        }
        await listening.refreshMe()

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let suffix = appearance == .aqua ? "light" : "dark"
            await openPanel()
            await pause(2.5)
            await shotPanel("panel-\(suffix)")
            closePanel()
            await pause(1)
        }

        // Stan zadania: skan wszystkich bibliotek i panel w trakcie.
        listening.player.pause()
        NSApp.appearance = NSAppearance(named: .aqua)
        await openPanel()
        await pause(1)
        // Mała biblioteka skanuje się w sekundę — skan rusza przy otwartym panelu.
        for library in account.libraries { libraryTasks.scan(library, force: true) }
        await pause(0.1)
        log("scan running=\(libraryTasks.anyRunning)")
        await shotPanel("panel-skan")
        closePanel()
        await pause(1)

        // Wznowienie z „Słuchaj dalej” — ta sama akcja co wiersz panelu.
        if let entry = menuBar.recent.first(where: { $0.itemID != listening.player.book?.itemID }) {
            menuBar.resume(entry)
            for _ in 0..<20 where listening.player.book?.itemID != entry.itemID { await pause(0.25) }
            log("resume \(entry.title) playing=\(listening.player.book?.itemID == entry.itemID)")
            listening.player.pause()
        }

        // Upuszczenie folderu: okno wyboru, Return („Dalej…”) — okno „Biblioteka” z arkuszem wgrywania.
        if let folder = UserDefaults.standard.string(forKey: "ABSMenuBarTourDrop") {
            menuBar.drop([URL(filePath: folder)])
            await pause(2)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == DropWindow.windowID }) {
                await shot("upuszczenie", window)
                if let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                isARepeat: false, keyCode: 36) {
                    window.makeKey()
                    window.sendEvent(enter)
                }
                for _ in 0..<40 where menuBar.browser?.showsUpload != true { await pause(0.25) }
                let entries = menuBar.browser?.upload?.entries.map(\.title) ?? []
                log("upload sheet=\(menuBar.browser?.showsUpload == true) entries=\(entries) dropWindowOpen=\(window.isVisible)")
                await pause(1.5)
                if let library = NSApp.windows.first(where: { $0.identifier?.rawValue == LibraryWindow.windowID }) {
                    await shot("wgrywanie", library)
                }
                menuBar.browser?.showsUpload = false
            }
        }

        // Dodanie folderu w miejscu (ta sama metoda co przycisk „Dodaj” w oknie wyboru).
        if let folder = UserDefaults.standard.string(forKey: "ABSMenuBarTourAddFolder"), let library = account.libraries.first {
            let before = account.libraries.first?.folders.count ?? 0
            let failure = await menuBar.addFolders([URL(filePath: folder)], to: library.id, account: account)
            log("add folder error=\(failure ?? "nil") folders \(before) -> \(account.libraries.first?.folders.count ?? 0)")
        }

        NSApp.appearance = nil
        log("OK")
    }

    /// Klik w ikonę: przycisk paska menu w oknie `NSStatusBarWindow` (widocznym na ekranie).
    private static func openPanel() async {
        guard let window = NSApp.windows.first(where: { $0.className == "NSStatusBarWindow" && $0.screen != nil }),
              window.contentView != nil else { log("no status window"); return }
        // `performClick` przycisku, zdarzenie w kolejce aplikacji ani zdarzenie wysłane do procesu
        // nie otwierają panelu `MenuBarExtra` — tylko prawdziwy klik. Robi go skrypt z zewnątrz
        // (`MTOUR click x y`, współrzędne ekranu od lewego górnego rogu); tu czekamy na panel.
        let frame = window.frame
        let screenHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        log("click \(Int(frame.midX)) \(Int(screenHeight - frame.midY))")
        for _ in 0..<50 where panel == nil { await pause(0.2) }
        if panel == nil { log("panel did not open") }
    }

    private static var panel: NSWindow? {
        WeakWindow.panel.flatMap { $0.isVisible ? $0 : nil }
    }

    private static func shotPanel(_ name: String) async {
        guard let panel else {
            log("no panel; windows: \(NSApp.windows.filter(\.isVisible).map(\.className))")
            return
        }
        await shot(name, panel)
    }

    private static func closePanel() {
        let box = WeakWindow()
        box.window = panel
        box.dismiss()
    }

    private static func shot(_ name: String, _ window: NSWindow) async {
        log("shot \(name) \(window.windowNumber)")
        // Zrzut z zewnątrz — czas na `screencapture`.
        await pause(2)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func log(_ text: String) {
        print("MTOUR \(text)")
        fflush(stdout)
    }
}
#endif
