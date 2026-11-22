// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 10e). Porządek sortowania odpowiada temu, co obsługuje
// serwer audiobookshelf v2.38.0 dla podcastów (`libraryItemsPodcastFilters.getOrder` — opisane
// słowami, nie przepisane).

import Foundation

/// Wszystkie biblioteki podcastów jako jedna (etap 10e). Bibliotek podcastów jest zwykle mało
/// i mają po kilkadziesiąt pozycji, więc lista jest pobierana w całości (`limit=0`) i sortowana
/// na telefonie — bez stronicowania i scalania.
extension CombinedLibraries {
    /// Tylko porządki, które serwer zna dla podcastów (inne klucze zwracają pozycje bez porządku).
    public enum PodcastSort: String, CaseIterable, Sendable, Codable {
        case title, author, addedAt, episodes

        public var defaultDescending: Bool { self == .addedAt || self == .episodes }
    }

    public var hasSeveralPodcastLibraries: Bool { podcastLibraries.count > 1 }

    /// Wszystkie podcasty (po tytule), z informacją o bibliotekach, które nie odpowiedziały.
    public func podcasts() async throws -> Partial<[Client.LibraryItem]> {
        guard !podcastLibraries.isEmpty else { return Partial(value: [], failures: []) }
        let parts = try await fanOut(podcastLibraries.map { library in
            (library.id, { @MainActor [auth] () async throws -> [Client.LibraryItem] in
                try await auth.perform {
                    try await $0.itemsPage(libraryID: library.id, page: 0, limit: 0, sort: "media.metadata.title", descending: false, filter: nil, token: $1)
                }.results.elements
            })
        })
        let items = Self.sortPodcasts(parts.value.flatMap(\.self), by: .title, descending: false, ignoresPrefix: ignoresTitlePrefix)
        return Partial(value: items, failures: parts.failures)
    }

    /// Porządek jak na serwerze: tytuł (z przedrostkiem albo bez) i autor przez `COLLATE NOCASE`;
    /// brak autora — na końcu przy rosnącym, na początku przy malejącym (NULLS LAST / FIRST).
    public nonisolated static func sortPodcasts(_ items: [Client.LibraryItem], by sort: PodcastSort, descending: Bool, ignoresPrefix: Bool) -> [Client.LibraryItem] {
        func title(_ item: Client.LibraryItem) -> String {
            ServerCollation.titleKey(title: item.media.metadata.title, withPrefixAtEnd: item.media.metadata.titleIgnorePrefix, ignoresPrefix: ignoresPrefix)
        }
        func author(_ item: Client.LibraryItem) -> String? {
            let value = item.media.metadata.author ?? item.media.metadata.authorName
            return value?.isEmpty == false ? value : nil
        }
        return items.sorted { a, b in
            let result: Int
            switch sort {
            case .title:
                result = ServerCollation.compare(title(a), title(b))
            case .author:
                switch (author(a), author(b)) {
                case (nil, nil): result = ServerCollation.compare(title(a), title(b))
                // Brak autora jest „największy”: przy malejącym wychodzi na początek.
                case (nil, _): result = 1
                case (_, nil): result = -1
                case (let x?, let y?):
                    let byAuthor = ServerCollation.compare(x, y)
                    result = byAuthor != 0 ? byAuthor : ServerCollation.compare(title(a), title(b)) * (descending ? -1 : 1)
                }
            case .addedAt:
                result = Self.compare(a.addedAt, b.addedAt)
            case .episodes:
                let byCount = Self.compare(a.media.numEpisodes.map(Double.init), b.media.numEpisodes.map(Double.init))
                result = byCount != 0 ? byCount : ServerCollation.compare(title(a), title(b)) * (descending ? -1 : 1)
            }
            return descending ? result > 0 : result < 0
        }
    }

    private nonisolated static func compare(_ a: Double?, _ b: Double?) -> Int {
        switch (a, b) {
        case (nil, nil): 0
        case (nil, _): -1
        case (_, nil): 1
        case (let x?, let y?): x == y ? 0 : (x < y ? -1 : 1)
        }
    }

    /// Najnowsze nieukończone odcinki ze wszystkich bibliotek podcastów (`recent-episodes`
    /// każdej biblioteki: odcinki na serwerze po dacie publikacji), scalone po dacie.
    public func recentEpisodes(limit: Int = 20) async throws -> Partial<[Client.PodcastEpisode]> {
        guard !podcastLibraries.isEmpty else { return Partial(value: [], failures: []) }
        let parts = try await fanOut(podcastLibraries.map { library in
            (library.id, { @MainActor [auth] () async throws -> [Client.PodcastEpisode] in
                try await auth.perform { try await $0.recentEpisodes(libraryID: library.id, page: 0, limit: limit, token: $1) }
            })
        })
        let merged = parts.value.flatMap(\.self).sorted { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) }
        return Partial(value: Array(merged.prefix(limit)), failures: parts.failures)
    }

    public struct PodcastSearchResults: Sendable {
        public var podcasts: [Client.LibraryItem] = []
        /// Pozycje z `recentEpisode` — znaleziony odcinek i jego podcast.
        public var episodes: [Client.LibraryItem] = []
        public var failures: [LibraryFailure] = []

        public var isEmpty: Bool { podcasts.isEmpty && episodes.isEmpty }
    }

    /// Szukanie podcastów i pobranych odcinków we wszystkich bibliotekach podcastów.
    public func searchPodcasts(_ text: String) async throws -> PodcastSearchResults {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !podcastLibraries.isEmpty else { return PodcastSearchResults() }
        let parts = try await fanOut(podcastLibraries.map { library in
            (library.id, { @MainActor [auth] () async throws -> Client.SearchResults in
                try await auth.perform { try await $0.search(libraryID: library.id, query: query, token: $1) }
            })
        })
        var result = PodcastSearchResults(failures: parts.failures)
        result.podcasts = Self.interleave(parts.value.map { ($0.podcast?.elements ?? []).map(\.libraryItem) })
        result.episodes = Self.interleave(parts.value.map { ($0.episodes?.elements ?? []).map(\.libraryItem) })
        return result
    }
}

// MARK: - Zlecenie pobrania na serwer

extension AudiobookshelfClient.FeedEpisode {
    public var identity: EpisodeIdentity {
        EpisodeIdentity(guid: guid, url: url, title: title, published: published)
    }
}

public enum PodcastDownloadOrder {
    /// Odcinki z kanału w postaci serwera (`POST /podcasts/feed`), które na pewno (guid albo
    /// dokładny adres) odpowiadają wybranym odcinkom z kanału telefonu. Serwer zapisze dokładnie
    /// ten JSON, więc jego późniejsze „sprawdź nowe” rozpozna odcinek i nie pobierze go drugi raz.
    /// Odcinki bez pewnego odpowiednika trafiają do `missing` — nie zlecamy ich.
    public static func select(_ wanted: [RSSEpisode], in serverFeed: [AudiobookshelfClient.FeedEpisode]) -> (found: [AudiobookshelfClient.FeedEpisode], missing: [RSSEpisode]) {
        let matches = EpisodeMatching.match(wanted.map(EpisodeIdentity.init), serverFeed.map(\.identity))
        var found: [AudiobookshelfClient.FeedEpisode] = []
        var missing: [RSSEpisode] = []
        for (index, episode) in wanted.enumerated() {
            if let match = matches[index], match.strength.isCertain {
                found.append(serverFeed[match.other])
            } else {
                missing.append(episode)
            }
        }
        return (found, missing)
    }
}
