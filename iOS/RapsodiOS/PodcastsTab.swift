// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AudiobookshelfKit
import AudiobookshelfPlayback

/// Zakładka „Podcasty”: wszystkie biblioteki podcastów jako jedna — odcinki w trakcie (z serwera
/// i słuchane ze strumienia), najnowsze odcinki na serwerze i podcasty z sortowaniem.
struct PodcastsTab: View {
    let model: AppModel
    let session: ServerSession
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch session.library.state {
                case .loading where model.isOffline:
                    // Bez sieci nie czekamy na limit czasu zapytań — od razu to, co jest na telefonie.
                    OfflineFallback(model: model, session: session, message: nil) { Task { await model.reconnect() } }
                case .loading:
                    ProgressView()
                case .failed(let message):
                    OfflineFallback(model: model, session: session, message: message) { Task { await session.library.load() } }
                case .ready(let combined):
                    PodcastsContent(combined: combined, model: model, session: session) { path.append(Route.item($0)) }
                }
            }
            .navigationTitle("Podcasty")
            .browseDestinations(model: model, session: session)
        }
    }
}

private struct PodcastsContent: View {
    let combined: CombinedLibraries
    let model: AppModel
    let session: ServerSession
    let open: (String) -> Void

    @State private var podcasts: [Client.LibraryItem]?
    @State private var adding = false
    @State private var recent: [Client.PodcastEpisode] = []
    @State private var inProgress: [Client.LibraryItem] = []
    @State private var failures: [LibraryFailure] = []
    @State private var error: String?
    @State private var playError: String?
    @AppStorage("podcastSort") private var sort: CombinedLibraries.PodcastSort = .title
    @AppStorage("podcastSortDescending") private var descending = false
    @ScaledMetric(relativeTo: .body) private var cardMinimum: CGFloat = 104

    /// Posortowana lista — liczona przy zmianie danych albo sortowania, nie w `body`.
    @State private var sorted: [Client.LibraryItem] = []

    @AppStorage("podcasts.layout") private var layout: BookLayout = .grid

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if model.isOffline {
                    Label("Brak połączenia z serwerem.", systemImage: "wifi.slash")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, Design.margin)
                }
                FailureNotice(failures: failures).padding(.horizontal, Design.margin)
                ContinueEpisodesShelf(serverItems: inProgress, model: model, session: session) { playError = $0 }
                if !recent.isEmpty {
                    EpisodeColumnsShelf(title: "Najnowsze odcinki", destination: .shelf(.newEpisodes), episodes: recent, model: model, session: session)
                }
                if !sorted.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Wszystkie podcasty", subtitle: PolishCount.form(sorted.count, one: "podcast", few: "podcasty", many: "podcastów"))
                        switch layout {
                        case .grid:
                            LazyVGrid(columns: coverColumns(minimum: cardMinimum), spacing: 20) {
                                ForEach(sorted) { item in
                                    PodcastCard(item: item, session: session,
                                                libraryName: combined.hasSeveralPodcastLibraries ? combined.libraryName(item.libraryId) : nil)
                                }
                            }
                            .padding(.horizontal, Design.margin)
                        case .list:
                            LazyVStack(spacing: 0) {
                                ForEach(sorted) { item in
                                    NavigationLink(value: Route.item(item.id)) {
                                        VStack(spacing: 0) {
                                            HStack(spacing: 12) {
                                                ItemCover(itemID: item.id, session: session, points: 60, isPodcast: true).frame(width: 56)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(item.title).lineLimit(2)
                                                    Text([item.author, item.media.numEpisodes.map(PolishCount.episodes)].compactMap(\.self).joined(separator: " · "))
                                                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                                }
                                                Spacer(minLength: 0)
                                            }
                                            .padding(.vertical, 8)
                                            Divider().padding(.leading, 68)
                                        }
                                        .contentShape(.rect)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, Design.margin)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .overlay {
            if let podcasts, podcasts.isEmpty {
                ContentUnavailableView("Brak podcastów", systemImage: "dot.radiowaves.left.and.right",
                                       description: Text(canAdd ? "W bibliotekach podcastów nie ma jeszcze żadnego podcastu. Dodasz go przyciskiem +." : "W bibliotekach podcastów nie ma jeszcze żadnego podcastu. Dodasz go na Macu."))
            } else if podcasts == nil {
                if let error {
                    LoadFailureView(message: error) { Task { await load() } }
                } else {
                    ShelvesSkeleton()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { sortMenu }
            if canAdd {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Dodaj podcast", systemImage: "plus") { adding = true }
                        .disabled(model.isOffline)
                        .accessibilityIdentifier("podcasts.add")
                }
            }
        }
        .sheet(isPresented: $adding) {
            AddPodcastSheet(session: session, libraries: combined.podcastLibraries) { id in
                session.library.noteItemAdded()
                if let id { open(id) }
            }
        }
        .alert("Nie udało się odtworzyć", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text((playError ?? "") + " Na stronie podcastu możesz zlecić pobranie na serwer.")
        }
        .refreshable {
            await model.reconnect()
            // Nowy postęp zmienia `progressRevision` — listę wczytuje wtedy `.task(id:)`.
            await session.library.refreshProgress()
        }
        .task(id: Trigger(items: session.library.itemsRevision, progress: session.library.progressRevision, playing: model.playback.nowPlayingKey)) {
            await load()
        }
        .onChange(of: SortKey(sort: sort, descending: descending)) { resort() }
    }

    /// Serwer pozwala dodawać podcasty tylko administratorom; przed `/api/me` przycisk też jest
    /// (odmowę serwera arkusz wyjaśni).
    private var canAdd: Bool {
        !combined.podcastLibraries.isEmpty && session.library.podcasts.permission != .listener
    }

    private struct Trigger: Hashable {
        let items: Int
        let progress: Int
        let playing: String?
    }

    private struct SortKey: Equatable {
        let sort: CombinedLibraries.PodcastSort
        let descending: Bool
    }

    private var sortMenu: some View {
        Menu {
            Picker("Widok", selection: $layout) {
                Label("Siatka", systemImage: "square.grid.2x2").tag(BookLayout.grid)
                Label("Lista", systemImage: "list.bullet").tag(BookLayout.list)
            }
            .pickerStyle(.palette)
            Picker("Sortuj", selection: Binding(get: { sort }, set: { value in
                if value == sort { descending.toggle() } else { sort = value; descending = value.defaultDescending }
            })) {
                ForEach(CombinedLibraries.PodcastSort.allCases, id: \.self) { option in
                    Group {
                        if option == sort {
                            Label(Self.title(option), systemImage: descending ? "chevron.down" : "chevron.up")
                        } else {
                            Text(Self.title(option))
                        }
                    }
                    .tag(option)
                }
            }
        } label: {
            Label("Widok i sortowanie", systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(Text("Sortuj podcasty: \(Self.title(sort)), \(descending ? "malejąco" : "rosnąco")"))
    }

    static func title(_ sort: CombinedLibraries.PodcastSort) -> String {
        switch sort {
        case .title: "Tytuł"
        case .author: "Autor"
        case .addedAt: "Data dodania"
        case .episodes: "Liczba odcinków"
        }
    }

    private func resort() {
        sorted = CombinedLibraries.sortPodcasts(podcasts ?? [], by: sort, descending: descending, ignoresPrefix: combined.ignoresTitlePrefix)
    }

    private func load() async {
        async let list = combined.podcasts()
        async let latest = try? combined.recentEpisodes(limit: 12)
        async let progress: [Client.LibraryItem]? = try? session.auth.perform { try await $0.itemsInProgress(token: $1) }
        do {
            let result = try await list
            podcasts = result.value
            failures = result.failures
            error = nil
            resort()
        } catch is CancellationError {
            return
        } catch {
            self.error = LibraryStore.message(error)
            if AddressSelection.isConnectionError(error) { model.connectionTroubled() }
        }
        recent = await latest?.value ?? recent
        if let items = await progress {
            inProgress = items.filter { $0.isPodcast && $0.recentEpisode != nil }
        }
    }
}

/// Karta podcastu w siatce.
struct PodcastCard: View {
    let item: Client.LibraryItem
    let session: ServerSession
    let libraryName: String?

    var body: some View {
        NavigationLink(value: Route.item(item.id)) {
            VStack(alignment: .leading, spacing: 4) {
                ItemCover(itemID: item.id, session: session, isPodcast: true)
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let author = item.author, !author.isEmpty {
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let count = item.media.numEpisodes {
                    Text(PolishCount.episodes(count)).font(.caption2).foregroundStyle(.secondary)
                }
                if let libraryName { LibraryBadge(name: libraryName) }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text([item.title, item.author, item.media.numEpisodes.map { "na serwerze \(PolishCount.episodes($0))" }, libraryName.map { "biblioteka \($0)" }]
                .compactMap(\.self).filter { !$0.isEmpty }.joined(separator: ", ")))
        }
        .buttonStyle(.plain)
    }
}

/// Odcinki w trakcie: z serwera (`items-in-progress`) i słuchane ze strumienia (postęp na telefonie),
/// połączone bez powtórzeń (`ContinueListening`) — te same karty co na Starcie.
struct ContinueEpisodesShelf: View {
    let serverItems: [Client.LibraryItem]
    let model: AppModel
    let session: ServerSession
    let failed: (String) -> Void

    var body: some View {
        let podcasts = session.library.podcasts
        let merged = ContinueListening.merge(books: [], serverEpisodes: serverItems, local: podcasts.localEpisodes.inProgress,
                                             lastUpdate: session.library.progress.lastUpdateByKey, limit: 12)
        Shelf(title: "Słuchaj dalej", width: .wide, items: merged.entries) { entry in
            ContinueCard(entry: entry, model: model, session: session, failed: failed)
        }
        // Pewne dopasowania ukryte na półce — ich postęp trafia na serwer.
        .task(id: merged.handover.map(\.id)) {
            if !merged.handover.isEmpty { podcasts.handOver(merged.handover) }
        }
    }
}

/// Wiersz odcinka na półce: okładka podcastu, tytuł, przycisk odtwarzania.
struct CompactEpisodeRow: View {
    let itemID: String
    let title: String
    let podcastTitle: String
    let keys: Set<String>
    let localOnly: Bool
    let session: ServerSession
    let playback: PlaybackCoordinator
    /// Odcinek na serwerze — można go pobrać na telefon (menu kontekstowe, znacznik stanu).
    var download: DownloadTarget? = nil
    let play: () -> Void
    @ScaledMetric(relativeTo: .body) private var coverSide: CGFloat = 48
    @State private var downloadError: String?

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let isCurrent = !playback.nowPlayingKeys.isDisjoint(with: keys)
        let icon = Image(systemName: isCurrent && playback.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
            .font(.title2)
            .foregroundStyle(.tint)
        let cover = ItemCover(itemID: itemID, session: session, points: 60)
            .frame(width: min(coverSide, 72), height: min(coverSide, 72))
        Button(action: play) {
            Group {
                if typeSize.isAccessibilitySize {
                    // Największy tekst: tytuł pod okładką, bez ucinania.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            cover
                            Spacer(minLength: 0)
                            icon
                        }
                        texts(lineLimit: nil)
                    }
                } else {
                    HStack(spacing: 12) {
                        cover
                        texts(lineLimit: 2)
                        Spacer(minLength: 0)
                        if let download { DownloadEntryBadge(entry: session.downloads.manager.entry(itemID: download.itemID, episodeID: download.episodeID)) }
                        icon
                    }
                }
            }
            .padding(.vertical, 6)
            .contentShape(.rect)
            // Na zawartości przycisku, nie na nim — inaczej VoiceOver widzi dwa elementy (etap 10d).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(title), \(podcastTitle)\(localOnly ? ", postęp tylko na tym telefonie" : "")\(downloadSuffix)"))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(isCurrent && playback.player.isPlaying ? "Wstrzymuje odtwarzanie" : "Odtwarza odcinek"))
        .contextMenu {
            if let download {
                DownloadMenuItems(target: download, session: session) { downloadError = $0 }
            }
        }
        .alert("Nie udało się pobrać", isPresented: Binding(get: { downloadError != nil }, set: { if !$0 { downloadError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
    }

    /// Stan pobrania w etykiecie VoiceOver (tylko gdy coś się dzieje albo jest pobrane).
    private var downloadSuffix: String {
        guard let download else { return "" }
        let status = session.downloads.manager.entry(itemID: download.itemID, episodeID: download.episodeID).status
        return status == .notDownloaded ? "" : ", \(status.text)"
    }

    private func texts(lineLimit: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(lineLimit).multilineTextAlignment(.leading)
            Text(localOnly ? "\(podcastTitle) · postęp na tym telefonie" : podcastTitle)
                .font(.caption).foregroundStyle(.secondary).lineLimit(lineLimit == nil ? nil : 1)
        }
    }
}

