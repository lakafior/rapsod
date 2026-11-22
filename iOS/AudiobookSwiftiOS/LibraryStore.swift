// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import OSLog
import AudiobookshelfKit
import AudiobookshelfPlayback

private let logger = Logger(subsystem: "net.smigi.abswift.ios", category: "Library")

/// Biblioteki serwera połączone w jedną (`CombinedLibraries` z pakietu), postęp słuchania
/// i zdarzenia serwera na żywo. Jedna na połączenie (`ServerSession`).
@MainActor
@Observable
final class LibraryStore {
    enum State {
        case loading
        case ready(CombinedLibraries)
        case failed(String)
    }

    private(set) var state: State = .loading
    /// Rośnie, gdy serwer zgłosi dodane/zmienione/usunięte pozycje — półki i listy mogą się odświeżyć.
    private(set) var itemsRevision = 0
    /// Rośnie po wczytaniu postępu z serwera (np. po powrocie połączenia).
    private(set) var progressRevision = 0
    @ObservationIgnored let progress: ProgressStore
    /// Podcasty: uprawnienia, kolejka pobierania serwera, przekazanie lokalnego postępu (etap 10e).
    @ObservationIgnored let podcasts: PodcastStore
    @ObservationIgnored private let auth: ListeningAuth
    @ObservationIgnored private let journal: ProgressJournal
    @ObservationIgnored private let downloads: DownloadsController
    @ObservationIgnored private let playback: PlaybackCoordinator
    @ObservationIgnored private var events: ListeningEvents?
    @ObservationIgnored private var itemsChange: Task<Void, Never>?

    init(auth: ListeningAuth, playback: PlaybackCoordinator, journal: ProgressJournal, feeds: PodcastFeedLoader, downloads: DownloadsController) {
        self.auth = auth
        self.journal = journal
        self.downloads = downloads
        self.playback = playback
        let progress = ProgressStore()
        self.progress = progress
        podcasts = PodcastStore(auth: auth, playback: playback, progress: progress, localEpisodes: journal, feeds: feeds)
        podcasts.onProgressSent = { [weak self] in await self?.refreshProgress() }
    }

    var combined: CombinedLibraries? {
        if case .ready(let combined) = state { return combined }
        return nil
    }

    /// Działa, dopóki trwa zadanie wołającego (widok z `.task`): wczytuje biblioteki i postęp,
    /// słucha zdarzeń serwera, a po anulowaniu zamyka gniazdo.
    func run() async {
        startEvents()
        await load()
        await withTaskCancellationHandler {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stopEvents() }
        }
    }

    func load() async {
        if case .failed = state { state = .loading }
        do {
            let combined = try await CombinedLibraries.load(auth: auth)
            // Postęp przed pokazaniem list: „Ostatnio słuchane” bierze z niego kolejność.
            await refreshProgress()
            state = .ready(combined)
            if !combined.podcastLibraries.isEmpty {
                Task {
                    await podcasts.loadQueue(libraries: combined.podcastLibraries)
                    await podcasts.reconcileAll()
                }
            }
        } catch is CancellationError {
            return
        } catch {
            logger.error("Biblioteki: \(error.localizedDescription, privacy: .public)")
            if combined == nil { state = .failed(Self.message(error)) }
            await refreshProgress()
        }
    }

    /// Postęp konta z `GET /api/me` (ten sam, który widzi Mac i web UI).
    func refreshProgress() async {
        guard let me: AudiobookshelfClient.MeState = try? await auth.perform({ try await $0.me(token: $1) }) else { return }
        progress.replaceAll(me.mediaProgress.elements)
        podcasts.setAccount(me)
        rememberDownloadedProgress(me.mediaProgress.elements)
        progressRevision += 1
    }

    /// Postęp pobranych pozycji trafia do dziennika — bez sieci start i paski postępu biorą go stamtąd.
    private func rememberDownloadedProgress(_ list: [AudiobookshelfClient.MediaProgress]) {
        for entry in list {
            guard let itemID = entry.libraryItemId, downloads.manager.item(itemID: itemID, episodeID: entry.episodeId) != nil else { continue }
            journal.recordServer(entry)
            // „Usuwaj po wysłuchaniu”: ukończone znika z telefonu — ale nie to, co właśnie gra
            // (po ukończeniu odtwarzacz zostaje na początku i można słuchać od nowa).
            let key = PlaybackTimeline.key(itemID, entry.episodeId)
            if entry.isFinished, UserDefaults.standard.bool(forKey: DownloadsController.removeFinishedKey), !playback.nowPlayingKeys.contains(key) {
                downloads.manager.remove(key: ProgressJournal.key(itemID, entry.episodeId))
            }
        }
    }

    static func message(_ error: any Error) -> String {
        if case AudiobookshelfClient.APIError.unauthorized = error {
            return Connector.ConnectError.keyRejected.localizedDescription
        }
        return error.localizedDescription
    }

    // MARK: Zdarzenia serwera

    private func startEvents() {
        guard events == nil else { return }
        let auth = auth
        let events = ListeningEvents(baseURL: auth.baseURL, token: { _ in try await auth.token() }) { [weak self] event in
            self?.handle(event)
        }
        self.events = events
        events.start()
    }

    private func stopEvents() {
        events?.stop()
        events = nil
        itemsChange?.cancel()
    }

    private func handle(_ event: ListeningEvents.Event) {
        switch event {
        case .progress(let entry):
            progress.update(entry)
            rememberDownloadedProgress([entry])
        case .user(let me):
            progress.replaceAll(me.mediaProgress.elements)
            podcasts.setAccount(me)
            rememberDownloadedProgress(me.mediaProgress.elements)
        case .itemsChanged(let libraries, let items):
            if let combined, libraries.contains(where: { id in combined.podcastLibraries.contains { $0.id == id } }) {
                for item in items { podcasts.itemChanged(item) }
            }
            guard combined.map({ store in libraries.contains { id in store.libraries.contains { $0.id == id } } }) ?? false else { return }
            // Skan dodaje pozycje seriami — jedno odświeżenie po chwili ciszy.
            itemsChange?.cancel()
            itemsChange = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                itemsRevision += 1
            }
        case .episodeDownload(let download, let phase):
            podcasts.apply(download, phase)
        case .downloadQueueCleared(let itemID):
            podcasts.cleared(itemID: itemID)
        case .reconnected:
            Task {
                await refreshProgress()
                if let combined, !combined.podcastLibraries.isEmpty {
                    await podcasts.loadQueue(libraries: combined.podcastLibraries)
                    await podcasts.reconcileAll()
                }
            }
        default:
            break
        }
    }
}

/// Postęp pozycji z wąską obserwacją: każda pozycja ma własny obiekt, więc zmiana postępu
/// jednej książki (synchronizacja co kilkanaście sekund w trakcie słuchania) przerysowuje
/// tylko jej kartę, a nie całą siatkę.
@MainActor
final class ProgressStore {
    @MainActor
    @Observable
    final class Entry {
        fileprivate(set) var value: AudiobookshelfClient.MediaProgress?

        init(_ value: AudiobookshelfClient.MediaProgress?) { self.value = value }

        /// 0…1 albo `nil`, gdy pozycji nie zaczęto.
        var fraction: Double? {
            guard let value else { return nil }
            if value.isFinished { return 1 }
            guard let progress = value.progress, progress > 0 else { return nil }
            return min(1, progress)
        }
    }

    private var entries: [String: Entry] = [:]
    private var values: [String: AudiobookshelfClient.MediaProgress] = [:]

    /// Obiekt postępu książki (tworzony przy pierwszym pytaniu; odczyt `value` w widoku go obserwuje).
    func entry(_ itemID: String) -> Entry {
        if let entry = entries[itemID] { return entry }
        let entry = Entry(values[itemID])
        entries[itemID] = entry
        return entry
    }

    func value(_ itemID: String) -> AudiobookshelfClient.MediaProgress? { values[itemID] }

    /// Czas ostatniego słuchania (ms) — do sortowania „Ostatnio słuchane” i półki „Słuchaj dalej”.
    /// Tylko pozycje (bez odcinków podcastów).
    var lastUpdate: [String: Double] { values.filter { $0.value.episodeId == nil }.mapValues(\.lastUpdate) }
    /// Czas ostatniego słuchania pozycji i odcinków (klucz jak `PlaybackTimeline.key`).
    var lastUpdateByKey: [String: Double] { values.mapValues(\.lastUpdate) }

    /// Książki pod identyfikatorem pozycji, odcinki — pod `PlaybackTimeline.key(pozycja, odcinek)`.
    private static func key(_ entry: AudiobookshelfClient.MediaProgress) -> String? {
        entry.libraryItemId.map { PlaybackTimeline.key($0, entry.episodeId) }
    }

    func replaceAll(_ list: [AudiobookshelfClient.MediaProgress]) {
        var fresh: [String: AudiobookshelfClient.MediaProgress] = [:]
        for entry in list {
            guard let id = Self.key(entry) else { continue }
            fresh[id] = entry
        }
        let removed = Set(values.keys).subtracting(fresh.keys)
        values = fresh
        for id in removed { set(id, nil) }
        for (id, entry) in fresh { set(id, entry) }
    }

    func update(_ entry: AudiobookshelfClient.MediaProgress) {
        guard let id = Self.key(entry) else { return }
        values[id] = entry
        set(id, entry)
    }

    func remove(_ itemID: String) {
        values[itemID] = nil
        set(itemID, nil)
    }

    private func set(_ id: String, _ value: AudiobookshelfClient.MediaProgress?) {
        // Przypisanie tylko przy zmianie — inaczej obserwujący widok i tak by się przerysował.
        guard let entry = entries[id], entry.value != value else { return }
        entry.value = value
    }
}
