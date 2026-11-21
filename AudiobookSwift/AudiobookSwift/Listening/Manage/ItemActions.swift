import AppKit
import SwiftUI

/// Akcje „Więcej” strony książki z etapu 9e, które nie mieszczą się w arkuszu edycji:
/// usunięcie pozycji (Kosz, sama baza albo — gdy Kosza nie ma — trwale) i ponowny skan.
enum ItemAction: Identifiable {
    case delete
    case scan
    /// Etap 9f: kanał RSS pozycji i wysłanie e-booka na czytnik.
    case rssFeed
    case sendEbook
    var id: Self { self }
}

extension View {
    func itemActions(browser: LibraryBrowser, item: AudiobookshelfClient.ItemDetail, action: Binding<ItemAction?>) -> some View {
        modifier(ItemActionsModifier(browser: browser, item: item, action: action))
    }
}

private struct ItemActionsModifier: ViewModifier {
    let browser: LibraryBrowser
    let item: AudiobookshelfClient.ItemDetail
    @Binding var action: ItemAction?
    @State private var confirmPermanent: String?
    @State private var result: (title: String, text: String)?
    @State private var busy: String?
    @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?
    @Environment(\.openWindow) private var openWindow

    private var manager: ItemManager { browser.manager }
    private var listening: ListeningController { browser.listening }
    private var isPlaying: Bool { listening.isLoaded(itemID: item.id) }
    /// Pozycja z jednego pliku: `path` to plik, nie folder.
    private var what: String { item.isFile == true ? "Plik" : "Folder" }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(busy)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .accessibilityIdentifier("item.busy")
                }
            }
            .onChange(of: action) {
                if action == .scan {
                    action = nil
                    scan()
                }
            }
            .sheet(isPresented: Binding(get: { action == .rssFeed }, set: { if !$0, action == .rssFeed { action = nil } })) {
                RSSFeedSheet(manager: manager, item: item)
            }
            .sheet(isPresented: Binding(get: { action == .sendEbook }, set: { if !$0, action == .sendEbook { action = nil } })) {
                SendEbookSheet(manager: manager, item: item) {
                    if let navigation { openWindow.openSettings(.notifications, navigation: navigation) }
                }
            }
            .confirmationDialog("Usunąć „\(item.title)”?", isPresented: Binding(get: { action == .delete }, set: { if !$0, action == .delete { action = nil } })) {
                Button("Usuń i przenieś pliki do Kosza", role: .destructive) { delete(.trash) }
                    .accessibilityIdentifier("delete.trash")
                Button("Usuń tylko z biblioteki") { delete(.databaseOnly) }
                    .accessibilityIdentifier("delete.database")
                Button("Anuluj", role: .cancel) {}
            } message: {
                Text(deleteMessage)
            }
            .alert("Kosz jest niedostępny", isPresented: Binding(get: { confirmPermanent != nil }, set: { if !$0 { confirmPermanent = nil } }), presenting: confirmPermanent) { _ in
                Button("Usuń trwale", role: .destructive) { delete(.permanent) }
                Button("Anuluj", role: .cancel) {}
            } message: { reason in
                Text("\(reason)\n\n\(what) „\(item.path ?? "")” zostanie usunięty z dysku bez możliwości odzyskania. Możesz też anulować i usunąć książkę tylko z biblioteki.")
            }
            .alert(result?.title ?? "", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } }), presenting: result) { _ in
                Button("OK") {}
            } message: { result in
                Text(result.text)
            }
    }

    private var deleteMessage: String {
        var lines: [String] = []
        if let path = item.path {
            lines.append("„Usuń i przenieś pliki do Kosza”: \(what.lowercased()) \(path) trafi do Kosza (da się go odzyskać), a \(item.isPodcast ? "podcast" : "książka") zniknie z biblioteki.")
        }
        lines.append("„Usuń tylko z biblioteki”: pliki zostają na dysku, a następny skan biblioteki doda \(item.isPodcast ? "podcast" : "książkę") z powrotem.")
        lines.append(item.isPodcast
            ? "Postęp słuchania wszystkich odcinków zniknie z serwera — także na telefonie."
            : "Postęp słuchania tej książki zniknie z serwera — także na telefonie.")
        if isPlaying { lines.append("Odtwarzanie zostanie zatrzymane.") }
        return lines.joined(separator: "\n\n")
    }

    private func delete(_ mode: ItemManager.DeleteMode) {
        let item = item
        busy = "Usuwanie…"
        Task {
            defer { busy = nil }
            await listening.release(itemID: item.id)
            do {
                try await manager.delete(itemID: item.id, path: item.path, mode: mode)
            } catch let trash as ItemManager.TrashUnavailable {
                confirmPermanent = trash.reason
                return
            } catch {
                result = ("Nie udało się usunąć", ItemManager.message(for: error, action: "Usuwanie „\(item.title)”"))
                return
            }
            // Strona usuniętej pozycji nie ma już czego pokazać — powrót do listy.
            browser.path.removeAll { $0 == .item(item.id) }
            browser.invalidateFilterData()
            listening.itemDeleted(itemID: item.id, libraryID: item.libraryId)
        }
    }

    private func scan() {
        let id = item.id
        busy = "Skanowanie pozycji…"
        Task {
            defer { busy = nil }
            do {
                let outcome = try await manager.run { try await $0.scanItem(id: id, token: $1) }
                let text: String = switch outcome {
                case .updated: "Zaktualizowano dane z plików na dysku."
                case .upToDate, .nothing: "Bez zmian — pliki na dysku zgadzają się z biblioteką."
                case .removed: "Plików tej pozycji nie ma już na dysku. Serwer oznaczył ją jako brakującą; możesz ją usunąć z biblioteki."
                case .added: "Pozycja została dodana."
                case nil: "Skan zakończony."
                }
                result = ("Ponowny skan", text)
                browser.invalidateFilterData()
            } catch {
                result = ("Nie udało się", ItemManager.message(for: error, action: "Ponowny skan"))
            }
        }
    }
}
