import AppKit
import Darwin
import SwiftUI

/// Tryb sprawdzający listę jak w Finderze (etap 14c, tylko testowa kopia): z argumentem
/// `-ABSLibraryTour <folder z książkami>` aplikacja dodaje bibliotekę z folderu (gdy serwer
/// żadnej nie ma), otwiera okno „Biblioteka” i po kolei: siatka i lista książek, przewinięcie
/// obu do końca z pomiarem pamięci, sortowanie nagłówkiem, ⌘A (tryb „Zaznacz”), serie, strona
/// serii, wyszukiwanie, wszystko w jasnym i ciemnym wyglądzie. Zrzuty okna (PNG) trafiają do
/// `-ABSLibraryTourOut <folder>`, postęp na standardowe wyjście (`LTOUR …`, na końcu `LTOUR OK`).
@MainActor
enum LibraryTour {
    static var folder: String? { UserDefaults.standard.string(forKey: "ABSLibraryTour") }
    static var isRequested: Bool { folder != nil }
    /// `-ABSLibraryTourQuick YES`: bez przewijania z pomiarem pamięci.
    private static var quick: Bool { UserDefaults.standard.bool(forKey: "ABSLibraryTourQuick") }
    private static var started = false

    static func runIfRequested(browser: LibraryBrowser, account: ServerAccount) async {
        guard let folder, !started else { return }
        started = true
        let out = URL(filePath: UserDefaults.standard.string(forKey: "ABSLibraryTourOut") ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let listening = browser.listening
        // Kopia testowa ma te same UserDefaults co prawdziwa aplikacja: stan okna („libraryWindow.*”:
        // biblioteka, sortowanie, tryby widoku, kolumny) wraca na koniec do tego sprzed sprawdzenia.
        let defaults = UserDefaults.standard
        let stored = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("libraryWindow.") }
        defer {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("libraryWindow.") { defaults.removeObject(forKey: key) }
            for (key, value) in stored { defaults.set(value, forKey: key) }
        }

        for _ in 0..<240 where account.state != .ready { await pause(0.5) }
        // Czysta kopia testowa: konto słuchacza (losowe hasło w pęku kluczy pod folderem danych).
        for _ in 0..<40 { if case .unknown = account.userState { await pause(0.5) } else { break } }
        if case .missing = account.userState {
            do { try await account.setUpUser(username: "tester", password: "") } catch { log("user error \(error)") }
        }
        log("account libraries=\(account.libraries.count)")
        if account.libraries.isEmpty {
            log("adding library")
            await account.addLibrary(folder: URL(filePath: folder))
            for _ in 0..<1200 where account.isScanning { await pause(0.5) }
            log("scan done libraries=\(account.libraries.count)")
        }
        await listening.refresh()
        for _ in 0..<120 where listening.libraries.isEmpty || listening.availability != .ready { await pause(0.5) }
        browser.ensureLibrary()
        log("libraries=\(listening.libraries.count)")

        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let suffix = dark ? "-dark" : "-light"
            browser.searchText = ""
            browser.path = []
            browser.section = .items
            browser.itemSort = .init(key: "media.metadata.title", descending: false)

            browser.setViewMode(.grid, for: .books)
            await pause(3)
            await snapshot("ksiazki-siatka" + suffix, out)
            browser.setViewMode(.list, for: .books)
            await pause(3)
            await snapshot("ksiazki-lista" + suffix, out)

            if !dark, !quick {
                await scrollTest("list")
                browser.setViewMode(.grid, for: .books)
                await pause(2)
                await scrollTest("grid")
                browser.setViewMode(.list, for: .books)
                await pause(2)
                accessibilityCheck()
            }

            browser.itemSort = .init(key: "media.metadata.authorName", descending: true)
            await pause(3)
            await snapshot("ksiazki-lista-autor-malejaco" + suffix, out)
            browser.itemSort = .init(key: "media.metadata.title", descending: false)
            await pause(2)

            if let table = largestTable() {
                table.selectRowIndexes(IndexSet(integersIn: 0..<min(5, table.numberOfRows)), byExtendingSelection: false)
                await pause(1)
                log("select5 isSelecting=\(browser.isSelecting) selection=\(browser.selection.count)")
                await snapshot("ksiazki-lista-zaznaczanie" + suffix, out)
                browser.isSelecting = false
                await pause(1)
            }

            browser.section = .series
            browser.setViewMode(.list, for: .series)
            await pause(3)
            await snapshot("serie-lista" + suffix, out)
            if let table = largestTable(), table.numberOfRows > 0 {
                table.selectRowIndexes([0], byExtendingSelection: false)
            }
            // Strona pierwszej serii z listy (nazwa z biblioteki testowej).
            let series = try? await listening.api { try await $0.seriesPage(libraryID: browser.libraryID ?? "", page: 0, limit: 1, sort: "name", descending: false, token: $1) }
            if let first = series?.results.elements.first {
                browser.open(.series(id: first.id, name: first.name))
                browser.setViewMode(.list, for: .seriesPage)
                await pause(3)
                await snapshot("seria-lista" + suffix, out)
                browser.path = []
            }

            browser.section = .items
            browser.setViewMode(.list, for: .search)
            browser.searchText = "Cichy"
            await pause(4)
            await snapshot("wyszukiwanie-lista" + suffix, out)
            browser.searchText = ""
            // Strona autora jako lista (pozycje bez stronicowania).
            let authors = try? await listening.api { try await $0.authorsPage(libraryID: browser.libraryID ?? "", page: 0, limit: 1, sort: "name", descending: false, token: $1) }
            if let author = authors?.results.elements.first {
                browser.setViewMode(.list, for: .authorPage)
                browser.open(.author(id: author.id, name: author.name))
                await pause(4)
                await snapshot("autor-lista" + suffix, out)
                browser.path = []
            }
        }
        NSApp.appearance = nil
        log("OK")
    }

    // MARK: Pamięć

    /// Przewija największą tabelę okna (lista albo wiersze siatki) do końca i z powrotem,
    /// wypisując `phys_footprint` procesu.
    private static func scrollTest(_ name: String) async {
        guard let table = largestTable() else { return log("\(name) no table") }
        let rows = table.numberOfRows
        log("\(name) rows=\(rows) start=\(footprint())MB")
        for pass in 0..<2 {
            var row = 0
            while row < rows {
                table.scrollRowToVisible(row)
                await pause(0.03)
                row += 20
            }
            table.scrollRowToVisible(rows - 1)
            await pause(1)
            log("\(name) pass\(pass) bottom=\(footprint())MB")
            table.scrollRowToVisible(0)
            await pause(1)
            log("\(name) pass\(pass) top=\(footprint())MB")
        }
    }

    private static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    // MARK: VoiceOver

    /// Co VoiceOver dostaje z pierwszego wiersza listy (rola i teksty komórek).
    private static func accessibilityCheck() {
        guard let table = largestTable() else { return }
        let rows = (table.value(forKey: "accessibilityRows") as? NSArray) ?? []
        let first = rows.firstObject as? NSObject
        let texts = describe(first, depth: 0).prefix(12).joined(separator: " | ")
        log("ax rows=\(rows.count) header=\(table.headerView != nil) first: \(texts)")
    }

    private static func describe(_ element: NSObject?, depth: Int) -> [String] {
        guard let element = element as? NSAccessibilityElementProtocol & NSObject, depth < 6 else { return [] }
        var result: [String] = []
        let role = (element.value(forKey: "accessibilityRole") as? String) ?? "?"
        let label = (element.value(forKey: "accessibilityLabel") as? String) ?? ""
        let value = (element.value(forKey: "accessibilityValue") as? String) ?? ""
        if !label.isEmpty || !value.isEmpty { result.append("\(role):\(label)\(value.isEmpty ? "" : "=" + value)") }
        for child in (element.value(forKey: "accessibilityChildren") as? NSArray) ?? [] {
            result += describe(child as? NSObject, depth: depth + 1)
        }
        return result
    }

    // MARK: Okno

    private static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains(LibraryWindow.windowID) == true && $0.isVisible }
            ?? NSApp.windows.first { $0.title == LibraryWindow.title && $0.isVisible }
    }

    private static func largestTable() -> NSTableView? {
        func tables(_ view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
        }
        guard let root = window?.contentView else { return nil }
        return tables(root).filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }.max { $0.numberOfRows < $1.numberOfRows }
    }

    /// Zrzut przez `cacheDisplay` (bez paska bocznego — jego materiał rysuje serwer okien) i ogłoszenie
    /// `LTOUR shot <nazwa> <numer okna>` z chwilą postoju: zewnętrzne `screencapture -l` robi wtedy
    /// pełny zrzut okna (np. `scripts`-owa pętla czytająca wyjście).
    private static func snapshot(_ name: String, _ out: URL) async {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return log("snapshot \(name) failed") }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = out.appending(path: name + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        log("snapshot \(name)")
        if let number = window?.windowNumber {
            log("shot \(name) \(number)")
            await pause(1.5)
        }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private static func log(_ text: String) {
        print("LTOUR \(text)")
        fflush(stdout)
    }
}
