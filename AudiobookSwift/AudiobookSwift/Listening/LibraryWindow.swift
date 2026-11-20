import SwiftUI

/// Natywne okno „Biblioteka”: „Słuchaj dalej”, lista książek wybranej biblioteki i odtwarzacz.
///
/// Treść istnieje tylko przy otwartym oknie (`ReleasedWhenClosed`); odtwarzacz żyje
/// w `ListeningController`, więc słuchanie trwa po zamknięciu okna.
struct LibraryWindow: View {
    static let windowID = "library"
    static let title = "Biblioteka"

    let listening: ListeningController
    let supervisor: ServerSupervisor
    let account: ServerAccount
    let settings: SettingsNavigation

    enum Selection: Hashable {
        case continueListening
        case library(String)
    }

    @State private var selection: Selection? = .continueListening
    @State private var showsPlayer = true
    @Environment(\.openWindow) private var openWindow

    private var needsUser: Bool {
        guard supervisor.state == .running, account.state == .ready else { return false }
        switch account.userState {
        case .missing, .invalid: return true
        case .unknown, .ready: return false
        }
    }

    var body: some View {
        Group {
            if needsUser {
                UserAccountSetup(account: account)
            } else if listening.availability == .ready {
                content
            } else {
                unavailable
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .navigationTitle(Self.title)
        .onDisappear { listening.windowClosed() }
    }

    private var content: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Słuchaj dalej", systemImage: "play.circle").tag(Selection.continueListening)
                Section("Biblioteki") {
                    ForEach(listening.libraries) { library in
                        Label(library.name, systemImage: library.mediaType == "podcast" ? "mic" : "books.vertical")
                            .tag(Selection.library(library.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            NavigationStack {
                switch selection {
                case .library(let id):
                    if let library = listening.libraries.first(where: { $0.id == id }) {
                        ItemList(listening: listening, items: listening.itemsByLibrary[id], title: library.name)
                            .task(id: id) { await listening.loadItems(libraryID: id) }
                    }
                case .continueListening, nil:
                    ItemList(listening: listening, items: listening.continueListening, title: "Słuchaj dalej", isContinue: true)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MiniPlayerBar(listening: listening, showsPlayer: $showsPlayer)
            }
        }
        .inspector(isPresented: $showsPlayer) {
            PlayerPanel(listening: listening)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
        }
        .toolbar {
            ToolbarItem {
                Button(showsPlayer ? "Schowaj odtwarzacz" : "Pokaż odtwarzacz", systemImage: "sidebar.trailing") { showsPlayer.toggle() }
            }
            ToolbarItem {
                Button("Odśwież", systemImage: "arrow.clockwise") {
                    Task {
                        await listening.refresh()
                        if case .library(let id) = selection { await listening.loadItems(libraryID: id) }
                    }
                }
                .disabled(listening.isRefreshing)
            }
        }
        .task { await listening.refresh() }
        .alert("Nie udało się", isPresented: Binding(get: { listening.loadError != nil }, set: { if !$0 { listening.loadError = nil } })) {
            Button("OK") { listening.loadError = nil }
        } message: {
            Text(listening.loadError ?? "")
        }
    }

    @ViewBuilder private var unavailable: some View {
        switch supervisor.state {
        case .running:
            ProgressView("Łączenie…")
        case .starting:
            ProgressView("Uruchamianie serwera…")
        case .stopping:
            ProgressView("Zatrzymywanie serwera…")
        case .stopped:
            ContentUnavailableView {
                Label("Serwer zatrzymany", systemImage: "books.vertical")
            } actions: {
                Button("Uruchom serwer") { supervisor.start() }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Serwer nie działa", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Uruchom ponownie") { supervisor.start() }
                Button("Ustawienia i log…") { openWindow.openSettings(.general, navigation: settings) }
            }
        }
    }
}

/// Lista pozycji: okładka, tytuł, autor, postęp. Dwuklik (albo Return) odtwarza;
/// podcast otwiera listę odcinków.
private struct ItemList: View {
    let listening: ListeningController
    let items: [AudiobookshelfClient.LibraryItem]?
    let title: String
    var isContinue = false
    @State private var selection: String?
    @State private var podcast: AudiobookshelfClient.LibraryItem?

    var body: some View {
        Group {
            if let items {
                if items.isEmpty {
                    ContentUnavailableView(
                        isContinue ? "Nic nie jest w trakcie słuchania" : "Pusta biblioteka",
                        systemImage: isContinue ? "play.circle" : "books.vertical",
                        description: Text(isContinue ? "Rozpoczęte książki pojawią się tutaj." : "")
                    )
                } else {
                    List(items, selection: $selection) { item in
                        ItemRow(listening: listening, item: item)
                            .tag(item.id)
                    }
                    .contextMenu(forSelectionType: String.self) { ids in
                        if let item = items.first(where: { ids.contains($0.id) }) {
                            Button(item.isPodcast && item.recentEpisode == nil ? "Pokaż odcinki" : "Odtwarzaj") { open(item) }
                        }
                    } primaryAction: { ids in
                        if let item = items.first(where: { ids.contains($0.id) }) { open(item) }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .navigationDestination(item: $podcast) { item in
            EpisodeList(listening: listening, podcast: item)
        }
    }

    private func open(_ item: AudiobookshelfClient.LibraryItem) {
        if item.isPodcast {
            if let episode = item.recentEpisode {
                Task { await listening.play(itemID: item.id, episodeID: episode.id) }
            } else {
                podcast = item
            }
        } else {
            Task { await listening.play(itemID: item.id) }
        }
    }
}

private struct ItemRow: View {
    let listening: ListeningController
    let item: AudiobookshelfClient.LibraryItem
    @State private var cover: NSImage?

    var body: some View {
        let key = ListeningController.key(item.id, item.recentEpisode?.id)
        let progress = listening.progress[key]
        HStack(spacing: 10) {
            CoverView(image: cover, symbol: item.isPodcast ? "mic" : "book.closed")
                .frame(width: 44, height: 44)
                .task(id: item.id) { cover = await listening.cover(for: item.id, path: item.media.coverPath, size: 44) }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.recentEpisode?.title ?? item.title).lineLimit(1)
                Text(item.recentEpisode != nil ? item.title : (item.author ?? "")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if item.isPodcast, item.recentEpisode == nil, let count = item.media.numEpisodes {
                    Text("Odcinki: \(count)").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressLine(progress: progress, duration: item.media.duration)
                }
            }
            Spacer()
            if listening.startingKey == key {
                ProgressView().controlSize(.small)
            } else if listening.player.book?.key == key {
                Image(systemName: listening.player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill").foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("item.\(item.id)")
    }
}

/// Pasek postępu z opisem („42%”, „Ukończone”).
private struct ProgressLine: View {
    let progress: AudiobookshelfClient.MediaProgress?
    let duration: Double?

    var body: some View {
        HStack(spacing: 6) {
            if let progress, progress.isFinished {
                Label("Ukończone", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
            } else if let progress, let value = progress.progress, value > 0 {
                ProgressView(value: min(1, value)).frame(maxWidth: 120)
                Text(value.formatted(.percent.precision(.fractionLength(0)))).fixedSize()
            } else if let duration, duration > 0 {
                Text(ChapterScrubber.time(duration))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Odcinki podcastu, najnowsze pierwsze; dwuklik odtwarza.
private struct EpisodeList: View {
    let listening: ListeningController
    let podcast: AudiobookshelfClient.LibraryItem
    @State private var episodes: [AudiobookshelfClient.PodcastEpisode]?
    @State private var error: String?
    @State private var selection: String?

    var body: some View {
        Group {
            if let episodes {
                List(episodes, selection: $selection) { episode in
                    let key = ListeningController.key(podcast.id, episode.id)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(episode.title ?? "Odcinek").lineLimit(2)
                            ProgressLine(progress: listening.progress[key], duration: episode.length)
                        }
                        Spacer()
                        if listening.player.book?.key == key {
                            Image(systemName: listening.player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill").foregroundStyle(.tint)
                        }
                    }
                    .tag(episode.id)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Odtwarzaj") { play(ids) }
                } primaryAction: { ids in
                    play(ids)
                }
            } else if let error {
                ContentUnavailableView("Nie udało się wczytać odcinków", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(podcast.title)
        .task {
            do { episodes = try await listening.episodes(of: podcast) } catch { self.error = error.localizedDescription }
        }
    }

    private func play(_ ids: Set<String>) {
        guard let id = ids.first else { return }
        Task { await listening.play(itemID: podcast.id, episodeID: id) }
    }
}
