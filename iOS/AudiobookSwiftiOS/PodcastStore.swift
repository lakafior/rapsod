// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import OSLog
import AudiobookshelfKit
import AudiobookshelfPlayback

private let logger = Logger(subsystem: "net.smigi.abswift.ios", category: "Podcasts")

/// Podcasty jednego połączenia (etap 10e): uprawnienia konta do zlecania pobrań, kolejka
/// pobierania serwera na żywo, zlecanie pobrań i przekazanie postępu odcinków słuchanych ze
/// strumienia, gdy serwer je pobierze.
@MainActor
@Observable
final class PodcastStore {
    enum Permission: Equatable {
        /// Jeszcze nie wiadomo (przed pierwszym `/api/me`).
        case unknown
        /// Administrator z „Edycją pozycji”: może zlecać pobrania.
        case admin
        /// Zwykły słuchacz — serwer odrzuci zlecenie (403).
        case listener
        /// Administrator bez „Edycji pozycji”: serwer też odrzuci zlecenie (sprawdza oba).
        case needsEditPermission

        var canOrder: Bool { self == .admin || self == .unknown }
    }

    /// Stan odcinka w kolejce serwera.
    enum DownloadState: Equatable {
        case downloading
        case queued
        case failed
    }

    private(set) var permission: Permission = .unknown
    /// Bieżące pobieranie każdej biblioteki i oczekujące w kolejce (`episode-downloads`).
    private(set) var current: [String: Client.EpisodeDownload] = [:]
    private(set) var queued: [Client.EpisodeDownload] = []
    /// Nieudane pobrania od uruchomienia (serwer o nich nie pamięta).
    private(set) var failed: [Client.EpisodeDownload] = []
    /// Zlecone z telefonu, zanim pojawiły się w kolejce: klucz odcinka → kiedy.
    private(set) var requested: [String: Date] = [:]
    /// Rośnie, gdy pozycja podcastu zmieniła się na serwerze (np. doszedł pobrany odcinek).
    private(set) var revision: [String: Int] = [:]

    let localEpisodes: LocalEpisodeStore
    let feeds: PodcastFeedLoader
    @ObservationIgnored private let auth: ListeningAuth
    @ObservationIgnored private let playback: PlaybackCoordinator
    @ObservationIgnored private let progress: ProgressStore
    /// Kanał w postaci serwera (do zlecenia pobrania), na kilka minut.
    @ObservationIgnored private var serverFeeds: [String: (date: Date, episodes: [Client.FeedEpisode])] = [:]
    @ObservationIgnored var onProgressSent: (@MainActor () async -> Void)?

    init(auth: ListeningAuth, playback: PlaybackCoordinator, progress: ProgressStore, localEpisodes: LocalEpisodeStore, feeds: PodcastFeedLoader) {
        self.auth = auth
        self.playback = playback
        self.progress = progress
        self.localEpisodes = localEpisodes
        self.feeds = feeds
    }

    static func requestKey(itemID: String, feedKey: String) -> String { LocalEpisodeRecord.id(itemID: itemID, feedKey: feedKey) }

    func setAccount(_ me: Client.MeState) {
        guard me.type != nil else { return }
        let value: Permission = me.canOrderEpisodeDownloads ? .admin : (me.isAdmin ? .needsEditPermission : .listener)
        if permission != value { permission = value }
    }

    // MARK: Kolejka serwera

    /// Kolejka pobierania wszystkich bibliotek podcastów (zwykły słuchacz też może ją czytać).
    func loadQueue(libraries: [Client.Library]) async {
        var currents: [String: Client.EpisodeDownload] = [:]
        var waiting: [Client.EpisodeDownload] = []
        for library in libraries {
            guard let queue = try? await auth.perform({ try await $0.episodeDownloadQueue(libraryID: library.id, token: $1) }) else { continue }
            if let download = queue.currentDownload { currents[library.id] = download }
            waiting += queue.queue?.elements ?? []
        }
        current = currents
        queued = waiting
        pruneRequested()
    }

    func apply(_ download: Client.EpisodeDownload, _ phase: Client.EpisodeDownloadPhase) {
        let library = download.libraryId ?? ""
        switch phase {
        case .queued:
            if !queued.contains(where: { $0.id == download.id }) { queued.append(download) }
        case .started:
            queued.removeAll { $0.id == download.id }
            current[library] = download
        case .finished:
            queued.removeAll { $0.id == download.id }
            if current[library]?.id == download.id { current[library] = nil }
            if download.failed == true {
                failed.append(download)
            } else {
                // Odcinek doszedł na serwer — strona podcastu przeładuje pozycję.
                bump(download.libraryItemId)
            }
        }
        pruneRequested()
    }

    func cleared(itemID: String) {
        queued.removeAll { $0.libraryItemId == itemID }
        requested = requested.filter { !$0.key.hasPrefix(itemID + "\u{1F}") }
    }

    /// Pozycja podcastu zmieniła się na serwerze.
    func itemChanged(_ itemID: String) {
        bump(itemID)
        // Odcinek słuchany ze strumienia mógł właśnie dojść na serwer — także poza jego stroną.
        guard !localEpisodes.records(itemID: itemID).isEmpty else { return }
        Task {
            guard let item = try? await auth.perform({ try await $0.item(id: itemID, token: $1) }) else { return }
            await reconcile(item)
        }
    }

    private func bump(_ itemID: String) {
        revision[itemID, default: 0] += 1
    }

    /// Stan odcinka w kolejce: najpierw pobierany, potem oczekujący, zlecony, nieudany.
    func downloadState(itemID: String, identity: EpisodeIdentity, feedKey: String?) -> DownloadState? {
        if current.values.contains(where: { $0.libraryItemId == itemID && EpisodeMatching.isSame($0, as: identity) }) { return .downloading }
        if queued.contains(where: { $0.libraryItemId == itemID && EpisodeMatching.isSame($0, as: identity) }) { return .queued }
        // Nieudane przed „zleconym”: ponowne zlecenie usuwa wpis nieudanego.
        if failed.contains(where: { $0.libraryItemId == itemID && EpisodeMatching.isSame($0, as: identity) }) { return .failed }
        if let feedKey, requested[Self.requestKey(itemID: itemID, feedKey: feedKey)] != nil { return .queued }
        return nil
    }

    /// Odcinek w tym stanie można (ponownie) zlecić do pobrania.
    nonisolated static func canRequest(_ state: DownloadState?) -> Bool { state == nil || state == .failed }

    /// Zlecenia, które serwer już widzi (albo sprzed 2 minut — mogły przepaść), nie są „zlecone”.
    private func pruneRequested() {
        guard !requested.isEmpty else { return }
        requested = requested.filter { Date.now.timeIntervalSince($0.value) < 120 }
    }

    // MARK: Zlecanie pobrań

    enum OrderError: LocalizedError {
        case notAllowed(Permission)
        case noFeedURL
        case notInServerFeed(Int)
        /// Serwer nie pobrał kanału (wydawca nie odpowiada, a adresy lokalne serwer blokuje).
        case serverFeedUnavailable

        var errorDescription: String? {
            switch self {
            case .notAllowed(let permission): PodcastStore.permissionHelp(permission)
            case .noFeedURL: "Ten podcast nie ma na serwerze adresu kanału RSS."
            case .serverFeedUnavailable: "Serwer nie mógł pobrać kanału RSS tego podcastu (wydawca nie odpowiada albo serwer nie łączy się z tym adresem). Spróbuj ponownie później."
            case .notInServerFeed(let count):
                count == 1 ? "Serwer nie widzi tego odcinka w kanale (wydawca mógł go zmienić albo usunąć). Odśwież listę i spróbuj ponownie."
                    : "Serwer nie widzi \(count) z wybranych odcinków w kanale. Odśwież listę i spróbuj ponownie."
            }
        }
    }

    /// Co włączyć na Macu, żeby telefon mógł zlecać pobrania.
    nonisolated static func permissionHelp(_ permission: Permission) -> String {
        if permission == .needsEditPermission {
            return "Konto tego telefonu ma uprawnienia administratora, ale serwer wymaga też „Edycji pozycji”. Na Macu: Ustawienia AudiobookSwift → Udostępnianie → Aplikacja AudiobookSwift na telefonie → Uprawnienia administratora → „Nadaj…” (włącza oba) albo Ustawienia → Użytkownicy → konto telefonu → „Edycja pozycji”."
        }
        return "Pobieranie na serwer wymaga uprawnień administratora dla konta tego telefonu. Na Macu: Ustawienia AudiobookSwift → Udostępnianie → Aplikacja AudiobookSwift na telefonie → Uprawnienia administratora → „Nadaj…”."
    }

    /// Zleca serwerowi pobranie odcinków z kanału. Serwer dostaje odcinki w postaci z własnego
    /// odczytu kanału (dopasowane na pewno: guid albo adres), więc zapisze je tak, jak przy
    /// zwykłym „Pobierz” w web UI. Zwraca liczbę zleconych.
    @discardableResult
    func order(_ episodes: [RSSEpisode], item: Client.ItemDetail) async throws -> Int {
        guard permission.canOrder else { throw OrderError.notAllowed(permission) }
        guard let feedURL = item.media.metadata.feedUrl, !feedURL.isEmpty else { throw OrderError.noFeedURL }
        // Nieudane można zlecić ponownie; pobierane, w kolejce i właśnie zlecone — nie.
        let wanted = episodes.filter { episode in
            let state = downloadState(itemID: item.id, identity: EpisodeIdentity(episode), feedKey: episode.id)
            return state == nil || state == .failed
        }
        guard !wanted.isEmpty else { return 0 }
        var serverEpisodes: [Client.FeedEpisode]
        do {
            serverEpisodes = try await serverFeed(feedURL, itemID: item.id, force: false)
            if PodcastDownloadOrder.select(wanted, in: serverEpisodes).missing.isEmpty == false {
                // Serwer mógł mieć starszą wersję kanału w pamięci — raz od nowa.
                serverEpisodes = try await serverFeed(feedURL, itemID: item.id, force: true)
            }
        } catch AudiobookshelfClient.APIError.http(status: 403, _) {
            permission = .listener
            throw OrderError.notAllowed(.listener)
        } catch AudiobookshelfClient.APIError.http(status: 404, _) {
            throw OrderError.serverFeedUnavailable
        }
        var found: [Client.FeedEpisode] = []
        var keys: [String] = []
        var missing = 0
        for episode in wanted {
            if let match = PodcastDownloadOrder.select([episode], in: serverEpisodes).found.first {
                found.append(match)
                keys.append(Self.requestKey(itemID: item.id, feedKey: episode.id))
            } else {
                missing += 1
            }
        }
        if !found.isEmpty {
            do {
                try await auth.perform { try await $0.downloadEpisodes(itemID: item.id, found, token: $1) }
            } catch AudiobookshelfClient.APIError.http(status: 403, _) {
                // Kanał przez serwer przeszedł (to sprawdza sam typ konta), a pobranie nie — brak „Edycji pozycji”.
                permission = .needsEditPermission
                throw OrderError.notAllowed(.needsEditPermission)
            }
            if permission == .unknown { permission = .admin }
            for key in keys { requested[key] = .now }
            failed.removeAll { download in download.libraryItemId == item.id && found.contains { EpisodeMatching.isSame(download, as: $0.identity) } }
            logger.notice("Zlecono pobranie \(found.count) odcinków")
        }
        if missing > 0, found.isEmpty { throw OrderError.notInServerFeed(missing) }
        return found.count
    }

    private func serverFeed(_ url: String, itemID: String, force: Bool) async throws -> [Client.FeedEpisode] {
        if !force, let cached = serverFeeds[itemID], Date.now.timeIntervalSince(cached.date) < 300 { return cached.episodes }
        let feed = try await auth.perform { try await $0.podcastFeed(url: url, token: $1) }
        serverFeeds[itemID] = (.now, feed.episodes)
        return feed.episodes
    }

    // MARK: Przekazanie postępu

    /// Lokalny postęp odcinków, które są już na serwerze, trafia na serwer (nowszy zapis wygrywa).
    /// Bieżący odcinek przełącza sam koordynator — bez przerywania słuchania.
    func reconcile(_ item: Client.ItemDetail) async {
        let records = localEpisodes.records(itemID: item.id)
        guard !records.isEmpty else { return }
        let episodes = item.media.episodes?.elements ?? []
        var sent = false
        for record in records {
            guard let server = EpisodeHandover.serverEpisode(for: record, in: episodes) else { continue }
            if await playback.serverEpisodeAvailable(itemID: item.id, feedKey: record.feedKey, episodeID: server.id, serverDuration: server.length) { continue }
            let serverProgress = progress.value(PlaybackTimeline.key(item.id, server.id))
            switch EpisodeHandover.decide(record, serverLastUpdate: serverProgress?.lastUpdate, serverDuration: server.length) {
            case .discardLocal:
                localEpisodes.remove(itemID: item.id, feedKey: record.feedKey)
            case .send(let time, let duration, let finished):
                do {
                    try await auth.perform {
                        try await $0.updateProgress(itemID: item.id, episodeID: server.id, currentTime: time, duration: duration, isFinished: finished ? true : nil, token: $1)
                    }
                    // Wpis znika dopiero po udanym zapisie (bez sieci zostaje do następnej próby).
                    localEpisodes.remove(itemID: item.id, feedKey: record.feedKey)
                    sent = true
                    logger.notice("Lokalny postęp odcinka przekazany na serwer")
                } catch {
                    logger.error("Przekazanie postępu odcinka: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if sent { await onProgressSent?() }
    }

    /// Po starcie i po powrocie połączenia: podcasty z lokalnym postępem sprawdzone na serwerze.
    func reconcileAll() async {
        let itemIDs = Set(localEpisodes.records.values.map(\.itemID))
        for itemID in itemIDs {
            guard let item = try? await auth.perform({ try await $0.item(id: itemID, token: $1) }) else { continue }
            await reconcile(item)
        }
    }
}
