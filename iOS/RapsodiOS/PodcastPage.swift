// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import Observation
import AudiobookshelfKit
import AudiobookshelfPlayback

/// Odcinek na liście podcastu: z serwera, z kanału RSS albo z obu (dopasowany), a także
/// odcinek, którego nie ma już w kanale, ale telefon ma jego lokalny postęp.
struct PodcastEpisodeRow: Identifiable, Hashable {
    let id: String
    let itemID: String
    let title: String
    let published: Date?
    let duration: Double?
    let summary: String?
    let label: String?
    let server: Client.PodcastEpisode?
    let feed: RSSEpisode?
    /// Odcinek tylko z lokalnym postępem (zniknął z kanału, nie ma go na serwerze).
    let localOnly: LocalEpisodeRecord?
    let match: EpisodeMatching.Strength?
    /// Kanał był wczytany, a odcinka serwera w nim nie ma.
    let missingFromFeed: Bool

    var feedKey: String? { feed?.id ?? localOnly?.feedKey }
    var identity: EpisodeIdentity {
        if let feed { return EpisodeIdentity(feed) }
        if let server { return EpisodeIdentity(server) }
        return localOnly?.identity ?? EpisodeIdentity(guid: nil, url: nil, title: title, published: published)
    }
    var playbackKeys: Set<String> {
        var keys: Set<String> = []
        if let server { keys.insert(PlaybackTimeline.key(itemID, server.id)) }
        if let feedKey { keys.insert(PlaybackTimeline.feedKey(itemID, feedKey)) }
        return keys
    }
    /// Można zlecić pobranie: odcinek z kanału, którego serwer nie ma.
    var canOrder: Bool { server == nil && feed != nil }
    var enclosureURL: String? { feed?.enclosure.url ?? localOnly?.enclosureURL }
}

/// Dane strony podcastu: pozycja z serwera, kanał RSS (z pamięci, potem od wydawcy) i ich złączenie.
@MainActor
@Observable
final class PodcastPageModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all, server, feedOnly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "Wszystkie"
            case .server: "Na serwerze"
            case .feedOnly: "Tylko w kanale"
            }
        }
    }

    private(set) var item: Client.ItemDetail
    private(set) var feed: RSSPodcast?
    private(set) var feedDate: Date?
    private(set) var feedError: String?
    private(set) var isLoadingFeed = false
    private(set) var rows: [PodcastEpisodeRow] = []
    private(set) var visibleRows: [PodcastEpisodeRow] = []
    var filter: Filter = .all { didSet { applyFilter() } }

    init(item: Client.ItemDetail) {
        self.item = item
    }

    var feedURL: String? { item.media.metadata.feedUrl.flatMap { $0.isEmpty ? nil : $0 } }

    func update(item: Client.ItemDetail, local: ProgressJournal) {
        self.item = item
        rebuild(local: local)
    }

    /// Kanał z pamięci od razu, potem od wydawcy (`force` — z pominięciem świeżości pamięci).
    func loadFeed(_ loader: PodcastFeedLoader, local: ProgressJournal, force: Bool) async {
        guard let url = feedURL else {
            feedError = PodcastFeedLoader.LoadError.invalidURL.localizedDescription
            rebuild(local: local)
            return
        }
        if feed == nil, let cached = await Task.detached(operation: { loader.cached(url) }).value {
            feed = cached.podcast
            feedDate = cached.fetchedAt
            rebuild(local: local)
        }
        isLoadingFeed = true
        defer { isLoadingFeed = false }
        do {
            let snapshot = try await loader.load(url, force: force)
            feed = snapshot.podcast
            feedDate = snapshot.fetchedAt
            feedError = nil
        } catch is CancellationError {
            return
        } catch {
            feedError = error.localizedDescription
        }
        rebuild(local: local)
    }

    /// Złączenie odcinków serwera i kanału (`EpisodeMatching`), od najnowszych.
    func rebuild(local: ProgressJournal) {
        let itemID = item.id
        let server = item.media.episodes?.elements ?? []
        let feedEpisodes = feed?.episodes ?? []
        let matches = EpisodeMatching.match(feedEpisodes.map(EpisodeIdentity.init), server.map(EpisodeIdentity.init))
        var usedServer = Set<Int>()
        var result: [PodcastEpisodeRow] = []
        for (index, episode) in feedEpisodes.enumerated() {
            let match = matches[index]
            let serverEpisode = match.map { server[$0.other] }
            if let match { usedServer.insert(match.other) }
            result.append(PodcastEpisodeRow(
                id: serverEpisode.map { "s:" + $0.id } ?? "f:" + episode.id,
                itemID: itemID,
                title: episode.title,
                published: episode.published ?? serverEpisode?.published,
                duration: serverEpisode?.length ?? episode.durationSeconds,
                summary: episode.summary ?? HTMLText.plain(serverEpisode?.description),
                label: Self.label(season: episode.season, episode: episode.episode, type: episode.episodeType),
                server: serverEpisode,
                feed: episode,
                localOnly: nil,
                match: match?.strength,
                missingFromFeed: false
            ))
        }
        for (index, episode) in server.enumerated() where !usedServer.contains(index) {
            result.append(PodcastEpisodeRow(
                id: "s:" + episode.id,
                itemID: itemID,
                title: episode.title ?? "Odcinek",
                published: episode.published,
                duration: episode.length,
                summary: HTMLText.plain(episode.description),
                label: Self.label(season: episode.season, episode: episode.episode, type: episode.episodeType),
                server: episode,
                feed: nil,
                localOnly: nil,
                match: nil,
                missingFromFeed: feed != nil
            ))
        }
        // Lokalny postęp odcinka, którego nie ma już ani w kanale, ani na serwerze.
        let feedKeys = Set(feedEpisodes.map(\.id))
        for record in local.records(itemID: itemID) where !feedKeys.contains(record.feedKey) {
            guard EpisodeHandover.serverEpisode(for: record, in: server) == nil else { continue }
            result.append(PodcastEpisodeRow(
                id: "l:" + record.feedKey, itemID: itemID, title: record.title, published: record.published,
                duration: record.duration, summary: nil, label: nil, server: nil, feed: nil,
                localOnly: record, match: nil, missingFromFeed: feed != nil
            ))
        }
        rows = result.enumerated().sorted { a, b in
            switch (a.element.published, b.element.published) {
            case (let x?, let y?) where x != y: return x > y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.offset < b.offset
            }
        }.map(\.element)
        applyFilter()
    }

    private func applyFilter() {
        visibleRows = switch filter {
        case .all: rows
        case .server: rows.filter { $0.server != nil }
        case .feedOnly: rows.filter { $0.server == nil }
        }
    }

    static func label(season: String?, episode: String?, type: String?) -> String? {
        var parts: [String] = []
        if let season, !season.isEmpty { parts.append("Sezon \(season)") }
        if let episode, !episode.isEmpty { parts.append("odc. \(episode)") }
        if type == "trailer" { parts.append("zwiastun") } else if type == "bonus" { parts.append("dodatek") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Strona podcastu: okładka, opis, odcinki z serwera i z kanału RSS ze stanem każdego,
/// zlecanie pobrania na serwer (także wielu naraz) i odtwarzanie.
struct PodcastPage: View {
    let model: AppModel
    let session: ServerSession
    @State private var page: PodcastPageModel
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var notice: String?
    @State private var detail: PodcastEpisodeRow?
    @State private var isOrdering = false
    @Environment(\.displayScale) private var displayScale
    @State private var cover: UIImage?
    @ScaledMetric(relativeTo: .title) private var coverSize: CGFloat = 200
    @AppStorage("orderDownloadWhenStreaming") private var orderWhenStreaming = true
    /// Odcinek ze strumienia nie ruszył (ATS, brak zakresów bajtów, plik zniknął…).
    @State private var streamFailure: (row: PodcastEpisodeRow, message: String)?
    @State private var showsPodcastSettings = false

    init(item: Client.ItemDetail, model: AppModel, session: ServerSession) {
        self.model = model
        self.session = session
        _page = State(initialValue: PodcastPageModel(item: item))
    }

    private var podcasts: PodcastStore { session.library.podcasts }
    private var item: Client.ItemDetail { page.item }

    var body: some View {
        List(selection: $selection) {
            header
            Section {
                if page.rows.count > 0 {
                    Picker("Pokaż", selection: $page.filter) {
                        ForEach(PodcastPageModel.Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                }
                feedStatus
                ForEach(page.visibleRows) { row in
                    EpisodeRowView(row: row, model: model, session: session, podcastTitle: item.title, libraryID: item.libraryId,
                                   play: { play(row) }, order: { Task { await order([row]) } }, info: { detail = row })
                        .selectionDisabled(!row.canOrder || !PodcastStore.canRequest(podcasts.downloadState(itemID: item.id, identity: row.identity, feedKey: row.feedKey)))
                }
                if page.visibleRows.isEmpty, !page.isLoadingFeed {
                    Text(page.filter == .all ? "Brak odcinków." : "Brak odcinków w tym widoku.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Odcinki")
            } footer: {
                permissionFooter
            }
        }
        .environment(\.editMode, $editMode)
        .scrollContentBackground(.hidden)
        .background(alignment: .top) {
            ArtworkBackdrop(image: cover, base: Color(.systemGroupedBackground))
                .frame(height: 560)
                .ignoresSafeArea(edges: .top)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showsPodcastSettings) {
            PodcastSettingsSheet(item: item, session: session, playback: model.playback)
        }
        .refreshable { await refresh(force: true) }
        .task(id: session.id) { await refresh(force: false) }
        // Serwer pobrał odcinek albo zmienił pozycję — przeładowanie w tle, lista zostaje na miejscu.
        .task(id: podcasts.revision[item.id] ?? 0) {
            guard podcasts.revision[item.id] != nil else { return }
            await reloadItem()
        }
        .onChange(of: session.library.podcasts.localEpisodes.membershipRevision) {
            page.rebuild(local: podcasts.localEpisodes)
        }
        .sheet(item: $detail) { row in
            EpisodeDetailSheet(row: row, podcastTitle: item.title, libraryID: item.libraryId, session: session)
        }
        .alert("Nie udało się odtworzyć", isPresented: Binding(get: { streamFailure != nil }, set: { if !$0 { streamFailure = nil } }), presenting: streamFailure) { failure in
            // Plik zniknął u wydawcy — serwer też go nie pobierze.
            if failure.row.canOrder, podcasts.permission.canOrder, failure.message != PlaybackCoordinator.StreamError.notFound.errorDescription {
                Button("Pobierz na serwer") { Task { await order([failure.row]) } }
            }
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
        .alert("Pobieranie", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: Nagłówek

    @ViewBuilder
    private var header: some View {
        Section {
            VStack(spacing: 12) {
                CoverImage(image: cover, isPodcast: true)
                    .frame(width: min(coverSize, 280))
                    .accessibilityHidden(true)
                    .padding(.top, 8)
                    .task(id: item.id) {
                        cover = await session.cover(itemID: item.id, path: nil, size: 300, scale: displayScale)
                    }
                Text(item.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let author = item.media.metadata.author ?? page.feed?.author, !author.isEmpty {
                    Text(author).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if let combined = session.library.combined, combined.hasSeveralPodcastLibraries, let name = combined.libraryName(item.libraryId) {
                    LibraryBadge(name: name)
                }
                if let latest = page.rows.first {
                    // Najnowszy odcinek jednym dotknięciem, jak w aplikacjach podcastowych.
                    Button {
                        play(latest)
                    } label: {
                        Label(latest.server == nil ? "Najnowszy odcinek (ze strumienia)" : "Najnowszy odcinek", systemImage: "play.fill")
                            .foregroundStyle(.white)
                            .font(.headline)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 22))
                    .controlSize(.large)
                    .accessibilityHint(Text(latest.title))
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
        if let text = HTMLText.plain(item.media.metadata.description) ?? page.feed?.summary, !text.isEmpty {
            Section {
                ExpandableText(text: text, lineLimit: 4)
            }
        }
    }

    @ViewBuilder
    private var feedStatus: some View {
        if page.isLoadingFeed, page.feed == nil {
            HStack(spacing: 8) {
                ProgressView()
                Text("Wczytywanie kanału RSS…").foregroundStyle(.secondary)
            }
            .font(.footnote)
        } else if let error = page.feedError {
            Label {
                Text(page.feed == nil
                     ? "Nie udało się wczytać kanału RSS: \(error) Widać tylko odcinki na serwerze."
                     : "Nie udało się odświeżyć kanału: \(error) Lista z \(page.feedDate.map { $0.formatted(.relative(presentation: .named)) } ?? "wcześniej").")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var permissionFooter: some View {
        if !podcasts.permission.canOrder, page.rows.contains(where: { $0.server == nil }) {
            Text("Odcinków spoza serwera możesz słuchać ze strumienia od wydawcy — ich postęp zostaje wtedy tylko na tym telefonie, dopóki odcinek nie trafi na serwer. \(PodcastStore.permissionHelp(podcasts.permission)) Potem pociągnij listę w dół.")
        } else if let date = page.feedDate {
            Text("Kanał RSS sprawdzony \(date.formatted(.relative(presentation: .named))). Pociągnij w dół, żeby odświeżyć.")
        }
    }

    /// Odcinki z serwera do pobrania na telefon, od najnowszych (`nil` — wszystkie).
    private func downloadLatest(_ count: Int?) {
        let server = page.rows.compactMap(\.server)
        let chosen = count.map { Array(server.prefix($0)) } ?? server
        Task {
            notice = await BulkDownload.start(chosen.map { .episode($0, itemID: item.id, podcastTitle: item.title, libraryID: item.libraryId) }, session: session).message
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Segmenty sponsorowane (ten telefon) i — dla administratora — pobieranie na serwer.
        ToolbarItem(placement: .topBarTrailing) {
            Button("Ustawienia podcastu", systemImage: "gearshape") { showsPodcastSettings = true }
                .accessibilityIdentifier("podcast.settings")
        }
        if page.rows.contains(where: { $0.server != nil }) {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Pobierz na telefon", systemImage: "arrow.down.circle") {
                    Section("Odcinki z serwera") {
                        Button("3 najnowsze") { downloadLatest(3) }
                        Button("10 najnowszych") { downloadLatest(10) }
                        Button("Wszystkie (\(page.rows.count { $0.server != nil }))") { downloadLatest(nil) }
                    }
                }
            }
        }
        // Bez uprawnień zaznaczanie nic by nie dało — przycisk znika (wyjaśnienie jest pod listą).
        if podcasts.permission.canOrder, page.rows.contains(where: \.canOrder) {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "Gotowe" : "Zaznacz") {
                    withAnimation {
                        editMode = editMode.isEditing ? .inactive : .active
                        selection = []
                    }
                }
            }
        }
        if editMode.isEditing {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    let rows = page.rows.filter { selection.contains($0.id) }
                    Task {
                        await order(rows)
                        withAnimation { editMode = .inactive; selection = [] }
                    }
                } label: {
                    if isOrdering { ProgressView() } else { Text(selection.isEmpty ? "Pobierz na serwer" : "Pobierz na serwer (\(selection.count))") }
                }
                .disabled(selection.isEmpty || isOrdering || !podcasts.permission.canOrder)
            }
        }
    }

    // MARK: Działania

    private func refresh(force: Bool) async {
        // `/api/me`: postęp odcinków i typ konta (serwer nie powiadamia telefonu o zmianie uprawnień).
        await session.library.refreshProgress()
        if force { await reloadItem() }
        await page.loadFeed(podcasts.feeds, local: podcasts.localEpisodes, force: force)
        if let combined = session.library.combined { await podcasts.loadQueue(libraries: combined.podcastLibraries) }
        await podcasts.reconcile(page.item)
    }

    private func reloadItem() async {
        do {
            let fresh = try await session.auth.perform { try await $0.item(id: item.id, token: $1) }
            page.update(item: fresh, local: podcasts.localEpisodes)
            await session.library.refreshProgress()
            await podcasts.reconcile(fresh)
        } catch {
            if AddressSelection.isConnectionError(error) { model.connectionTroubled() }
        }
    }

    private func play(_ row: PodcastEpisodeRow) {
        Task {
            if let server = row.server {
                await podcasts.play(itemID: item.id, episode: server, weakLocal: podcasts.weakLocal(itemID: item.id, feedKey: row.feedKey, match: row.match))
                return
            }
            guard let url = row.enclosureURL, let feedKey = row.feedKey else { return }
            let episode = PlaybackCoordinator.ExternalEpisode(
                itemID: item.id, feedKey: feedKey, title: row.title, podcastTitle: item.title,
                guid: row.feed?.guid ?? row.localOnly?.guid, enclosureURL: url, published: row.published,
                feedDuration: row.feed?.durationSeconds ?? row.localOnly?.duration, summary: row.feed?.summary
            )
            let wasPlaying = model.playback.nowPlayingKeys.contains(PlaybackTimeline.feedKey(item.id, feedKey))
            await model.playback.play(external: episode)
            if !wasPlaying, let error = model.playback.loadError, !model.playback.nowPlayingKeys.contains(PlaybackTimeline.feedKey(item.id, feedKey)) {
                streamFailure = (row, error)
                return
            }
            // Słuchanie ze strumienia + pobranie na serwer w tle (gdy konto może i nikt jeszcze nie zlecił).
            if !wasPlaying, orderWhenStreaming, row.canOrder, podcasts.permission.canOrder, model.playback.loadError == nil,
               podcasts.downloadState(itemID: item.id, identity: row.identity, feedKey: feedKey) == nil, let feedEpisode = row.feed {
                _ = try? await podcasts.order([feedEpisode], item: item)
            }
        }
    }

    private func order(_ rows: [PodcastEpisodeRow]) async {
        let episodes = rows.compactMap(\.feed)
        guard !episodes.isEmpty else { return }
        isOrdering = true
        defer { isOrdering = false }
        do {
            try await podcasts.order(episodes, item: item)
            if let combined = session.library.combined { await podcasts.loadQueue(libraries: combined.podcastLibraries) }
        } catch {
            notice = error.localizedDescription
        }
    }
}

/// Wiersz odcinka: tytuł, data i długość, stan (na serwerze / tylko w kanale / pobierany / w kolejce),
/// postęp i przycisk odtwarzania. Osobny widok — obserwuje tylko swój postęp.
private struct EpisodeRowView: View {
    let row: PodcastEpisodeRow
    let model: AppModel
    let session: ServerSession
    let podcastTitle: String
    let libraryID: String?
    let play: () -> Void
    let order: () -> Void
    let info: () -> Void
    @Environment(\.editMode) private var editMode
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var downloadError: String?
    @State private var showsSkips = false

    private var podcasts: PodcastStore { session.library.podcasts }

    /// „Pobierz na telefon” jest niezależne od „Pobierz na serwer”: dotyczy odcinków już na serwerze.
    private var phoneDownload: DownloadTarget? {
        row.server.map { .episode($0, itemID: row.itemID, podcastTitle: podcastTitle, libraryID: libraryID) }
    }

    var body: some View {
        let download = podcasts.downloadState(itemID: row.itemID, identity: row.identity, feedKey: row.feedKey)
        let showsButton = editMode?.wrappedValue.isEditing != true
        Group {
            if typeSize.isAccessibilitySize {
                // Największy tekst: cała szerokość na tekst, przycisk pod nim.
                VStack(alignment: .leading, spacing: 6) {
                    details(download: download, lineLimit: nil)
                    if showsButton {
                        PlayEpisodeButton(row: row, playback: model.playback, action: play)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    details(download: download, lineLimit: 3)
                    Spacer(minLength: 0)
                    if showsButton {
                        PlayEpisodeButton(row: row, playback: model.playback, action: play)
                    }
                }
            }
        }
        .contentShape(.rect)
        .contextMenu {
            Button("Opis odcinka", systemImage: "info.circle", action: info)
            if row.server != nil {
                Button("Fragmenty sponsorowane…", systemImage: "forward.end.alt") { showsSkips = true }
            }
            if row.canOrder, PodcastStore.canRequest(download) {
                Button("Pobierz na serwer", systemImage: "externaldrive.badge.plus", action: order)
                    .disabled(!podcasts.permission.canOrder)
            }
            if let phoneDownload {
                DownloadMenuItems(target: phoneDownload, session: session) { downloadError = $0 }
            }
        }
        .sheet(isPresented: $showsSkips) {
            if let server = row.server {
                EpisodeSkipSheet(itemID: row.itemID, episodeID: server.id, title: row.title, model: model)
            }
        }
        .alert("Nie udało się pobrać", isPresented: Binding(get: { downloadError != nil }, set: { if !$0 { downloadError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
        .swipeActions(edge: .trailing) {
            if row.canOrder, PodcastStore.canRequest(download), podcasts.permission.canOrder {
                Button("Pobierz na serwer", systemImage: "arrow.down.circle", action: order).tint(.accentColor)
            }
        }
        .swipeActions(edge: .leading) {
            if let phoneDownload, session.downloads.manager.entry(itemID: row.itemID, episodeID: phoneDownload.episodeID).status == .notDownloaded {
                Button("Pobierz na telefon", systemImage: "arrow.down.circle") {
                    Task {
                        do { try await phoneDownload.start(in: session) } catch { downloadError = error.localizedDescription }
                    }
                }
                .tint(.green)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Opis odcinka", info)
        .accessibilityActions {
            if row.server != nil {
                Button("Fragmenty sponsorowane") { showsSkips = true }
            }
            if row.canOrder, PodcastStore.canRequest(download), podcasts.permission.canOrder {
                Button("Pobierz na serwer", action: order)
            }
        }
    }

    private func details(download: PodcastStore.DownloadState?, lineLimit: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(lineLimit)
            meta
            HStack(spacing: 6) {
                EpisodeStateLabel(row: row, download: download)
                if let server = row.server {
                    PhoneDownloadLabel(entry: session.downloads.manager.entry(itemID: row.itemID, episodeID: server.id))
                }
            }
            EpisodeProgressLine(row: row, session: session)
        }
    }

    private var meta: some View {
        let parts = [row.published.map { $0.formatted(.dateTime.day().month(.abbreviated).year()) },
                     row.duration.map { TimeText.long($0) }, row.label].compactMap(\.self)
        return Text(parts.joined(separator: " · "))
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

/// Stan pobrania na telefon przy odcinku (obserwuje tylko wpis tego odcinka). Pusty, gdy nie pobrano.
private struct PhoneDownloadLabel: View {
    let entry: DownloadManager.Entry

    var body: some View {
        if entry.status != .notDownloaded {
            HStack(spacing: 4) {
                DownloadBadge(status: entry.status).accessibilityHidden(true)
                Text(entry.status == .downloaded ? "Na telefonie" : entry.status.text)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.status.text)
        }
    }
}

/// Stan odcinka słownie i ikoną.
private struct EpisodeStateLabel: View {
    let row: PodcastEpisodeRow
    let download: PodcastStore.DownloadState?

    var body: some View {
        let (text, icon, tint): (String, String, Color) = {
            if row.server != nil {
                return (row.missingFromFeed ? "Na serwerze · nie ma go już w kanale" : "Na serwerze", "externaldrive.fill", .green)
            }
            switch download {
            case .downloading: return ("Serwer pobiera…", "arrow.down.circle.dotted", .blue)
            case .queued: return ("W kolejce pobierania serwera", "clock", .blue)
            case .failed: return ("Serwer nie pobrał odcinka — spróbuj ponownie", "exclamationmark.triangle", .orange)
            case nil:
                if row.localOnly != nil { return ("Nie ma go już w kanale", "questionmark.circle", .secondary) }
                return ("Tylko w kanale RSS", "dot.radiowaves.up.forward", .secondary)
            }
        }()
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
    }
}

/// Postęp odcinka: z serwera (odcinek na serwerze) albo z telefonu (odcinek ze strumienia).
private struct EpisodeProgressLine: View {
    let row: PodcastEpisodeRow
    let session: ServerSession

    var body: some View {
        if let server = row.server {
            ServerProgressLine(entry: session.library.progress.entry(PlaybackTimeline.key(row.itemID, server.id)), duration: row.duration)
        } else if let feedKey = row.feedKey {
            LocalProgressLine(entry: session.library.podcasts.localEpisodes.entry(itemID: row.itemID, feedKey: feedKey))
        }
    }
}

private struct ServerProgressLine: View {
    let entry: ProgressStore.Entry
    let duration: Double?

    var body: some View {
        if let value = entry.value {
            ProgressCaption(fraction: value.isFinished ? 1 : (value.progress ?? 0), finished: value.isFinished,
                            remaining: (duration ?? value.duration).map { max(0, $0 - (value.currentTime ?? 0)) }, localOnly: false)
        }
    }
}

private struct LocalProgressLine: View {
    let entry: ProgressJournal.Entry

    var body: some View {
        if let record = entry.value, record.isFinished || record.currentTime > 1 {
            ProgressCaption(fraction: record.fraction, finished: record.isFinished, remaining: max(0, record.duration - record.currentTime), localOnly: true)
        }
    }
}

private struct ProgressCaption: View {
    let fraction: Double
    let finished: Bool
    let remaining: Double?
    let localOnly: Bool

    private var caption: String {
        var parts: [String] = []
        if finished { parts.append("Ukończony") } else if let remaining, fraction > 0 { parts.append("zostało \(TimeText.long(remaining))") }
        if localOnly { parts.append("postęp tylko na tym telefonie") }
        return parts.joined(separator: " · ")
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 6))
        layout {
            if finished {
                Image(systemName: "checkmark.circle.fill")
            } else if fraction > 0 {
                ProgressView(value: min(1, fraction)).frame(maxWidth: 60)
            }
            Text(caption)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(finished ? "Ukończony" : "Przesłuchane \(Int(min(1, fraction) * 100)) procent")\(localOnly ? ", postęp tylko na tym telefonie" : "")"))
    }
}

/// Odtwórz / pauza dla odcinka; obserwuje tylko stan odtwarzacza (bez czasu).
private struct PlayEpisodeButton: View {
    let row: PodcastEpisodeRow
    let playback: PlaybackCoordinator
    let action: () -> Void

    var body: some View {
        let isCurrent = !playback.nowPlayingKeys.isDisjoint(with: row.playbackKeys)
        let isStarting = playback.startingKey.map { row.playbackKeys.contains($0) } ?? false
        let playable = row.server != nil || row.enclosureURL.flatMap(RSSFeedParser.webURL) != nil
        Button(action: action) {
            Group {
                if isStarting {
                    ProgressView()
                } else {
                    Image(systemName: isCurrent && playback.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title)
                        .foregroundStyle(.tint)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .disabled(!playable || isStarting)
        .accessibilityLabel(Text(isCurrent && playback.player.isPlaying ? "Pauza" : (row.server == nil ? "Odtwórz ze strumienia" : "Odtwórz")))
    }
}

/// Opis odcinka (czysty tekst z kanału albo z serwera).
private struct EpisodeDetailSheet: View {
    let row: PodcastEpisodeRow
    let podcastTitle: String
    let libraryID: String?
    let session: ServerSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(row.title).font(.title3.bold())
                    Text(podcastTitle).foregroundStyle(.secondary)
                    if let published = row.published {
                        Text(published, format: .dateTime.day().month(.wide).year()).font(.footnote).foregroundStyle(.secondary)
                    }
                    // Odcinek na serwerze: pobranie na telefon (stan, procent, wstrzymanie, usunięcie).
                    if let server = row.server {
                        VStack(alignment: .leading, spacing: 4) {
                            DownloadButton(target: .episode(server, itemID: row.itemID, podcastTitle: podcastTitle, libraryID: libraryID), session: session)
                        }
                    }
                    if let summary = row.summary, !summary.isEmpty {
                        Text(summary).textSelection(.enabled)
                    } else {
                        Text("Brak opisu.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Odcinek")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Gotowe") { dismiss() } }
            }
        }
    }
}
