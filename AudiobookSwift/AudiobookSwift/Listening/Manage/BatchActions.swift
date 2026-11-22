import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Zaznaczanie wielu pozycji w siatce i działania na nich (etap 9h) — to, co web UI ma
/// w pasku zaznaczenia (`Appbar.vue`): odtwarzanie, ukończone, kolekcja i playlista,
/// edycja wsadowa, szybkie dopasowanie, osadzanie metadanych, skan i usuwanie.
/// Zmiany pozycji idą tokenem root (`ItemManager`), playlisty i postęp — kontem słuchacza.
extension View {
    /// Przycisk „Zaznacz” w pasku narzędzi i pasek działań na dole w trybie zaznaczania.
    func batchSelection(browser: LibraryBrowser, scope: String) -> some View {
        modifier(BatchSelection(browser: browser, scope: scope))
    }
}

private struct BatchSelection: ViewModifier {
    let browser: LibraryBrowser
    let scope: String
    @State private var sheet: BatchSheet?
    @State private var confirm: BatchConfirm?
    @State private var busy: String?
    @State private var result: (title: String, message: String)?
    @State private var permanentIDs: [String]?

    private var manager: ItemManager { browser.manager }
    private var listening: ListeningController { browser.listening }
    private var selection: [AudiobookshelfClient.LibraryItem] { browser.selection }
    private var ids: [String] { selection.map(\.id) }
    private var isPodcast: Bool { browser.isPodcastLibrary }
    private var allPlayable: Bool { !selection.isEmpty && selection.allSatisfy { ($0.media.numTracks ?? 0) > 0 } }
    private var allFinished: Bool { !selection.isEmpty && selection.allSatisfy { listening.progress[$0.id]?.isFinished == true } }

    enum BatchSheet: String, Identifiable {
        case edit, quickMatch, collection, playlist
        var id: String { rawValue }
    }

    enum BatchConfirm: String, Identifiable {
        case delete, scan, embed
        var id: String { rawValue }
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem {
                    Toggle(isOn: Bindable(browser).isSelecting) {
                        Label("Zaznacz", systemImage: "checkmark.circle")
                    }
                    .help(browser.isSelecting ? "Zakończ zaznaczanie" : "Zaznacz wiele pozycji")
                    .accessibilityIdentifier("batch.select")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if browser.isSelecting { bar }
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .edit: BatchEditSheet(browser: browser, items: selection) { finish($0) }
                case .quickMatch: BatchQuickMatchSheet(browser: browser, ids: ids) { finish($0) }
                case .collection: BatchCollectionSheet(browser: browser, ids: ids) { finish($0) }
                case .playlist: BatchPlaylistSheet(browser: browser, items: selection) { finish($0) }
                }
            }
            .confirmationDialog(confirmTitle, item: $confirm) { kind in
                switch kind {
                case .delete:
                    Button("Przenieś do Kosza i usuń z biblioteki", role: .destructive) { delete() }
                case .scan:
                    Button("Skanuj ponownie") { scan() }
                case .embed:
                    Button("Osadź metadane") { embed() }
                }
                Button("Anuluj", role: .cancel) {}
            } message: { kind in
                Text(confirmMessage(kind))
            }
            .alert("Kosz jest niedostępny", item: $permanentIDs) { ids in
                Button("Usuń trwale (\(ids.count))", role: .destructive) { deletePermanently(ids) }
                Button("Anuluj", role: .cancel) {}
            } message: { ids in
                Text("Folderów \(ids.count) pozycji nie da się przenieść do Kosza. Usunąć je trwale razem z plikami? Tego nie można cofnąć.")
            }
            .alert(result?.title ?? "", item: $result) { _ in
                Button("OK") {}
            } message: { Text($0.message) }
    }

    // MARK: Pasek

    private var bar: some View {
        HStack(spacing: 10) {
            Text(selection.isEmpty ? "Kliknij okładki, żeby zaznaczyć" : "Zaznaczono: \(selection.count)")
                .monospacedDigit()
                .foregroundStyle(selection.isEmpty ? .secondary : .primary)
            if let busy {
                ProgressView().controlSize(.small)
                Text(busy).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Zaznacz wczytane") { browser.requestSelectAll(scope: scope) }
                .disabled(busy != nil)
                .help("Zaznacz wszystkie pozycje wczytane dotąd w siatce")
            Button("Wyczyść") { browser.clearSelection() }.disabled(selection.isEmpty || busy != nil)
            Divider().frame(height: 18)
            actions.disabled(selection.isEmpty || busy != nil)
            Button("Gotowe") { browser.isSelecting = false }
                .keyboardShortcut(.cancelAction)
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var actions: some View {
        if !isPodcast {
            Button("Odtwarzaj", systemImage: "play.fill") { play() }
                .disabled(!allPlayable)
                .help(allPlayable ? "Odtwarzaj zaznaczone po kolei" : "Niektóre zaznaczone pozycje nie mają plików audio")
            Button(allFinished ? "Nieukończone" : "Ukończone", systemImage: allFinished ? "checkmark.circle.fill" : "checkmark.circle") { markFinished(!allFinished) }
                .help(allFinished ? "Oznacz zaznaczone jako nieukończone" : "Oznacz zaznaczone jako ukończone")
        }
        Menu {
            if !isPodcast {
                Button("Dodaj do playlisty…") { sheet = .playlist }
                if manager.isAvailable { Button("Dodaj do kolekcji…") { sheet = .collection } }
            }
            if manager.isAvailable {
                if !isPodcast {
                    Divider()
                    Button("Edytuj wsadowo…") { sheet = .edit }
                    Button("Szybkie dopasowanie…") { sheet = .quickMatch }
                    Button("Osadź metadane w plikach…") { confirm = .embed }.disabled(!allPlayable)
                }
                Button("Skanuj ponownie…") { confirm = .scan }
            }
            Divider()
            Button("Pobierz jako archiwum ZIP…") { download() }
            if manager.isAvailable {
                Divider()
                Button("Usuń…", role: .destructive) { confirm = .delete }
            }
        } label: {
            Label("Działania", systemImage: "ellipsis.circle")
        }
        .fixedSize()
        .help(manager.isAvailable ? "Działania na zaznaczonych" : manager.unavailableReason)
    }

    // MARK: Działania

    private func play() {
        let entries = selection.map { ListeningController.QueueEntry(itemID: $0.id, episodeID: nil, title: $0.title) }
        Task { await listening.playQueue(entries) }
    }

    private func markFinished(_ finished: Bool) {
        let entries = selection.map { AudiobookshelfClient.BatchProgress(libraryItemId: $0.id, episodeId: nil, isFinished: finished) }
        Task { await listening.setFinished(entries) }
    }

    private var confirmTitle: String {
        switch confirm {
        case .delete: "Usunąć zaznaczone pozycje (\(selection.count))?"
        case .scan: "Skanować ponownie zaznaczone pozycje (\(selection.count))?"
        case .embed: "Osadzić metadane w plikach zaznaczonych książek (\(selection.count))?"
        case nil: ""
        }
    }

    private func confirmMessage(_ kind: BatchConfirm) -> String {
        switch kind {
        case .delete:
            "Foldery pozycji trafią do Kosza macOS, a serwer usunie je z biblioteki razem z postępem słuchania. Odtwarzanie tych pozycji zostanie zatrzymane."
        case .scan:
            "Serwer przeczyta od nowa pliki zaznaczonych pozycji. Pozycje, których plików już nie ma, zostaną oznaczone jako brakujące."
        case .embed:
            "Serwer zapisze tytuł, autora, rozdziały i okładkę w plikach audio, z kopią oryginałów w pamięci podręcznej serwera. Zadania idą w kolejce; odtwarzanie tych książek zostanie zatrzymane."
        }
    }

    private func finish(_ message: (String, String)?) {
        sheet = nil
        if let message { result = message }
    }

    private func run(_ label: String, _ work: @escaping () async throws -> (String, String)?) {
        busy = label
        Task {
            defer { busy = nil }
            do {
                if let message = try await work() { result = message }
            } catch {
                result = ("Nie udało się", ItemManager.message(for: error, action: label.replacingOccurrences(of: "…", with: "")))
            }
        }
    }

    /// Archiwum ZIP z folderami zaznaczonych pozycji (etap 9i; `GET /api/libraries/:id/download`).
    /// Kontem root, gdy jest (słuchacz może nie mieć prawa pobierania), inaczej kontem słuchacza.
    private func download() {
        guard let libraryID = browser.libraryID else { return }
        let ids = ids
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = selection.count == 1 ? "\(selection[0].title).zip" : "Pozycje (\(selection.count)).zip"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        run("Pakowanie i pobieranie…") {
            if manager.isAvailable {
                try await manager.run { try await $0.downloadItems(libraryID: libraryID, ids: ids, to: destination, token: $1) }
            } else {
                try await listening.api { try await $0.downloadItems(libraryID: libraryID, ids: ids, to: destination, token: $1) }
            }
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            return nil
        }
    }

    private func scan() {
        let ids = ids
        run("Zlecanie skanu…") {
            try await manager.run { try await $0.batchScan(ids: ids, token: $1) }
            return ("Skan zlecony", "Serwer skanuje \(ids.count) poz. w tle; zmiany pojawią się na liście same.")
        }
    }

    private func embed() {
        let ids = ids
        run("Zlecanie osadzania…") {
            for id in ids { await listening.release(itemID: id) }
            try await manager.run { try await $0.batchEmbedMetadata(ids: ids, backup: true, token: $1) }
            return ("Osadzanie zlecone", "Serwer osadza metadane w \(ids.count) książkach po kolei. Postęp każdej widać na jej stronie.")
        }
    }

    private func delete() {
        let ids = ids
        run("Usuwanie…") {
            let details = try await manager.run { try await $0.batchItems(ids: ids, token: $1) }
            var removed: Set<String> = []
            var noTrash: [String] = []
            var failures: [String] = []
            for item in details {
                await listening.release(itemID: item.id)
                do {
                    try await manager.delete(itemID: item.id, path: item.path, mode: .trash)
                    removed.insert(item.id)
                    listening.itemDeleted(itemID: item.id, libraryID: item.libraryId)
                } catch is ItemManager.TrashUnavailable {
                    noTrash.append(item.id)
                } catch {
                    failures.append(ItemManager.message(for: error, action: "„\(item.title)”"))
                }
            }
            browser.deselect(removed)
            browser.invalidateFilterData()
            if !noTrash.isEmpty { permanentIDs = noTrash }
            if !failures.isEmpty { return ("Nie wszystko usunięto", failures.joined(separator: "\n")) }
            if browser.selection.isEmpty, noTrash.isEmpty { browser.isSelecting = false }
            return nil
        }
    }

    private func deletePermanently(_ ids: [String]) {
        run("Usuwanie…") {
            var failures: [String] = []
            for id in ids {
                do {
                    try await manager.delete(itemID: id, path: nil, mode: .permanent)
                    browser.deselect([id])
                } catch {
                    failures.append(ItemManager.message(for: error, action: "Usuwanie"))
                }
            }
            browser.invalidateFilterData()
            return failures.isEmpty ? nil : ("Nie wszystko usunięto", failures.joined(separator: "\n"))
        }
    }
}
