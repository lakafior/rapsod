import AudiobookshelfKit
import SwiftUI

// MARK: - Lektorzy

struct NarratorsSection: View {
    let browser: LibraryBrowser
    let libraryID: String
    @State private var narrators: [AudiobookshelfClient.Narrator]?
    @State private var error: String?
    @State private var renaming: AudiobookshelfClient.Narrator?
    @State private var newName = ""
    @State private var deleting: AudiobookshelfClient.Narrator?
    @State private var failure: String?
    /// Zaznaczony wiersz: strzałki przesuwają zaznaczenie, Return (albo dwuklik) otwiera.
    @State private var selection: Set<String> = []

    var body: some View {
        Group {
            if let narrators {
                if narrators.isEmpty {
                    ContentUnavailableView("Brak lektorów", systemImage: "waveform")
                } else {
                    // Wiersz to przycisk: kliknięcie otwiera listę książek lektora, jak link w web UI.
                    // Z klawiatury: strzałki zaznaczają wiersz, Return go otwiera.
                    List(narrators, selection: $selection) { narrator in
                        Button { browser.open(.filtered(.narrator(narrator.name))) } label: {
                            HStack {
                                Text(narrator.name)
                                Spacer()
                                Text("Książki: \(narrator.numBooks ?? 0)").foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .contextMenu(forSelectionType: String.self) { ids in
                        if let narrator = narrators.first(where: { ids.contains($0.id) }) {
                            NarratorManageMenu(browser: browser, libraryID: libraryID, narrator: narrator, renaming: $renaming, deleting: $deleting)
                        }
                    } primaryAction: { ids in
                        if let narrator = narrators.first(where: { ids.contains($0.id) }) {
                            browser.open(.filtered(.narrator(narrator.name)))
                        }
                    }
                }
            } else {
                LoadingState(error: error) { await load() }
            }
        }
        .navigationTitle("Lektorzy")
        .task(id: ReloadKey(id: libraryID, revision: browser.revision)) { await load() }
        .onChange(of: renaming) { if let renaming { newName = renaming.name } }
        .alert("Nowa nazwa lektora", item: $renaming) { narrator in
            TextField("Nazwa", text: $newName)
            Button("Zmień") { Task { await rename(narrator) } }
            Button("Anuluj", role: .cancel) {}
        } message: { narrator in
            Text("„\(narrator.name)” zmieni się we wszystkich książkach tej biblioteki. Istniejąca nazwa połączy obu lektorów.")
        }
        .confirmationDialog("Usunąć lektora „\(deleting?.name ?? "")”?", item: $deleting) { narrator in
            Button("Usuń ze wszystkich książek", role: .destructive) { Task { await remove(narrator) } }
            Button("Anuluj", role: .cancel) {}
        } message: { narrator in
            Text("Lektor zniknie z \(narrator.numBooks ?? 0) książek tej biblioteki. Książki zostają.")
        }
        .alert("Nie udało się", item: $failure) { _ in
            Button("OK") {}
        } message: { Text($0) }
    }

    private func rename(_ narrator: AudiobookshelfClient.Narrator) async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != narrator.name else { return }
        do {
            _ = try await browser.manager.run { try await $0.renameNarrator(libraryID: libraryID, narratorID: narrator.id, to: name, token: $1) }
            browser.invalidateFilterData()
            await load()
        } catch {
            failure = ItemManager.message(for: error, action: "Zmiana nazwy lektora")
        }
    }

    private func remove(_ narrator: AudiobookshelfClient.Narrator) async {
        do {
            _ = try await browser.manager.run { try await $0.removeNarrator(libraryID: libraryID, narratorID: narrator.id, token: $1) }
            browser.invalidateFilterData()
            await load()
        } catch {
            failure = ItemManager.message(for: error, action: "Usuwanie lektora")
        }
    }

    private func load() async {
        do {
            narrators = try await browser.listening.api { try await $0.narrators(libraryID: libraryID, token: $1) }
        } catch {
            if Task.isCancelled { return }
            self.error = error.localizedDescription
        }
    }
}
