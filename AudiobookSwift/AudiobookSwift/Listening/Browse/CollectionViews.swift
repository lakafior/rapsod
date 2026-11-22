import AudiobookshelfKit
import SwiftUI

// MARK: - Kolekcje (wspólne dla wszystkich; słuchacz tylko ogląda)

struct CollectionsSection: View {
    let browser: LibraryBrowser
    let libraryID: String
    @State private var collections: [AudiobookshelfClient.Collection]?
    @State private var error: String?

    var body: some View {
        Group {
            if let collections {
                if collections.isEmpty {
                    ContentUnavailableView("Brak kolekcji", systemImage: "rectangle.stack", description: Text("Kolekcję tworzy się z trybu „Zaznacz” w sekcji Książki (Działania → Dodaj do kolekcji…)."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
                            ForEach(collections) { collection in
                                SeriesCard(browser: browser, series: .init(id: collection.id, name: collection.name, description: nil, books: collection.books)) {
                                    browser.open(.collection(collection.id))
                                }
                            }
                        }
                        .padding(20)
                    }
                }
            } else {
                LoadingState(error: error) { await load() }
            }
        }
        .navigationTitle("Kolekcje")
        // Zmiana nazwy, pozycji albo usunięcie kolekcji (etap 9i) i zdarzenia z serwera.
        .task(id: ReloadKey(id: libraryID, revision: browser.revision)) { await load() }
    }

    private func load() async {
        do {
            collections = try await browser.listening.api { try await $0.collections(libraryID: libraryID, token: $1) }
            error = nil
        } catch {
            if Task.isCancelled { return }
            self.error = error.localizedDescription
        }
    }
}

struct CollectionPage: View {
    let browser: LibraryBrowser
    let collectionID: String
    @State private var collection: AudiobookshelfClient.Collection?
    @State private var feed: FeedTarget?
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let description = HTMLText.plain(collection?.description) { ExpandableText(text: description, lines: 4) }
                LazyVGrid(columns: ItemGrid.columns, alignment: .leading, spacing: 22) {
                    ForEach(collection?.books.elements ?? []) { ItemCard(browser: browser, item: $0) }
                }
            }
            .padding(20)
        }
        .navigationTitle(collection?.name ?? "Kolekcja")
        .toolbar {
            ToolbarItem {
                Button("Odtwarzaj po kolei", systemImage: "play.fill") {
                    let entries = (collection?.books.elements ?? [])
                        .filter { browser.listening.progress[$0.id]?.isFinished != true }
                        .map { ListeningController.QueueEntry(itemID: $0.id, episodeID: nil, title: $0.title) }
                    Task { await browser.listening.playQueue(entries) }
                }
                .disabled(collection?.books.elements.isEmpty ?? true)
            }
            if browser.manager.isAvailable {
                ToolbarItem {
                    Menu {
                        Button("Edytuj kolekcję…") { editing = true }
                        Button("Kanał RSS kolekcji…") {
                            feed = FeedTarget(kind: .collection, id: collectionID, title: collection?.name ?? "Kolekcja")
                        }
                        Divider()
                        Button("Usuń kolekcję…", role: .destructive) { confirmDelete = true }
                    } label: { Label("Kolekcja", systemImage: "ellipsis.circle") }
                    .disabled(collection == nil)
                    .help("Nazwa, opis i pozycje kolekcji, kanał RSS")
                    .accessibilityIdentifier("collection.more")
                }
            }
        }
        .sheet(item: $feed) { RSSFeedSheet(manager: browser.manager, target: $0) }
        .sheet(isPresented: $editing) {
            if let collection {
                CollectionEditSheet(manager: browser.manager, listening: browser.listening, collection: collection) {
                    changed()
                    Task { await load() }
                }
            }
        }
        .confirmationDialog("Usunąć kolekcję „\(collection?.name ?? "")”?", isPresented: $confirmDelete) {
            Button("Usuń kolekcję", role: .destructive) { Task { await delete() } }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Kolekcja zniknie dla wszystkich kont. Książki zostają w bibliotece.")
        }
        .alert("Nie udało się", item: $failure) { _ in
            Button("OK") {}
        } message: { Text($0) }
        .task(id: ReloadKey(id: collectionID, revision: browser.revision)) { await load() }
    }

    private func load() async {
        guard let libraryID = browser.libraryID else { return }
        let all = try? await browser.listening.api { try await $0.collections(libraryID: libraryID, token: $1) }
        // Wczytanie przerwane przez nowsze nie czyści strony.
        if Task.isCancelled { return }
        collection = all?.first { $0.id == collectionID }
    }

    private func changed() {
        if let libraryID = browser.libraryID { browser.listening.libraryChanged(libraryID) }
    }

    private func delete() async {
        do {
            try await browser.manager.run { try await $0.deleteCollection(id: collectionID, token: $1) }
            changed()
            browser.path.removeAll { $0 == .collection(collectionID) }
        } catch {
            failure = ItemManager.message(for: error, action: "Usuwanie kolekcji")
        }
    }
}

/// Edycja kolekcji (etap 9i; wzorzec: `components/modals/collections/EditModal.vue` i lista na
/// `pages/collection/_id.vue`): nazwa, opis i usunięcie wybranych pozycji. Tokenem root.
struct CollectionEditSheet: View {
    let manager: ItemManager
    let listening: ListeningController
    let collection: AudiobookshelfClient.Collection
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var removed: Set<String> = []
    @State private var status = AdminStatus()

    var body: some View {
        Form {
            if status.error != nil || status.isBusy {
                Section { AdminStatusRows(status: status) }
            }
            Section("Kolekcja") {
                TextField("Nazwa", text: $name)
                TextField("Opis", text: $description, axis: .vertical).lineLimit(3...8)
            }
            Section {
                ForEach(collection.books.elements) { book in
                    let isRemoved = removed.contains(book.id)
                    HStack(spacing: 10) {
                        AsyncCover(listening: listening, itemID: book.id, path: book.media.coverPath, size: 36).frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(book.title).lineLimit(1).strikethrough(isRemoved)
                            Text(book.author ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button(isRemoved ? "Przywróć" : "Usuń z kolekcji", systemImage: isRemoved ? "arrow.uturn.backward" : "minus.circle") {
                            if isRemoved { removed.remove(book.id) } else { removed.insert(book.id) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help(isRemoved ? "Zostaw w kolekcji" : "Usuń z kolekcji (książka zostaje w bibliotece)")
                    }
                    .opacity(isRemoved ? 0.5 : 1)
                }
            } header: {
                Text("Pozycje (\(collection.books.elements.count - removed.count))")
            } footer: {
                if !removed.isEmpty {
                    Text("Do usunięcia z kolekcji: \(removed.count). Książki zostają w bibliotece.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Zapisz") { Task { await save() } }
                    .disabled(status.isBusy || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            name = collection.name
            description = collection.description ?? ""
        }
    }

    private func save() async {
        let id = collection.id
        let name = name.trimmingCharacters(in: .whitespaces)
        let description = description
        let removed = Array(removed)
        let changedText = name != collection.name || description != (collection.description ?? "")
        let ok = await status.run("Zapisywanie…", failure: "Nie udało się zapisać kolekcji") {
            if changedText {
                try await manager.run { try await $0.updateCollection(id: id, name: name, description: description, token: $1) }
            }
            if !removed.isEmpty {
                try await manager.run { try await $0.removeFromCollection(id: id, books: removed, token: $1) }
            }
        }
        if ok {
            saved()
            dismiss()
        }
    }
}
