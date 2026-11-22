import SwiftUI

// MARK: - Playlisty (własne playlisty użytkownika)

struct PlaylistsSection: View {
    let browser: LibraryBrowser
    let libraryID: String

    var body: some View {
        Group {
            if let playlists = browser.playlists {
                if playlists.isEmpty {
                    ContentUnavailableView("Brak playlist", systemImage: "music.note.list",
                                           description: Text("Dodaj książkę albo odcinek do playlisty z menu „Więcej” na jego stronie albo z menu podręcznego karty."))
                } else {
                    // Wiersz to przycisk: kliknięcie otwiera playlistę, jak dotąd, a z klawiatury
                    // (pełny dostęp z klawiatury) i VoiceOver działa jak każdy przycisk.
                    List(playlists) { playlist in
                        Button { browser.open(.playlist(playlist.id)) } label: {
                            HStack {
                                Image(systemName: "music.note.list").foregroundStyle(.secondary)
                                Text(playlist.name)
                                Spacer()
                                Text("Pozycje: \(playlist.items.elements.count)").foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
    @State private var selection: String?

    private var playlist: AudiobookshelfClient.Playlist? { browser.playlists?.first { $0.id == playlistID } }

    var body: some View {
        let items = playlist?.items.elements ?? []
        // Identyfikator wpisu: pozycja + odcinek (serwer nie przyjmuje dwa razy tego samego),
        // więc wiersz nie myli się po usunięciu wpisu wyżej. Dwuklik i Return odtwarzają od wiersza.
        List(selection: $selection) {
            ForEach(items, id: \.entryKey) { entry in
                row(entry).tag(entry.entryKey)
            }
        }
        .contextMenu(forSelectionType: String.self) { keys in
            if let key = keys.first, let index = items.firstIndex(where: { $0.entryKey == key }) {
                let entry = items[index]
                Button("Odtwarzaj od tej pozycji") { play(from: index) }
                Button("Otwórz") { browser.open(.item(entry.libraryItemId)) }
                Divider()
                Button("Usuń z playlisty") {
                    Task { await browser.removeFromPlaylist(playlistID, .init(libraryItemId: entry.libraryItemId, episodeId: entry.episodeId)) }
                }
            }
        } primaryAction: { keys in
            if let key = keys.first, let index = items.firstIndex(where: { $0.entryKey == key }) { play(from: index) }
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

    private func row(_ entry: AudiobookshelfClient.Playlist.Item) -> some View {
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
        .accessibilityElement(children: .combine)
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

private extension AudiobookshelfClient.Playlist.Item {
    /// Jak `ListeningController.key`: `itemID` albo `itemID/episodeID`.
    var entryKey: String { episodeId.map { "\(libraryItemId)/\($0)" } ?? libraryItemId }
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
