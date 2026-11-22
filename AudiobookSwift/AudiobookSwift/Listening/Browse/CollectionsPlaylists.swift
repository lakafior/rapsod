import Charts
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
        .task(id: libraryID) { await load() }
        // Zmiana nazwy, pozycji albo usunięcie kolekcji (etap 9i) i zdarzenia z serwera.
        .onChange(of: browser.revision) { Task { await load() } }
    }

    private func load() async {
        do {
            collections = try await browser.listening.api { try await $0.collections(libraryID: libraryID, token: $1) }
            error = nil
        } catch {
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
        .alert("Nie udało się", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: { Text(failure ?? "") }
        .task(id: collectionID) { await load() }
        .onChange(of: browser.revision) { Task { await load() } }
    }

    private func load() async {
        guard let libraryID = browser.libraryID else { return }
        let all = try? await browser.listening.api { try await $0.collections(libraryID: libraryID, token: $1) }
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

// MARK: - Playlisty (własne playlisty użytkownika)

struct PlaylistsSection: View {
    let browser: LibraryBrowser
    let libraryID: String
    @State private var selection: String?

    var body: some View {
        Group {
            if let playlists = browser.playlists {
                if playlists.isEmpty {
                    ContentUnavailableView("Brak playlist", systemImage: "music.note.list",
                                           description: Text("Dodaj książkę albo odcinek do playlisty z menu „Więcej” na jego stronie albo z menu podręcznego karty."))
                } else {
                    List(playlists, selection: $selection) { playlist in
                        HStack {
                            Image(systemName: "music.note.list").foregroundStyle(.secondary)
                            Text(playlist.name)
                            Spacer()
                            Text("Pozycje: \(playlist.items.elements.count)").foregroundStyle(.secondary)
                        }
                        .tag(playlist.id)
                    }
                    .onChange(of: selection) {
                        if let id = selection {
                            selection = nil
                            browser.open(.playlist(id))
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Playlisty")
        .task(id: libraryID) { await browser.loadPlaylists() }
    }
}

struct PlaylistPage: View {
    let browser: LibraryBrowser
    let playlistID: String
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    private var playlist: AudiobookshelfClient.Playlist? { browser.playlists?.first { $0.id == playlistID } }

    var body: some View {
        let items = playlist?.items.elements ?? []
        List {
            ForEach(Array(items.enumerated()), id: \.offset) { index, entry in
                row(index: index, entry: entry)
            }
        }
        .overlay {
            if playlist != nil, items.isEmpty { ContentUnavailableView("Pusta playlista", systemImage: "music.note.list") }
        }
        .navigationTitle(playlist?.name ?? "Playlista")
        .toolbar {
            ToolbarItemGroup {
                Button("Odtwarzaj po kolei", systemImage: "play.fill") { play(from: 0) }
                    .disabled(items.isEmpty)
                Menu {
                    Button("Zmień nazwę…") { newName = playlist?.name ?? ""; renaming = true }
                    Button("Usuń playlistę…", role: .destructive) { confirmDelete = true }
                } label: { Label("Playlista", systemImage: "ellipsis.circle") }
            }
        }
        .alert("Nazwa playlisty", isPresented: $renaming) {
            TextField("Nazwa", text: $newName)
            Button("Zapisz") { Task { await browser.renamePlaylist(playlistID, to: newName) } }
            Button("Anuluj", role: .cancel) {}
        }
        .confirmationDialog("Usunąć playlistę „\(playlist?.name ?? "")”?", isPresented: $confirmDelete) {
            Button("Usuń playlistę", role: .destructive) {
                Task {
                    await browser.deletePlaylist(playlistID)
                    if !browser.path.isEmpty { browser.path.removeLast() }
                }
            }
        }
        .task { await browser.loadPlaylists() }
    }

    private func row(index: Int, entry: AudiobookshelfClient.Playlist.Item) -> some View {
        let listening = browser.listening
        let key = ListeningController.key(entry.libraryItemId, entry.episodeId)
        let progress = listening.progress[key]
        return HStack(spacing: 12) {
            AsyncCover(listening: listening, itemID: entry.libraryItemId, path: entry.libraryItem?.media.coverPath, size: 44)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.episode?.title ?? entry.libraryItem?.title ?? "Pozycja").lineLimit(1)
                Text(entry.episode != nil ? entry.libraryItem?.title ?? "" : entry.libraryItem?.author ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if progress?.isFinished == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Ukończone")
            } else if let value = progress?.progress, value > 0 {
                Text(value.formatted(.percent.precision(.fractionLength(0)))).font(.caption).foregroundStyle(.secondary)
            }
            if listening.player.book?.key == key {
                Image(systemName: listening.player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill").foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { play(from: index) }
        .contextMenu {
            Button("Odtwarzaj od tej pozycji") { play(from: index) }
            Button("Otwórz") { browser.open(.item(entry.libraryItemId)) }
            Divider()
            Button("Usuń z playlisty") {
                Task { await browser.removeFromPlaylist(playlistID, .init(libraryItemId: entry.libraryItemId, episodeId: entry.episodeId)) }
            }
        }
    }

    /// Kolejka od wybranej pozycji; ukończone są pomijane.
    private func play(from index: Int) {
        let items = playlist?.items.elements ?? []
        guard index < items.count else { return }
        let entries = items[index...].filter { entry in
            entry.libraryItemId == items[index].libraryItemId && entry.episodeId == items[index].episodeId
                || browser.listening.progress[ListeningController.key(entry.libraryItemId, entry.episodeId)]?.isFinished != true
        }
        .map { ListeningController.QueueEntry(itemID: $0.libraryItemId, episodeID: $0.episodeId, title: $0.episode?.title ?? $0.libraryItem?.title ?? "") }
        Task { await browser.listening.playQueue(entries) }
    }
}

/// „Dodaj do playlisty” w menu pozycji i odcinka: istniejące playlisty biblioteki albo nowa.
struct AddToPlaylistMenu: View {
    let browser: LibraryBrowser
    let entry: AudiobookshelfClient.PlaylistEntry
    let libraryID: String

    var body: some View {
        Menu("Dodaj do playlisty") {
            ForEach(browser.playlists ?? []) { playlist in
                let contains = playlist.items.elements.contains { $0.libraryItemId == entry.libraryItemId && $0.episodeId == entry.episodeId }
                Button(playlist.name) { Task { await browser.addToPlaylist(playlist.id, entry) } }
                    .disabled(contains)
            }
            if !(browser.playlists ?? []).isEmpty { Divider() }
            Button("Nowa playlista…") { browser.newPlaylistEntry = entry }
        }
    }
}

// MARK: - Statystyki słuchania

struct StatsView: View {
    let listening: ListeningController
    @State private var stats: AudiobookshelfClient.ListeningStats?
    @State private var error: String?

    var body: some View {
        Group {
            if let stats {
                ListeningStatsContent(stats: stats, finished: listening.progress.values.filter(\.isFinished).count)
            } else {
                LoadingState(error: error) { await load() }
            }
        }
        .navigationTitle("Statystyki")
        .task { await load() }
    }

    private func load() async {
        do {
            stats = try await listening.api { try await $0.listeningStats(token: $1) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Statystyki słuchania jednego konta: kafelki, ostatnie 30 dni, najdłużej słuchane i ostatnie sesje.
/// Wspólne dla „Twoje słuchanie” i Ustawień → Konta (etap 9i, `pages/config/users/_id/index.vue`).
struct ListeningStatsContent: View {
    let stats: AudiobookshelfClient.ListeningStats
    /// Liczba ukończonych — znana tylko dla własnego konta (postęp słuchacza).
    let finished: Int?

    private struct Day: Identifiable {
        let date: Date
        let minutes: Double
        var id: Date { date }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 16) {
                    StatTile(title: "Łącznie", value: Formats.duration(stats.totalTime))
                    StatTile(title: "Dzisiaj", value: Formats.duration(stats.today ?? 0))
                    StatTile(title: "Dni słuchania", value: "\(stats.days.values.filter { $0 > 0 }.count)")
                    if let finished { StatTile(title: "Ukończone", value: "\(finished)") }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ostatnie 30 dni").font(.title2.weight(.semibold))
                    Chart(lastDays) { day in
                        BarMark(x: .value("Dzień", day.date, unit: .day), y: .value("Minuty", day.minutes))
                    }
                    .chartYAxisLabel("min")
                    .environment(\.locale, Locale(identifier: "pl_PL"))
                    .frame(height: 180)
                }
                let top = stats.items.values.sorted { $0.timeListening > $1.timeListening }.prefix(10)
                if !top.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Najdłużej słuchane").font(.title2.weight(.semibold))
                        ForEach(Array(top)) { item in
                            HStack {
                                Text(item.mediaMetadata?.title ?? "—").lineLimit(1)
                                Text(item.mediaMetadata?.authorName ?? item.mediaMetadata?.author ?? "").foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Text(Formats.duration(item.timeListening)).monospacedDigit()
                            }
                            Divider()
                        }
                    }
                }
                if let sessions = stats.recentSessions?.elements, !sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Ostatnie sesje").font(.title2.weight(.semibold))
                        ForEach(sessions) { session in
                            HStack {
                                Text(session.displayTitle ?? "—").lineLimit(1)
                                Spacer()
                                if let date = Formats.date(ms: session.updatedAt) { Text(date).foregroundStyle(.secondary) }
                                Text(Formats.duration(session.timeListening)).monospacedDigit().frame(width: 110, alignment: .trailing)
                            }
                            Divider()
                        }
                    }
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(24)
        }
    }

    private var lastDays: [Day] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let today = calendar.startOfDay(for: .now)
        return (0..<30).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return Day(date: date, minutes: (stats.days[formatter.string(from: date)] ?? 0) / 60)
        }
    }
}
