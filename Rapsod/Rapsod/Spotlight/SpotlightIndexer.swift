import AudiobookshelfKit
import CoreSpotlight
import Foundation
import Observation
import OSLog
import RapsodIntegration
import UniformTypeIdentifiers

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Rapsod", category: "Spotlight")

/// Książki, podcasty i odcinki z serwera w Spotlight (etap 14f).
///
/// Zwykłe `CSSearchableItem`, nie `IndexedEntity`: kopia testowa ma ten sam identyfikator pakietu,
/// więc dzieli indeks z prawdziwą aplikacją, a tylko własne domeny (`SpotlightKey`, zakres z folderu
/// danych) pozwalają usuwać swoje wpisy, nie dotykając cudzych. Indeks buduje konto słuchacza —
/// wynik otwiera się w jego oknie Biblioteka, więc pozycje widoczne tylko dla roota by nie działały.
///
/// Pierwsze połączenie: wszystko, w paczkach po `batchSize`, z zapisem manifestu po każdej (przerwane
/// indeksowanie wznawia się od miejsca przerwania). Potem przy każdym połączeniu przegląd list
/// bibliotek (skrócone strony po 500 pozycji) i tylko zmiany według `updatedAt`; w trakcie działania
/// zmiany ze stałego gniazda zdarzeń (`ServerActivityMonitor`) — przegląd biblioteki ze zdarzenia.
@MainActor
@Observable
final class SpotlightIndexer {
    static let enabledKey = "spotlight.enabled"
    static let batchSize = 100
    static let pageSize = 500
    static let coverWidth = 240

    enum Status: Equatable {
        case off
        case waiting
        case indexing(done: Int, total: Int)
        case ready(count: Int, date: Date)
        case failed(String)
    }

    private(set) var status: Status = .waiting
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            if !Self.isTestCopy || scopeOverride != nil { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
            onEnabledChanged?(isEnabled)
            if isEnabled { scheduleSync(after: .zero) } else { Task { await removeAll() } }
        }
    }
    /// Zmiana przełącznika — stałe gniazdo zdarzeń jest potrzebne także bez powiadomień.
    @ObservationIgnored var onEnabledChanged: ((Bool) -> Void)?

    @ObservationIgnored private let supervisor: ServerSupervisor
    @ObservationIgnored private let account: ServerAccount
    @ObservationIgnored private let listening: ListeningController
    @ObservationIgnored private let index: CSSearchableIndex
    @ObservationIgnored private var manifest = SpotlightManifest()
    @ObservationIgnored private var loadedScope: String?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var dirtyLibraries: Set<String>?
    /// Zaplanowany pełny przegląd nie ustępuje późniejszemu przeglądowi jednej biblioteki.
    @ObservationIgnored private var fullSyncPending = false
    /// Pozycje ze zdarzeń serwera — indeksowane ponownie bez względu na `updatedAt`.
    @ObservationIgnored private var forcedItems: Set<String> = []
    @ObservationIgnored private var watcher: Task<Void, Never>?
    /// Tryb sprawdzający: osobny zakres zamiast wyliczonego z folderu danych.
    @ObservationIgnored var scopeOverride: String?

    init(supervisor: ServerSupervisor, account: ServerAccount, listening: ListeningController,
         index: CSSearchableIndex = CSSearchableIndex(name: "Rapsod")) {
        self.supervisor = supervisor
        self.account = account
        self.listening = listening
        self.index = index
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        if !isEnabled { status = .off }
        if Self.isTestCopy { status = .failed("kopia testowa (-ABSDataRoot) nie dodaje pozycji do Spotlight.") }
    }

    /// Zakres wpisów tej kopii (folder danych); `nil`, dopóki serwer nie wystartował.
    var scope: String? {
        if let scopeOverride { return scopeOverride }
        // Kopia z `-ABSDataRoot` (testy, zrzuty) nie pisze do wspólnego indeksu — chyba że tryb
        // sprawdzający ustawi własny zakres.
        guard !Self.isTestCopy else { return nil }
        return supervisor.dataRoot.map { SpotlightKey.scope(dataRoot: $0.path) }
    }

    /// Kopia z innym folderem danych niż domyślny (`-ABSDataRoot`).
    static var isTestCopy: Bool { !(UserDefaults.standard.string(forKey: "ABSDataRoot") ?? "").isEmpty }

    private var manifestURL: URL? {
        supervisor.dataRoot?.appending(path: scopeOverride.map { "spotlight-index-\($0).json" } ?? "spotlight-index.json")
    }

    func activate() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            // Konto słuchacza gotowe albo zmiana list bibliotek: przegląd. Brak konta: czyszczenie.
            let changes = Observations { [weak self] in
                self.map { ($0.listening.availability, $0.listening.libraries.map(\.id), $0.listenerName) }
            }
            for await value in changes {
                guard let self, let (availability, _, listener) = value else { return }
                if availability == .ready, listener != nil {
                    scheduleSync(after: .seconds(2))
                } else if case .missing = account.userState {
                    await removeAll(keepEnabled: true)
                }
            }
        }
    }

    private var listenerName: String? {
        if case .ready(let username) = account.userState { return username }
        return nil
    }

    // MARK: Zdarzenia serwera

    func handle(_ event: ListeningEvents.Event) {
        guard isEnabled else { return }
        switch event {
        case .itemsChanged(let libraries, let items):
            dirtyLibraries = (dirtyLibraries ?? []).union(libraries)
            forcedItems.formUnion(items)
            scheduleSync(after: .seconds(5), libraries: dirtyLibraries)
        case .connected, .reconnected:
            // Zdarzenia z przerwy w połączeniu przepadły — pełny przegląd.
            scheduleSync(after: .seconds(5))
        default:
            break
        }
    }

    /// Kolejny przegląd po chwili ciszy (zdarzenia przychodzą seriami, np. przy skanie).
    func scheduleSync(after delay: Duration, libraries: Set<String>? = nil) {
        guard isEnabled else { return }
        if libraries == nil { fullSyncPending = true }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.running?.value
            guard !Task.isCancelled else { return }
            let only = self.fullSyncPending ? nil : self.dirtyLibraries
            self.fullSyncPending = false
            self.dirtyLibraries = nil
            let task = Task { await self.sync(libraries: only) }
            self.running = task
            await task.value
        }
    }

    // MARK: Przegląd

    /// Porównanie z serwerem i zmiany w indeksie. `libraries == nil` — wszystkie biblioteki konta.
    func sync(libraries only: Set<String>? = nil) async {
        guard isEnabled, listening.availability == .ready, let listener = listenerName, let scope else { return }
        loadManifest(scope: scope)
        if manifest.userID != listener {
            // Inne konto słuchacza widzi inne biblioteki: od zera.
            await deleteDomain(SpotlightKey.domain(scope: scope))
            manifest = SpotlightManifest(userID: listener)
            saveManifest()
        }
        let all = listening.libraries
        let listed = all.filter { only?.contains($0.id) ?? true }
        let started = Date.now
        do {
            var current: [SpotlightSource] = []
            var details: [String: AudiobookshelfClient.IndexItem] = [:]
            for library in listed {
                var page = 0
                while true {
                    let result = try await listening.api { try await $0.indexPage(libraryID: library.id, page: page, limit: Self.pageSize, token: $1) }
                    let elements = result.results.elements
                    for item in elements {
                        details[item.id] = item
                        current.append(SpotlightSource(itemID: item.id, libraryID: item.libraryId, kind: item.isPodcast ? .podcast : .book,
                                                       updatedAt: item.updatedAt ?? item.addedAt ?? 0))
                    }
                    page += 1
                    if elements.count < Self.pageSize || current.count >= (result.total ?? .max) { break }
                }
            }
            // Pozycje ze zdarzeń: serwer nie zawsze podbija `updatedAt` (np. nowe odcinki).
            var compared = manifest
            for id in forcedItems { compared.items[id]?.updatedAt = -1 }
            forcedItems = []
            let changes = SpotlightPlan.changes(manifest: compared, current: current, listed: Set(listed.map(\.id)), libraries: Set(all.map(\.id)))
            if changes.isEmpty {
                status = .ready(count: manifest.items.count, date: .now)
                logger.info("Spotlight: bez zmian (\(current.count) pozycji)")
                return
            }
            for libraryID in changes.removedLibraries {
                await deleteDomain(SpotlightKey.domain(scope: scope, libraryID: libraryID))
                manifest.items = manifest.items.filter { $0.value.libraryID != libraryID }
            }
            if !changes.removedItems.isEmpty {
                var identifiers: [String] = []
                for (id, entry) in changes.removedItems {
                    identifiers.append(SpotlightKey(scope: scope, kind: entry.kind, itemID: id).uniqueIdentifier)
                    identifiers += entry.episodes.map { SpotlightKey(scope: scope, kind: .episode, itemID: id, episodeID: $0).uniqueIdentifier }
                    manifest.items[id] = nil
                }
                try await index.deleteSearchableItems(withIdentifiers: identifiers)
            }
            saveManifest()
            let total = changes.toIndex.count
            var done = 0
            status = .indexing(done: 0, total: total)
            for batch in SpotlightPlan.batches(changes.toIndex, size: Self.batchSize) {
                try Task.checkCancellation()
                guard isEnabled else { return }
                try await indexBatch(batch.compactMap { details[$0.itemID] }, scope: scope)
                done += batch.count
                status = .indexing(done: done, total: total)
            }
            status = .ready(count: manifest.items.count, date: .now)
            logger.info("Spotlight: \(total) zindeksowanych, \(changes.removedItems.count) usuniętych, \(changes.removedLibraries.count) bibliotek usuniętych w \(Date.now.timeIntervalSince(started), format: .fixed(precision: 1)) s")
        } catch is CancellationError {
            saveManifest()
        } catch {
            saveManifest()
            status = .failed(error.localizedDescription)
            logger.error("Spotlight: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func indexBatch(_ items: [AudiobookshelfClient.IndexItem], scope: String) async throws {
        let covers = await fetchCovers(items.filter { $0.media.coverPath != nil }.map(\.id))
        coverStats.withCover += items.filter { $0.media.coverPath != nil }.count
        coverStats.fetched += covers.count
        var searchable: [CSSearchableItem] = []
        var entries: [String: SpotlightManifest.Entry] = [:]
        for item in items {
            let domain = SpotlightKey.domain(scope: scope, libraryID: item.libraryId)
            let kind: SpotlightKind = item.isPodcast ? .podcast : .book
            searchable.append(Self.searchableItem(item, kind: kind, scope: scope, domain: domain, cover: covers[item.id]))
            var entry = SpotlightManifest.Entry(libraryID: item.libraryId, kind: kind, updatedAt: item.updatedAt ?? item.addedAt ?? 0)
            if item.isPodcast {
                // Bez szczegółów (odcinków) pozycja nie trafia do manifestu — następny przegląd ją powtórzy.
                guard let detail = try? await listening.api({ try await $0.item(id: item.id, token: $1) }) else {
                    searchable.removeLast()
                    continue
                }
                let episodes = detail.media.episodes?.elements ?? []
                for episode in episodes {
                    searchable.append(Self.episodeItem(episode, podcast: item, scope: scope, domain: domain, cover: covers[item.id]))
                }
                entry.episodes = episodes.map(\.id)
                let removed = SpotlightPlan.removedEpisodes(old: manifest.items[item.id]?.episodes ?? [], new: entry.episodes)
                if !removed.isEmpty {
                    try await index.deleteSearchableItems(withIdentifiers: removed.map {
                        SpotlightKey(scope: scope, kind: .episode, itemID: item.id, episodeID: $0).uniqueIdentifier
                    })
                }
            }
            entries[item.id] = entry
        }
        try await index.indexSearchableItems(searchable)
        manifest.items.merge(entries) { _, new in new }
        saveManifest()
    }

    /// Małe okładki z serwera, po kilka naraz (serwer skaluje je sam).
    private func fetchCovers(_ ids: [String]) async -> [String: Data] {
        var result: [String: Data] = [:]
        for chunk in SpotlightPlan.batches(ids, size: 6) {
            await withTaskGroup(of: (String, Data?).self) { group in
                for id in chunk {
                    group.addTask { await (id, self.cover(id)) }
                }
                for await (id, data) in group { result[id] = data }
            }
        }
        return result
    }

    private func cover(_ id: String) async -> Data? {
        try? await listening.api { try await $0.cover(itemID: id, width: Self.coverWidth, token: $1) }
    }

    // MARK: Wpisy

    static func searchableItem(_ item: AudiobookshelfClient.IndexItem, kind: SpotlightKind, scope: String, domain: String, cover: Data?) -> CSSearchableItem {
        let metadata = item.media.metadata
        let attributes = CSSearchableItemAttributeSet(contentType: .audio)
        let title = metadata.title ?? "Bez tytułu"
        attributes.title = title
        attributes.displayName = title
        let author = metadata.authorName ?? metadata.author
        if let author { attributes.authorNames = author.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        attributes.artist = author
        if let narrators = metadata.narratorName, !narrators.isEmpty {
            attributes.performers = narrators.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        attributes.album = metadata.seriesName
        attributes.genre = metadata.genres?.first
        attributes.duration = item.media.duration.map { NSNumber(value: $0) }
        attributes.contentDescription = description(
            kind == .podcast ? "Podcast" : nil,
            [author, metadata.narratorName.map { "czyta \($0)" }, metadata.seriesName].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "),
            metadata.subtitle, HTMLText.plain(metadata.description))
        attributes.keywords = SpotlightPlan.keywords([author], [metadata.narratorName], [metadata.seriesName], metadata.genres ?? [], [kind == .podcast ? "podcast" : "audiobook"])
        attributes.languages = metadata.language.map { [$0] }
        attributes.addedDate = item.addedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        attributes.thumbnailData = cover
        let key = SpotlightKey(scope: scope, kind: kind, itemID: item.id)
        return CSSearchableItem(uniqueIdentifier: key.uniqueIdentifier, domainIdentifier: domain, attributeSet: attributes)
    }

    static func episodeItem(_ episode: AudiobookshelfClient.PodcastEpisode, podcast: AudiobookshelfClient.IndexItem, scope: String, domain: String, cover: Data?) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .audio)
        let title = episode.title ?? "Odcinek"
        let podcastTitle = podcast.media.metadata.title
        attributes.title = title
        attributes.displayName = title
        attributes.album = podcastTitle
        attributes.artist = podcast.media.metadata.author
        attributes.contentDescription = description(podcastTitle.map { "Odcinek · \($0)" }, nil, episode.subtitle, HTMLText.plain(episode.description))
        attributes.keywords = SpotlightPlan.keywords([podcastTitle], [podcast.media.metadata.author], ["odcinek"])
        attributes.contentCreationDate = episode.publishedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        attributes.thumbnailData = cover
        let key = SpotlightKey(scope: scope, kind: .episode, itemID: podcast.id, episodeID: episode.id)
        return CSSearchableItem(uniqueIdentifier: key.uniqueIdentifier, domainIdentifier: domain, attributeSet: attributes)
    }

    /// Opis w wynikach Spotlight: pierwsze linie są widoczne pod tytułem, reszta służy wyszukiwaniu.
    private static func description(_ parts: String?...) -> String? {
        let text = parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? nil : String(text.prefix(2000))
    }

    // MARK: Otwieranie wyniku

    /// Wynik Spotlight tej kopii: pozycja i jej biblioteka; cudzy zakres albo inny wpis — `nil`.
    func target(forIdentifier identifier: String) -> (itemID: String, libraryID: String?)? {
        guard let key = SpotlightKey(uniqueIdentifier: identifier), let scope, key.scope == scope else { return nil }
        loadManifest(scope: scope)
        return (key.itemID, manifest.items[key.itemID]?.libraryID)
    }

    // MARK: Usuwanie

    /// Wyłączenie albo konto słuchacza usunięte: cały zakres tej kopii znika z indeksu.
    func removeAll(keepEnabled: Bool = false) async {
        pending?.cancel()
        running?.cancel()
        // Paczka w locie trafiłaby do indeksu po usunięciu domeny i odtworzyła manifest.
        await running?.value
        guard let scope else { return }
        await deleteDomain(SpotlightKey.domain(scope: scope))
        manifest = SpotlightManifest()
        if let manifestURL { try? FileManager.default.removeItem(at: manifestURL) }
        status = isEnabled ? .waiting : .off
        logger.info("Spotlight: indeks tej kopii usunięty")
    }

    private func deleteDomain(_ domain: String) async {
        do { try await index.deleteSearchableItems(withDomainIdentifiers: [domain]) } catch {
            logger.error("Spotlight: usuwanie \(domain, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Manifest

    private func loadManifest(scope: String) {
        guard loadedScope != scope else { return }
        loadedScope = scope
        manifest = manifestURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(SpotlightManifest.self, from: $0) } ?? SpotlightManifest()
    }

    private func saveManifest() {
        guard let manifestURL, let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// Okładki w ostatnich paczkach: pozycje z okładką na serwerze i pobrane miniatury (tryb sprawdzający).
    @ObservationIgnored var coverStats = (withCover: 0, fetched: 0)

    /// Liczba pozycji w indeksie tej kopii (strona ustawień, tryb sprawdzający).
    var indexedCount: Int { manifest.items.count }
}
