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
                    ContentUnavailableView("Brak kolekcji", systemImage: "rectangle.stack", description: Text("Kolekcje tworzy administrator serwera."))
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
        }
        .task(id: collectionID) {
            guard let libraryID = browser.libraryID else { return }
            let all = try? await browser.listening.api { try await $0.collections(libraryID: libraryID, token: $1) }
            collection = all?.first { $0.id == collectionID }
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

    private struct Day: Identifiable {
        let date: Date
        let minutes: Double
        var id: Date { date }
    }

    var body: some View {
        Group {
            if let stats {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(spacing: 16) {
                            tile("Łącznie", Formats.duration(stats.totalTime))
                            tile("Dzisiaj", Formats.duration(stats.today ?? 0))
                            tile("Dni słuchania", "\(stats.days.values.filter { $0 > 0 }.count)")
                            tile("Ukończone", "\(listening.progress.values.filter(\.isFinished).count)")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ostatnie 30 dni").font(.title2.weight(.semibold))
                            Chart(lastDays(stats)) { day in
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
            } else {
                LoadingState(error: error) { await load() }
            }
        }
        .navigationTitle("Statystyki")
        .task { await load() }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }
        .padding(12)
        .frame(minWidth: 150, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func lastDays(_ stats: AudiobookshelfClient.ListeningStats) -> [Day] {
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

    private func load() async {
        do {
            stats = try await listening.api { try await $0.listeningStats(token: $1) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
