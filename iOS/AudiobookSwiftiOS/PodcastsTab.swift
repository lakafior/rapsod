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

    var body: some View {
        NavigationStack {
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
                    PodcastsContent(combined: combined, model: model, session: session)
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

    @State private var podcasts: [Client.LibraryItem]?
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if model.isOffline {
                    Label("Brak połączenia z serwerem.", systemImage: "wifi.slash")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
                FailureNotice(failures: failures).padding(.horizontal)
                ContinueEpisodes(serverItems: inProgress, model: model, session: session) { playError = $0 }
                if !recent.isEmpty {
                    EpisodeShelf(title: "Najnowsze odcinki", episodes: recent, combined: combined, model: model, session: session)
                }
                if !sorted.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Wszystkie podcasty")
                            .font(.title3.bold())
                            .accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: coverColumns(minimum: cardMinimum), spacing: 18) {
                            ForEach(sorted) { item in
                                PodcastCard(item: item, session: session,
                                            libraryName: combined.hasSeveralPodcastLibraries ? combined.libraryName(item.libraryId) : nil)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .overlay {
            if let podcasts, podcasts.isEmpty {
                ContentUnavailableView("Brak podcastów", systemImage: "dot.radiowaves.left.and.right",
                                       description: Text("W bibliotekach podcastów nie ma jeszcze żadnego podcastu. Dodasz go na Macu."))
            } else if podcasts == nil {
                if let error {
                    LoadFailureView(message: error) { Task { await load() } }
                } else {
                    ProgressView()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { sortMenu }
        }
        .alert("Nie udało się odtworzyć", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text((playError ?? "") + " Na stronie podcastu możesz zlecić pobranie na serwer.")
        }
        .refreshable {
            await model.reconnect()
            await session.library.refreshProgress()
            await load()
        }
        .task(id: Trigger(items: session.library.itemsRevision, progress: session.library.progressRevision, playing: model.playback.nowPlayingKey)) {
            await load()
        }
        .onChange(of: SortKey(sort: sort, descending: descending)) { resort() }
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
            Picker("Sortuj", selection: Binding(get: { sort }, set: { value in
                if value == sort { descending.toggle() } else { sort = value; descending = value.defaultDescending }
            })) {
                ForEach(CombinedLibraries.PodcastSort.allCases, id: \.self) { option in
                    Label(Self.title(option), systemImage: option == sort ? (descending ? "chevron.down" : "chevron.up") : "")
                        .tag(option)
                }
            }
        } label: {
            Label("Sortuj", systemImage: "arrow.up.arrow.down")
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
                ItemCover(itemID: item.id, session: session)
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
/// połączone bez powtórzeń (`ContinueListening`): każdy zaczęty odcinek raz, od ostatnio słuchanego.
struct ContinueEpisodes: View {
    var title = "Słuchaj dalej"
    let serverItems: [Client.LibraryItem]
    let model: AppModel
    let session: ServerSession
    let failed: (String) -> Void

    var body: some View {
        let podcasts = session.library.podcasts
        let merged = ContinueListening.merge(books: [], serverEpisodes: serverItems, local: podcasts.localEpisodes.inProgress,
                                             lastUpdate: session.library.progress.lastUpdateByKey, limit: 8)
        if !merged.entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.title3.bold())
                    .padding(.horizontal)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(merged.entries) { entry in
                        row(entry)
                    }
                }
                .padding(.horizontal)
            }
            // Pewne dopasowania ukryte na półce — ich postęp trafia na serwer.
            .task(id: merged.handover.map(\.id)) {
                if !merged.handover.isEmpty { podcasts.handOver(merged.handover) }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: ContinueListening.Entry) -> some View {
        switch entry.kind {
        case .serverEpisode(let item, let episode, let weakLocal):
            CompactEpisodeRow(itemID: item.id, title: episode.title ?? "Odcinek", podcastTitle: item.title,
                              keys: Set([PlaybackTimeline.key(item.id, episode.id)] + (weakLocal.map { [PlaybackTimeline.feedKey(item.id, $0.feedKey)] } ?? [])),
                              localOnly: false, session: session, playback: model.playback,
                              download: .episode(episode, itemID: item.id, podcastTitle: item.title, libraryID: item.libraryId)) {
                Task { await session.library.podcasts.play(itemID: item.id, episode: episode, weakLocal: weakLocal) }
            }
        case .localEpisode(let record):
            CompactEpisodeRow(itemID: record.itemID, title: record.title, podcastTitle: record.podcastTitle ?? "",
                              keys: [PlaybackTimeline.feedKey(record.itemID, record.feedKey)], localOnly: true, session: session, playback: model.playback) {
                Task {
                    let key = PlaybackTimeline.feedKey(record.itemID, record.feedKey)
                    await model.playback.play(external: .init(
                        itemID: record.itemID, feedKey: record.feedKey, title: record.title, podcastTitle: record.podcastTitle,
                        guid: record.guid, enclosureURL: record.enclosureURL, published: record.published, feedDuration: record.duration))
                    if let error = model.playback.loadError, !model.playback.nowPlayingKeys.contains(key) { failed(error) }
                }
            }
        case .book:
            EmptyView()
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

/// „Najnowsze odcinki” — odcinki na serwerze ze wszystkich bibliotek, od najnowszego.
struct EpisodeShelf: View {
    let title: String
    let episodes: [Client.PodcastEpisode]
    let combined: CombinedLibraries
    let model: AppModel
    let session: ServerSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.bold())
                .padding(.horizontal)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(episodes) { episode in
                    if let itemID = episode.libraryItemId {
                        CompactEpisodeRow(itemID: itemID, title: episode.title ?? "Odcinek",
                                          podcastTitle: [episode.podcast?.metadata?.title, episode.published.map { $0.formatted(.dateTime.day().month(.abbreviated)) }].compactMap(\.self).joined(separator: " · "),
                                          keys: [PlaybackTimeline.key(itemID, episode.id)], localOnly: false, session: session, playback: model.playback,
                                          download: .episode(episode, itemID: itemID, podcastTitle: episode.podcast?.metadata?.title, libraryID: nil)) {
                            Task { await model.playback.play(itemID: itemID, episodeID: episode.id) }
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}
