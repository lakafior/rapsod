import AppIntents
import AudiobookshelfKit
import Foundation

// Encje Skrótów (etap 14e): książki, podcasty, odcinki i biblioteki z serwera. Identyfikatory to
// identyfikatory serwera, więc Skrót zapisany dziś działa po ponownym uruchomieniu (dopóki pozycji
// nie usunięto). Wyszukiwanie idzie przez wyszukiwarkę serwera (`/api/libraries/:id/search`).

struct BookEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Książka"
    static let defaultQuery = BookQuery()

    let id: String
    let title: String
    let author: String?
    let libraryID: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: author.map { "\($0)" }, image: .init(systemName: "book.closed"))
    }

    init(item: AudiobookshelfClient.LibraryItem) {
        id = item.id
        title = item.title
        author = item.author
        libraryID = item.libraryId
    }

    init(detail: AudiobookshelfClient.ItemDetail) {
        id = detail.id
        title = detail.media.metadata.title ?? "Bez tytułu"
        author = detail.media.metadata.authors?.map(\.name).joined(separator: ", ")
        libraryID = detail.libraryId
    }
}

struct BookQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [BookEntity] {
        try await IntentBridge.items(identifiers).filter { $0.mediaType != "podcast" }.map(BookEntity.init(detail:))
    }

    func entities(matching string: String) async throws -> [BookEntity] {
        try await IntentBridge.search(string, podcasts: false).map(BookEntity.init(item:))
    }

    /// Zaczęte książki, a gdy ich nie ma — pierwsze z biblioteki.
    func suggestedEntities() async throws -> [BookEntity] {
        let started = try await IntentBridge.inProgress().filter { !$0.isPodcast }
        let items = started.isEmpty ? try await IntentBridge.firstItems(podcasts: false) : started
        return items.map(BookEntity.init(item:))
    }
}

struct PodcastEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Podcast"
    static let defaultQuery = PodcastQuery()

    let id: String
    let title: String
    let author: String?
    let libraryID: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: author.map { "\($0)" }, image: .init(systemName: "mic"))
    }

    init(item: AudiobookshelfClient.LibraryItem) {
        id = item.id
        title = item.title
        author = item.author
        libraryID = item.libraryId
    }

    init(detail: AudiobookshelfClient.ItemDetail) {
        id = detail.id
        title = detail.media.metadata.title ?? "Bez tytułu"
        author = detail.media.metadata.author
        libraryID = detail.libraryId
    }

    init(id: String, title: String, author: String?, libraryID: String) {
        self.id = id
        self.title = title
        self.author = author
        self.libraryID = libraryID
    }
}

struct PodcastQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PodcastEntity] {
        try await IntentBridge.items(identifiers).filter { $0.mediaType == "podcast" }.map(PodcastEntity.init(detail:))
    }

    func entities(matching string: String) async throws -> [PodcastEntity] {
        try await IntentBridge.search(string, podcasts: true).map(PodcastEntity.init(item:))
    }

    func suggestedEntities() async throws -> [PodcastEntity] {
        try await IntentBridge.firstItems(podcasts: true).map(PodcastEntity.init(item:))
    }
}

struct EpisodeEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Odcinek"
    static let defaultQuery = EpisodeQuery()

    /// `itemID/episodeID` — jak klucz postępu (`ListeningController.key`).
    let id: String
    let itemID: String
    let episodeID: String
    let title: String
    let podcastTitle: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: podcastTitle.map { "\($0)" }, image: .init(systemName: "waveform"))
    }

    init(itemID: String, episodeID: String, title: String, podcastTitle: String?) {
        id = "\(itemID)/\(episodeID)"
        self.itemID = itemID
        self.episodeID = episodeID
        self.title = title
        self.podcastTitle = podcastTitle
    }

    init(item: AudiobookshelfClient.LibraryItem, episode: AudiobookshelfClient.PodcastEpisode) {
        self.init(itemID: item.id, episodeID: episode.id, title: episode.title ?? "Odcinek", podcastTitle: item.title)
    }

    init(podcast: AudiobookshelfClient.ItemDetail, episode: AudiobookshelfClient.PodcastEpisode) {
        self.init(itemID: podcast.id, episodeID: episode.id, title: episode.title ?? "Odcinek", podcastTitle: podcast.media.metadata.title)
    }
}

struct EpisodeQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [EpisodeEntity] {
        let pairs = identifiers.compactMap { id -> (String, String)? in
            let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        let podcasts = try await IntentBridge.items(Array(Set(pairs.map(\.0))))
        return pairs.compactMap { itemID, episodeID in
            guard let podcast = podcasts.first(where: { $0.id == itemID }),
                  let episode = podcast.media.episodes?.elements.first(where: { $0.id == episodeID }) else { return nil }
            return EpisodeEntity(podcast: podcast, episode: episode)
        }
    }

    func entities(matching string: String) async throws -> [EpisodeEntity] {
        try await IntentBridge.searchEpisodes(string)
    }

    /// Zaczęte odcinki.
    func suggestedEntities() async throws -> [EpisodeEntity] {
        try await IntentBridge.inProgress().compactMap { item in
            item.recentEpisode.map { EpisodeEntity(item: item, episode: $0) }
        }
    }
}

struct LibraryEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Biblioteka"
    static let defaultQuery = LibraryQuery()

    let id: String
    let name: String
    let isPodcasts: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: isPodcasts ? "Podcasty" : "Książki",
                              image: .init(systemName: isPodcasts ? "mic" : "books.vertical"))
    }

    init(_ library: AudiobookshelfClient.Library) {
        id = library.id
        name = library.name
        isPodcasts = library.mediaType == "podcast"
    }
}

struct LibraryQuery: EntityQuery {
    /// Biblioteki z konta root (wszystkie), a gdy nie jest połączone — te widoczne dla słuchacza.
    @MainActor
    private func libraries() async throws -> [AudiobookshelfClient.Library] {
        if let app = try? await IntentBridge.ready(.admin), !app.account.libraries.isEmpty { return app.account.libraries }
        return try await IntentBridge.ready(.listener).listening.libraries
    }

    func entities(for identifiers: [String]) async throws -> [LibraryEntity] {
        try await libraries().filter { identifiers.contains($0.id) }.map(LibraryEntity.init)
    }

    func suggestedEntities() async throws -> [LibraryEntity] {
        try await libraries().map(LibraryEntity.init)
    }
}
