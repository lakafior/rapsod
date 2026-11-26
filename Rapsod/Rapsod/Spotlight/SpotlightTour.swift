#if DEBUG
import AppKit
import AudiobookshelfKit
import CoreSpotlight
import RapsodIntegration

/// Tryb sprawdzający etap 14f w kopii testowej (argument `-ABSSpotlightTour YES`, tylko Debug).
///
/// Spotlight: osobny zakres `t14f` (indeks jest wspólny z prawdziwą aplikacją — ten sam
/// identyfikator pakietu), usuwany na początku i na końcu, z zapytaniem potwierdzającym zero wpisów.
/// Pełne indeksowanie z czasem i pamięcią, drugi przegląd bez zmian, dodanie i usunięcie pozycji
/// przez serwer (zdarzenia ze stałego gniazda), otwarcie wyniku, wyłączenie przełącznika.
/// Do tego okno Biblioteka: Wstecz/Dalej, wąskie okno (panel odtwarzacza), panel „O programie”.
/// Postęp: `STOUR …`, zrzuty: `STOUR shot <nazwa> <numer okna>` (zrzut robi skrypt z zewnątrz).
/// `-ABSSpotlightTourBook <folder książki>` — folder kopiowany do biblioteki i z niej usuwany.
@MainActor
enum SpotlightTour {
    static let scope = "t14f"

    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "ABSSpotlightTour") }

    static func log(_ text: String) {
        print("STOUR \(text)")
        fflush(stdout)
    }

    static func run(_ app: AppDelegate) async {
        let defaults = UserDefaults.standard
        let keys = ["spotlight.", "libraryWindow.", "settings.lastPage", "updates.lastCheck"]
        let stored = defaults.dictionaryRepresentation().filter { entry in keys.contains { entry.key.hasPrefix($0) } }
        let spotlight = app.spotlight
        spotlight.scopeOverride = scope
        defer {
            for key in defaults.dictionaryRepresentation().keys where keys.contains(where: key.hasPrefix) { defaults.removeObject(forKey: key) }
            for (key, value) in stored { defaults.set(value, forKey: key) }
        }
        let index = CSSearchableIndex(name: "Rapsod")
        try? await index.deleteSearchableItems(withDomainIdentifiers: [SpotlightKey.domain(scope: scope)])
        log("start, wpisów w zakresie: \(await count())")
        // Zimny start: wynik rozpoznany, zanim serwer wstanie (zakres z folderu danych, nie ze środowiska).
        log("zimny start: serwer \(app.supervisor.state), wynik rozpoznany: \(spotlight.target(forIdentifier: "rapsod:\(scope):book:x") != nil)")

        // Konto słuchacza i biblioteki.
        guard await wait(seconds: 120, { app.listening.availability == .ready && !app.listening.libraries.isEmpty && app.account.state == .ready }) else {
            log("FAIL brak konta słuchacza"); return
        }
        spotlight.isEnabled = true

        // 1. Pełne indeksowanie.
        let before = footprint()
        let started = Date.now
        await spotlight.sync()
        let seconds = Date.now.timeIntervalSince(started)
        log("pełne: \(spotlight.indexedCount) pozycji w \(String(format: "%.1f", seconds)) s, pamięć \(before) → \(footprint()) MB, stan \(spotlight.status)")
        let total = await count()
        log("w indeksie (zapytanie): \(total)")
        for title in ["Ciemny Lustro", "Złoty Zegar"] { await probe(title) }

        // 2. Drugi przegląd bez zmian.
        let again = Date.now
        await spotlight.sync()
        log("drugi przegląd: \(String(format: "%.1f", Date.now.timeIntervalSince(again))) s, stan \(spotlight.status)")

        // 3. Dodanie i usunięcie pozycji przez serwer — zmiany przychodzą zdarzeniami.
        if let source = defaults.string(forKey: "ABSSpotlightTourBook"), let library = app.account.libraries.first(where: { $0.mediaType != "podcast" }),
           let folder = library.folders.first {
            let name = "Spotlight Próba \(Int.random(in: 1000...9999))"
            let target = URL(fileURLWithPath: folder.fullPath).appending(path: "Rapsod Test/\(name)")
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: target)
                try coverJPEG().write(to: target.appending(path: "cover.jpg"))
                app.libraryTasks.scan(library, force: false)
                let added = await wait(seconds: 90) { spotlight.indexedCount == total + 1 && !isIndexing(spotlight) }
                log("dodanie: \(added ? "OK" : "FAIL") (\(spotlight.indexedCount))")
                await probe(name)
                // Identyfikator pozycji z wyniku Spotlight (wyszukiwarka serwera nie zna jej od razu).
                let hit = await query("domainIdentifier == \"\(SpotlightKey.domain(scope: scope))*\" && title == \"*\(name)*\"c").first
                if let itemID = hit.flatMap({ SpotlightKey(uniqueIdentifier: $0.uniqueIdentifier) })?.itemID {
                    // Zmiana tytułu przez API — zdarzenie `item_updated`, wpis z nowym tytułem.
                    let renamed = name + " Zmieniona"
                    let update = AudiobookshelfClient.MediaUpdate(metadata: .init(title: renamed))
                    _ = try await app.account.withAdminToken { try await $0.updateMedia(itemID: itemID, update, token: $1) }
                    let changed = await waitAsync(seconds: 60) { await count(title: renamed) == 1 }
                    log("okładki w paczkach: \(app.spotlight.coverStats.withCover) z okładką, pobrane \(app.spotlight.coverStats.fetched)")
                    log("zmiana tytułu: \(changed ? "OK" : "FAIL"), stary tytuł bez „Zmieniona”: \(await query("domainIdentifier == \"\(SpotlightKey.domain(scope: scope))*\" && title == \"\(name)\"").count)")
                    await probe(renamed)
                    try await app.account.withAdminToken { try await $0.deleteItem(id: itemID, hard: true, token: $1) }
                    let removed = await wait(seconds: 60) { spotlight.indexedCount == total && !isIndexing(spotlight) }
                    log("usunięcie: \(removed ? "OK" : "FAIL") (\(spotlight.indexedCount)), zapytanie: \(await count(title: name))")
                } else {
                    log("FAIL nie znaleziono dodanej pozycji na serwerze")
                }
            } catch {
                log("FAIL dodanie/usunięcie: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
        }

        // 4. Otwarcie wyniku — ta sama droga co kliknięcie w Spotlight (NSUserActivity → AppDelegate).
        if let identifier = await firstIdentifier() {
            let activity = NSUserActivity(activityType: CSSearchableItemActionType)
            activity.userInfo = [CSSearchableItemActivityIdentifier: identifier]
            let opened = app.application(NSApp, continue: activity, restorationHandler: { _ in })
            log("otwarcie \(identifier): \(opened)")
            let foreign = NSUserActivity(activityType: CSSearchableItemActionType)
            foreign.userInfo = [CSSearchableItemActivityIdentifier: identifier.replacingOccurrences(of: ":\(scope):", with: ":obca:")]
            log("cudzy zakres odrzucony: \(!app.application(NSApp, continue: foreign, restorationHandler: { _ in }))")
            try? await Task.sleep(for: .seconds(3))
            await shot("wynik-strona")
            await navigationCheck(app)
        }

        await podcastCheck(app)
        await menuCheck(app)

        // 5. Panel „O programie”.
        AboutPanel.show(serverVersion: app.supervisor.environment?.serverVersion)
        try? await Task.sleep(for: .seconds(1))
        if let panel = NSApp.windows.first(where: { $0.isVisible && $0.className.contains("About") || ($0.isVisible && $0 is NSPanel && $0.title.isEmpty) }) {
            log("shot o-programie \(panel.windowNumber)")
            try? await Task.sleep(for: .seconds(2))
            panel.close()
        }

        // Przełącznik w Ustawieniach › Ogólne.
        app.settingsNavigation.page = .general
        app.menuBar.open(.settings(nil))
        try? await Task.sleep(for: .seconds(3))
        if let settings = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(SettingsWindow.windowID) == true && $0.isVisible }) {
            log("zoom ustawień: \(settings.standardWindowButton(.zoomButton)?.isEnabled == true), pełny ekran: \(settings.collectionBehavior.contains(.fullScreenNone) ? "wyłączony" : "dostępny")")
            log("shot ustawienia-spotlight \(settings.windowNumber)")
            try? await Task.sleep(for: .seconds(2))
        }

        // 6. Wyłączenie: cały zakres znika.
        spotlight.isEnabled = false
        try? await Task.sleep(for: .seconds(2))
        log("po wyłączeniu: \(await count()) wpisów, stan \(spotlight.status)")
        try? await index.deleteSearchableItems(withDomainIdentifiers: [SpotlightKey.domain(scope: scope)])
        log("na koniec: \(await count()) wpisów")
        log("OK")
    }

    // MARK: Podcasty

    /// Biblioteka podcastów z folderu (dwa pliki audio jako odcinki), indeks odcinków, potem
    /// usunięcie biblioteki — jej domena znika z indeksu.
    private static func podcastCheck(_ app: AppDelegate) async {
        guard let source = UserDefaults.standard.string(forKey: "ABSSpotlightTourBook"),
              let audio = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: source), includingPropertiesForKeys: nil)
                .first(where: { ["m4a", "mp3"].contains($0.pathExtension) }) else { return }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "rapsod-14f-podcasty")
        let podcast = root.appending(path: "Podcast Próba 14f")
        try? FileManager.default.removeItem(at: root)
        do {
            try FileManager.default.createDirectory(at: podcast, withIntermediateDirectories: true)
            for n in 1...2 { try FileManager.default.copyItem(at: audio, to: podcast.appending(path: "Odcinek \(n).\(audio.pathExtension)")) }
            try coverJPEG().write(to: podcast.appending(path: "cover.jpg"))
        } catch { log("FAIL podcast: \(error.localizedDescription)"); return }
        let before = Set(app.account.libraries.map(\.id))
        await app.account.addLibrary(folder: root, kind: .podcasts)
        guard await wait(seconds: 60, { app.account.libraries.contains { !before.contains($0.id) } }),
              let library = app.account.libraries.first(where: { !before.contains($0.id) }) else { log("FAIL biblioteka podcastów"); return }
        let domain = SpotlightKey.domain(scope: scope, libraryID: library.id)
        let indexed = await waitAsync(seconds: 120) { await query("domainIdentifier == \"\(domain)\"").count >= 3 }
        let items = await query("domainIdentifier == \"\(domain)\"", attributes: ["title", "album", "thumbnailData"])
        log("okładki w paczkach: \(app.spotlight.coverStats.withCover) z okładką, pobrane \(app.spotlight.coverStats.fetched)")
        log("podcasty: \(indexed ? "OK" : "FAIL") — \(items.map { "\($0.uniqueIdentifier.split(separator: ":")[2]) \($0.attributeSet.title ?? "-") (\($0.attributeSet.album ?? "-"), okładka \($0.attributeSet.thumbnailData?.count ?? 0) B)" }.joined(separator: "; "))")
        if let episode = items.first(where: { $0.uniqueIdentifier.contains(":episode:") }) {
            log("otwarcie odcinka: \(app.openSpotlightResult(episode.uniqueIdentifier))")
            try? await Task.sleep(for: .seconds(3))
            await shot("wynik-odcinek")
        }
        do {
            try await app.account.removeLibrary(library)
            let removed = await waitAsync(seconds: 60) { await query("domainIdentifier == \"\(domain)\"").count == 0 }
            log("usunięcie biblioteki: \(removed ? "OK" : "FAIL")")
        } catch { log("FAIL usunięcie biblioteki: \(error.localizedDescription)") }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Menu

    /// Pozycje menu zależne od okna na pierwszym planie (`@FocusedValue`): Wstecz, Dalej, odtwarzacz.
    private static func menuCheck(_ app: AppDelegate) async {
        guard let window = libraryWindow, let browser = app.menuBar.browser else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(1))
        func item(_ title: String) -> (NSMenu, Int)? {
            for top in NSApp.mainMenu?.items ?? [] {
                guard let menu = top.submenu else { continue }
                menu.update()
                if let index = menu.items.firstIndex(where: { $0.title == title }) { return (menu, index) }
            }
            return nil
        }
        func press(_ title: String) async -> String {
            guard let (menu, index) = item(title) else { return "brak" }
            let enabled = menu.items[index].isEnabled
            menu.performActionForItem(at: index)
            try? await Task.sleep(for: .milliseconds(800))
            return enabled ? "włączona" : "wyłączona"
        }
        let start = browser.path.count
        log("menu Wstecz: \(await press("Wstecz")) → ścieżka \(start) → \(browser.path.count)")
        log("menu Dalej: \(await press("Dalej")) → ścieżka \(browser.path.count)")
        let shows = browser.showsPlayer
        let label = shows ? "Schowaj odtwarzacz" : "Pokaż odtwarzacz"
        log("menu \(label): \(await press(label)) → odtwarzacz \(shows) → \(browser.showsPlayer)")
        browser.showsPlayer = shows
        let windowMenu = NSApp.mainMenu?.items.first { $0.submenu?.items.contains { $0.title == "Zamknij wszystkie okna" } == true }?.submenu
        log("menu Okno: \(windowMenu?.items.map { $0.title }.filter { !$0.isEmpty }.joined(separator: ", ") ?? "-")")
        log("menu Plik: \(NSApp.mainMenu?.items.first { $0.submenu?.items.contains { $0.title == "Wgraj książkę…" } == true }?.submenu?.items.map { "\($0.title)\($0.isEnabled ? "" : " (wył.)")" }.filter { $0.count > 6 }.joined(separator: ", ") ?? "-")")
    }

    // MARK: Okno Biblioteka

    private static func navigationCheck(_ app: AppDelegate) async {
        guard let browser = app.menuBar.browser else { log("FAIL brak okna Biblioteka"); return }
        log("ścieżka: \(browser.path.count), wstecz \(browser.canGoBack), dalej \(browser.canGoForward)")
        browser.goBack()
        try? await Task.sleep(for: .seconds(1))
        log("po Wstecz: ścieżka \(browser.path.count), dalej \(browser.canGoForward)")
        browser.goForward()
        try? await Task.sleep(for: .seconds(1))
        log("po Dalej: ścieżka \(browser.path.count), dalej \(browser.canGoForward)")
        guard let window = libraryWindow else { return }
        log("elementy paska: \(backButtons(window))")
        browser.showsPlayer = true
        try? await Task.sleep(for: .seconds(1))
        let frame = window.frame
        window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: 735, height: frame.height), display: true)
        try? await Task.sleep(for: .seconds(2))
        log("okno 735 pt: szerokość \(Int(window.frame.width)), odtwarzacz \(browser.showsPlayer)")
        await shot("okno-735")
        window.setFrame(frame, display: true)
        try? await Task.sleep(for: .seconds(2))
        log("okno \(Int(window.frame.width)) pt: odtwarzacz \(browser.showsPlayer)")
    }

    private static var libraryWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains(LibraryWindow.windowID) == true && $0.isVisible }
    }

    /// Przyciski „wstecz” w pasku narzędzi (czy system nie dodaje drugiego obok naszego).
    private static func backButtons(_ window: NSWindow) -> String {
        window.toolbar?.items.map { $0.itemIdentifier.rawValue }.joined(separator: ", ") ?? "-"
    }

    private static func shot(_ name: String) async {
        guard let window = libraryWindow else { return }
        log("shot \(name) \(window.windowNumber)")
        try? await Task.sleep(for: .seconds(2))
    }

    // MARK: Zapytania do indeksu

    private static func isIndexing(_ spotlight: SpotlightIndexer) -> Bool {
        if case .indexing = spotlight.status { return true }
        return false
    }

    private static func query(_ text: String, attributes: [String] = ["title"]) async -> [CSSearchableItem] {
        let context = CSSearchQueryContext()
        context.fetchAttributes = attributes
        let query = CSSearchQuery(queryString: text, queryContext: context)
        var found: [CSSearchableItem] = []
        do {
            for try await result in query.results { found.append(result.item) }
        } catch {
            log("zapytanie \(text): \(error.localizedDescription)")
        }
        return found.filter { SpotlightKey(uniqueIdentifier: $0.uniqueIdentifier)?.scope == scope }
    }

    private static func count(title: String? = nil) async -> Int {
        // Zapytanie po zakresie w identyfikatorze nie istnieje — po domenie tak.
        let domain = SpotlightKey.domain(scope: scope)
        var text = "domainIdentifier == \"\(domain)*\""
        if let title { text += " && title == \"*\(title)*\"c" }
        return await query(text).count
    }

    private static func firstIdentifier() async -> String? {
        await query("domainIdentifier == \"\(SpotlightKey.domain(scope: scope))*\" && title == \"*Ciemny Lustro*\"c").first?.uniqueIdentifier
    }

    /// Co Spotlight ma o pozycji: tytuł, autorzy, lektorzy, seria, opis, okładka.
    private static func probe(_ title: String) async {
        let items = await query("domainIdentifier == \"\(SpotlightKey.domain(scope: scope))*\" && title == \"*\(title)*\"c",
                                attributes: ["title", "authorNames", "performers", "album", "contentDescription", "thumbnailData", "keywords"])
        guard let item = items.first else { log("szukaj „\(title)”: brak"); return }
        let a = item.attributeSet
        log("szukaj „\(title)”: \(items.count) · \(item.uniqueIdentifier) · \(a.title ?? "-") · autorzy \(a.authorNames ?? []) · lektorzy \(a.performers ?? []) · seria \(a.album ?? "-") · okładka \(a.thumbnailData?.count ?? 0) B · opis \(a.contentDescription?.prefix(60) ?? "-")")
    }

    private static func waitAsync(seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return await condition()
    }

    /// Okładka próbna (gradient z napisem), żeby sprawdzić miniatury w indeksie.
    private static func coverJPEG() throws -> Data {
        let image = NSImage(size: NSSize(width: 400, height: 400), flipped: false) { rect in
            NSGradient(colors: [.systemOrange, .systemPurple])?.draw(in: rect, angle: 45)
            ("14f" as NSString).draw(at: NSPoint(x: 120, y: 160), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 80), .foregroundColor: NSColor.white])
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    private static func wait(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return condition()
    }

    private static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}
#endif
