// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import Observation
import AudiobookshelfKit
import AudiobookshelfPlayback

/// Półki Startu (etap 10i). Osobny obiekt połączenia, żeby pełne listy („Zobacz wszystko”)
/// pokazywały to samo, co półka, bez ponownego pytania serwera.
@MainActor
@Observable
final class HomeFeed {
    private(set) var shelves: CombinedLibraries.Shelves?
    private(set) var recentEpisodes: [Client.PodcastEpisode] = []
    /// Zaczęte odcinki z `items-in-progress` (każdy odcinek osobno).
    private(set) var episodesInProgress: [Client.LibraryItem] = []
    private(set) var error: String?

    var isLoaded: Bool { shelves != nil }

    func load(_ combined: CombinedLibraries, session: ServerSession, model: AppModel) async {
        async let episodes = try? combined.recentEpisodes(limit: 15)
        async let progress: [Client.LibraryItem]? = try? session.auth.perform { try await $0.itemsInProgress(token: $1) }
        do {
            shelves = try await combined.shelves(lastUpdate: session.library.progress.lastUpdate, limit: 20)
            recentEpisodes = await episodes?.value ?? recentEpisodes
            if let items = await progress {
                episodesInProgress = items.filter { $0.isPodcast && $0.recentEpisode != nil }
            }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = LibraryStore.message(error)
            if AddressSelection.isConnectionError(error) { model.connectionTroubled() }
        }
    }

    /// „Słuchaj dalej”: książki i odcinki razem (`ContinueListening`).
    func continueListening(session: ServerSession, limit: Int = 20) -> ContinueListening.Result {
        ContinueListening.merge(books: shelves?.continueListening ?? [], serverEpisodes: episodesInProgress,
                                local: session.library.podcasts.localEpisodes.inProgress,
                                lastUpdate: session.library.progress.lastUpdateByKey, limit: limit)
    }
}

/// Półki Startu, do których prowadzi „Zobacz wszystko”.
enum HomeShelf: String, Hashable {
    case continueListening, continueSeries, newEpisodes, recentlyAdded, discover, listenAgain, recentSeries, newestAuthors

    var title: String {
        switch self {
        case .continueListening: "Słuchaj dalej"
        case .continueSeries: "Kolejne w serii"
        case .newEpisodes: "Nowe odcinki"
        case .recentlyAdded: "Ostatnio dodane"
        case .discover: "Odkrywaj"
        case .listenAgain: "Słuchaj ponownie"
        case .recentSeries: "Ostatnie serie"
        case .newestAuthors: "Nowi autorzy"
        }
    }
}

/// Zakładka „Start”: jedna półka „Słuchaj dalej” (książki i odcinki razem), dalej półki poziome
/// ze wszystkich bibliotek; bez sieci na górze to, co jest na telefonie.
struct HomeView: View {
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
                    ShelvesSkeleton()
                case .failed(let message):
                    OfflineFallback(model: model, session: session, message: message) { Task { await session.library.load() } }
                case .ready(let combined):
                    HomeContent(combined: combined, model: model, session: session)
                }
            }
            .navigationTitle("Start")
            .browseDestinations(model: model, session: session)
        }
    }
}

private struct HomeContent: View {
    let combined: CombinedLibraries
    let model: AppModel
    let session: ServerSession
    @State private var playError: String?

    private var feed: HomeFeed { session.home }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if model.isOffline {
                    OfflineBanner()
                    DownloadedShelf(model: model, session: session)
                }
                if let shelves = feed.shelves {
                    FailureNotice(failures: shelves.failures).padding(.horizontal, Design.margin)
                    ContinueShelf(model: model, session: session) { playError = $0 }
                    bookShelf(.continueSeries, shelves.continueSeries)
                    if !feed.recentEpisodes.isEmpty {
                        EpisodeColumnsShelf(title: HomeShelf.newEpisodes.title, destination: .shelf(.newEpisodes),
                                            episodes: feed.recentEpisodes, model: model, session: session)
                    }
                    bookShelf(.recentlyAdded, shelves.recentlyAdded)
                    bookShelf(.listenAgain, shelves.listenAgain)
                    Shelf(title: HomeShelf.recentSeries.title, destination: .shelf(.recentSeries), items: shelves.recentSeries) { series in
                        SeriesCard(series: series, session: session)
                    }
                    bookShelf(.discover, shelves.discover)
                    Shelf(title: HomeShelf.newestAuthors.title, destination: .shelf(.newestAuthors), width: .round, items: shelves.newestAuthors) { author in
                        AuthorCard(author: author, session: session)
                    }
                    if !model.isOffline {
                        DownloadedShelf(model: model, session: session)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .overlay {
            if let shelves = feed.shelves, shelves.isEmpty, feed.recentEpisodes.isEmpty, feed.continueListening(session: session).entries.isEmpty {
                EmptyState(title: "Pusto", systemImage: "books.vertical",
                           message: combined.libraries.isEmpty ? "Na serwerze nie ma bibliotek książek dostępnych dla tego konta." : "W bibliotekach nie ma jeszcze książek.")
            } else if feed.shelves == nil {
                if let error = feed.error {
                    OfflineFallback(model: model, session: session, message: error) { Task { await feed.load(combined, session: session, model: model) } }
                } else {
                    ShelvesSkeleton()
                }
            }
        }
        .alert("Nie udało się odtworzyć", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text((playError ?? "") + " Na stronie podcastu możesz zlecić pobranie na serwer.")
        }
        .refreshable {
            await model.reconnect()
            await session.library.refreshProgress()
            await feed.load(combined, session: session, model: model)
        }
        // Po zdarzeniach serwera (nowe pozycje, wczytany od nowa postęp) i po włączeniu innej książki.
        // Nie po każdej synchronizacji postępu (co 15 s) — paski postępu odświeżają się same.
        .task(id: Trigger(items: session.library.itemsRevision, progress: session.library.progressRevision, playing: model.playback.nowPlayingKey)) {
            await feed.load(combined, session: session, model: model)
        }
    }

    private struct Trigger: Hashable {
        let items: Int
        let progress: Int
        let playing: String?
    }

    private func bookShelf(_ shelf: HomeShelf, _ items: [Client.LibraryItem]) -> some View {
        Shelf(title: shelf.title, destination: .shelf(shelf), items: items) { item in
            BookCard(item: item, session: session, libraryName: combined.hasSeveralLibraries ? combined.libraryName(item.libraryId) : nil)
        }
    }
}

/// „Brak połączenia” na górze Startu.
private struct OfflineBanner: View {
    var body: some View {
        Label("Brak połączenia z serwerem. Telefon spróbuje ponownie po zmianie sieci — do tego czasu słuchasz tego, co pobrane.", systemImage: "wifi.slash")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Design.margin)
    }
}

// MARK: - Słuchaj dalej

/// Jedna półka z książkami i odcinkami, od ostatnio słuchanych.
private struct ContinueShelf: View {
    let model: AppModel
    let session: ServerSession
    let failed: (String) -> Void

    var body: some View {
        let result = session.home.continueListening(session: session)
        Shelf(title: HomeShelf.continueListening.title, destination: result.entries.count > 3 ? .shelf(.continueListening) : nil,
              width: .wide, items: result.entries) { entry in
            ContinueCard(entry: entry, model: model, session: session, failed: failed)
        }
        // Pewnie rozpoznane wpisy lokalne — ich postęp trafia na serwer.
        .task(id: result.handover.map(\.id)) {
            if !result.handover.isEmpty { session.library.podcasts.handOver(result.handover) }
        }
    }
}

/// Duża karta „Słuchaj dalej”: okładka, rodzaj, tytuł, autor albo podcast, postęp z pozostałym
/// czasem i przycisk odtwarzania. Dotknięcie karty otwiera pozycję.
struct ContinueCard: View {
    let entry: ContinueListening.Entry
    let model: AppModel
    let session: ServerSession
    let failed: (String) -> Void
    @State private var downloadError: String?
    @ScaledMetric(relativeTo: .body) private var coverSide: CGFloat = 92

    var body: some View {
        let info = Info(entry)
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: Route.item(info.itemID)) {
                HStack(alignment: .top, spacing: 14) {
                    ItemCover(itemID: info.itemID, session: session, points: 120, isPodcast: info.isEpisode, shadow: false)
                        .frame(width: min(coverSide, 130))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(info.kicker)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .lineLimit(1)
                        Text(info.title)
                            .font(.headline)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        if let subtitle = info.subtitle {
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text([info.kicker, info.title, info.subtitle].compactMap(\.self).joined(separator: ", ")))
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                PlayControl(entry: entry, model: model, session: session, failed: failed)
                CardProgressLine(entry: entry, session: session)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Design.cardRadius, style: .continuous))
        .contextMenu {
            if let target = info.download {
                DownloadMenuItems(target: target, session: session) { downloadError = $0 }
            }
        }
        .alert("Nie udało się pobrać", isPresented: Binding(get: { downloadError != nil }, set: { if !$0 { downloadError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
    }

    /// Co pokazać dla wpisu.
    struct Info {
        let itemID: String
        let title: String
        let subtitle: String?
        let kicker: String
        let isEpisode: Bool
        let download: DownloadTarget?

        init(_ entry: ContinueListening.Entry) {
            switch entry.kind {
            case .book(let item):
                itemID = item.id
                title = item.title
                subtitle = item.author
                kicker = "Audiobook"
                isEpisode = false
                download = .book(itemID: item.id)
            case .serverEpisode(let item, let episode, _):
                itemID = item.id
                title = episode.title ?? "Odcinek"
                subtitle = item.title
                kicker = episode.published.map { "Odcinek · " + $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "Odcinek"
                isEpisode = true
                download = .episode(episode, itemID: item.id, podcastTitle: item.title, libraryID: item.libraryId)
            case .localEpisode(let record):
                itemID = record.itemID
                title = record.title
                subtitle = record.podcastTitle
                kicker = "Ze strumienia · postęp na telefonie"
                isEpisode = true
                download = nil
            }
        }
    }
}

/// Przycisk odtwarzania karty — obserwuje tylko stan odtwarzacza.
private struct PlayControl: View {
    let entry: ContinueListening.Entry
    let model: AppModel
    let session: ServerSession
    let failed: (String) -> Void

    var body: some View {
        let playback = model.playback
        let keys = Self.keys(entry)
        CirclePlayButton(isCurrent: !playback.nowPlayingKeys.isDisjoint(with: keys), isPlaying: playback.player.isPlaying,
                         isStarting: playback.startingKey.map(keys.contains) ?? false) {
            Task { await play() }
        }
    }

    static func keys(_ entry: ContinueListening.Entry) -> Set<String> {
        switch entry.kind {
        case .book(let item): [item.id]
        case .serverEpisode(let item, let episode, let weak):
            Set([PlaybackTimeline.key(item.id, episode.id)] + (weak.map { [PlaybackTimeline.feedKey(item.id, $0.feedKey)] } ?? []))
        case .localEpisode(let record): [PlaybackTimeline.feedKey(record.itemID, record.feedKey)]
        }
    }

    private func play() async {
        switch entry.kind {
        case .book(let item):
            await model.playback.play(itemID: item.id)
        case .serverEpisode(let item, let episode, let weak):
            await session.library.podcasts.play(itemID: item.id, episode: episode, weakLocal: weak)
        case .localEpisode(let record):
            let key = PlaybackTimeline.feedKey(record.itemID, record.feedKey)
            await model.playback.play(external: .init(
                itemID: record.itemID, feedKey: record.feedKey, title: record.title, podcastTitle: record.podcastTitle,
                guid: record.guid, enclosureURL: record.enclosureURL, published: record.published, feedDuration: record.duration))
            if let error = model.playback.loadError, !model.playback.nowPlayingKeys.contains(key) { failed(error) }
        }
    }
}

/// Pasek postępu z pozostałym czasem — obserwuje tylko postęp tej pozycji.
private struct CardProgressLine: View {
    let entry: ContinueListening.Entry
    let session: ServerSession

    var body: some View {
        let (fraction, text) = values
        VStack(alignment: .leading, spacing: 4) {
            ProgressCapsule(fraction: fraction)
            if let text {
                Text(text).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Przesłuchane \(Int((fraction * 100).rounded())) procent\(text.map { ", " + $0 } ?? "")"))
    }

    private var values: (Double, String?) {
        switch entry.kind {
        case .book(let item):
            let value = session.library.progress.entry(item.id).value
            return (value?.progress ?? 0, RemainingText.text(currentTime: value?.currentTime, duration: value?.duration ?? item.media.duration, isFinished: value?.isFinished ?? false))
        case .serverEpisode(let item, let episode, let weak):
            let value = session.library.progress.entry(PlaybackTimeline.key(item.id, episode.id)).value
            if let weak, (weak.updatedAt.timeIntervalSince1970 * 1000) > (value?.lastUpdate ?? 0) {
                return (weak.fraction, RemainingText.text(currentTime: weak.currentTime, duration: weak.duration, isFinished: weak.isFinished))
            }
            return (value?.progress ?? 0, RemainingText.text(currentTime: value?.currentTime, duration: value?.duration ?? episode.length, isFinished: value?.isFinished ?? false))
        case .localEpisode(let record):
            return (record.fraction, RemainingText.text(currentTime: record.currentTime, duration: record.duration, isFinished: record.isFinished))
        }
    }
}

// MARK: - Odcinki

/// Nowe odcinki w kolumnach po trzy (przewijane poziomo).
struct EpisodeColumnsShelf: View {
    let title: String
    var destination: Route? = nil
    let episodes: [Client.PodcastEpisode]
    let model: AppModel
    let session: ServerSession

    var body: some View {
        let columns = stride(from: 0, to: episodes.count, by: 3).map { start in
            EpisodeColumn(id: episodes[start].id, episodes: Array(episodes[start..<min(start + 3, episodes.count)]))
        }
        Shelf(title: title, destination: destination, width: .wide, items: columns) { column in
            VStack(spacing: 0) {
                ForEach(column.episodes) { episode in
                    if let itemID = episode.libraryItemId {
                        EpisodeListRow(itemID: itemID, episode: episode, podcastTitle: episode.podcast?.metadata?.title,
                                       model: model, session: session)
                        if episode.id != column.episodes.last?.id { Divider().padding(.leading, 68) }
                    }
                }
            }
        }
    }

    struct EpisodeColumn: Identifiable {
        let id: String
        let episodes: [Client.PodcastEpisode]
    }
}

/// Wiersz odcinka serwera: okładka podcastu, data, tytuł, długość albo postęp, odtwarzanie.
/// Ten sam w kolumnach Startu, na liście „Nowe odcinki” i w zakładce Podcasty.
struct EpisodeListRow: View {
    let itemID: String
    let episode: Client.PodcastEpisode
    let podcastTitle: String?
    let model: AppModel
    let session: ServerSession
    @State private var downloadError: String?
    @ScaledMetric(relativeTo: .body) private var coverSide: CGFloat = 56

    var body: some View {
        let key = PlaybackTimeline.key(itemID, episode.id)
        let playback = model.playback
        HStack(spacing: 12) {
            NavigationLink(value: Route.item(itemID)) {
                HStack(spacing: 12) {
                    ItemCover(itemID: itemID, session: session, points: 60, isPodcast: true)
                        .frame(width: min(coverSide, 80))
                    VStack(alignment: .leading, spacing: 2) {
                        Text([episode.published.map { $0.formatted(.dateTime.day().month(.abbreviated)) }, podcastTitle].compactMap(\.self).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(episode.title ?? "Odcinek").font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                        EpisodeProgressCaption(entry: session.library.progress.entry(key), duration: episode.length)
                    }
                    Spacer(minLength: 0)
                    DownloadEntryBadge(entry: session.downloads.manager.entry(itemID: itemID, episodeID: episode.id))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            CirclePlayButton(isCurrent: playback.nowPlayingKeys.contains(key), isPlaying: playback.player.isPlaying,
                             isStarting: playback.startingKey == key) {
                Task { await playback.play(itemID: itemID, episodeID: episode.id) }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 8)
        .contextMenu {
            DownloadMenuItems(target: .episode(episode, itemID: itemID, podcastTitle: podcastTitle, libraryID: nil), session: session) { downloadError = $0 }
        }
        .alert("Nie udało się pobrać", isPresented: Binding(get: { downloadError != nil }, set: { if !$0 { downloadError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
    }
}

/// „12 min” albo „Zostało 3 min” z paskiem — obserwuje tylko postęp odcinka.
struct EpisodeProgressCaption: View {
    let entry: ProgressStore.Entry
    let duration: Double?

    var body: some View {
        let value = entry.value
        HStack(spacing: 6) {
            if value?.isFinished == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary).accessibilityHidden(true)
            } else if let fraction = entry.fraction, fraction > 0 {
                ProgressCapsule(fraction: fraction, height: 3).frame(width: 36)
            }
            if let text = RemainingText.text(currentTime: value?.currentTime, duration: value?.duration ?? duration, isFinished: value?.isFinished ?? false) {
                Text(text)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

// MARK: - Serie, autorzy, pobrane

/// Karta serii: okładki pierwszych tomów jedna za drugą, nazwa i liczba książek.
struct SeriesCard: View {
    let series: MergedEntity<Client.Series>
    let session: ServerSession

    var body: some View {
        let books = series.members.flatMap(\.value.items)
        NavigationLink(value: Route.series(series)) {
            VStack(alignment: .leading, spacing: 6) {
                // Kolejne tomy wystają spod pierwszego jak stos — ciemniejsze i mniejsze.
                ZStack(alignment: .bottom) {
                    ForEach(Array(books.prefix(3).enumerated().reversed()), id: \.element.id) { index, book in
                        ItemCover(itemID: book.id, session: session, points: 180, shadow: index == 0)
                            .scaleEffect(1 - CGFloat(index) * 0.08, anchor: .top)
                            .offset(y: CGFloat(index) * -7)
                            .brightness(index == 0 ? 0 : -0.12 * Double(index))
                    }
                    if books.isEmpty { CoverPlaceholder().aspectRatio(1, contentMode: .fit).coverStyle() }
                }
                .padding(.top, min(CGFloat(books.count - 1), 2) * 7)
                Text(series.first.name).font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                if !books.isEmpty {
                    Text(PolishCount.books(books.count)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Seria \(series.first.name), \(PolishCount.books(books.count))"))
        }
        .buttonStyle(.plain)
    }
}

/// Okrągłe zdjęcie autora z nazwą.
struct AuthorCard: View {
    let author: MergedEntity<Client.Author>
    let session: ServerSession
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        NavigationLink(value: Route.author(author)) {
            VStack(spacing: 6) {
                Circle()
                    .fill(.quaternary)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Text(Self.initials(author.first.name)).font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .clipShape(.circle)
                Text(author.first.name).font(.subheadline).lineLimit(2).multilineTextAlignment(.center)
            }
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Autor \(author.first.name)"))
        }
        .buttonStyle(.plain)
        .task(id: author.id) {
            guard let member = author.members.first(where: { $0.value.imagePath != nil }) else { return }
            let pixels = Int(120 * displayScale)
            if let data = try? await session.auth.perform({ try await $0.authorImage(id: member.value.id, width: pixels, token: $1) }) {
                image = UIImage(data: data)
            }
        }
    }

    static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// Pobrane na telefon jako półka okładek (bez sieci — na górze Startu).
private struct DownloadedShelf: View {
    let model: AppModel
    let session: ServerSession

    var body: some View {
        let items = session.downloads.manager.items(scope: session.scope)
        let active = items.count { !$0.isComplete }
        Shelf(title: "Pobrane na telefon", subtitle: active > 0 ? "Pobieranie: \(active)" : nil, destination: .downloads, items: items.prefix(15)) { item in
            Button {
                Task { await model.playback.play(itemID: item.itemID, episodeID: item.episodeID) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    ItemCover(itemID: item.itemID, session: session, isPodcast: item.isEpisode)
                        .overlay(alignment: .topTrailing) {
                            DownloadEntryBadge(entry: session.downloads.manager.entry(itemID: item.itemID, episodeID: item.episodeID))
                                .padding(4)
                                .background(.regularMaterial, in: .circle)
                                .padding(6)
                        }
                    Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                    if let author = item.author { Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Odtwarza z telefonu"))
        }
    }
}
