// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Lista pozycji do indeksu Spotlight na Macu (etap 14f): `/api/libraries/:id/items?minified=1`
// (`LibraryItem.toOldJSONMinified`) — skrócona wersja ma już opis, lektora, serię, gatunki
// i `updatedAt`, więc nie trzeba pobierać każdej pozycji osobno. Odcinki podcastów są tylko
// w szczegółach pozycji (`item(id:)`).
extension AudiobookshelfClient {
    public struct IndexItem: Decodable, Sendable, Identifiable {
        public struct Media: Decodable, Sendable {
            public struct Metadata: Decodable, Sendable {
                public let title: String?
                public let subtitle: String?
                public let authorName: String?
                /// Podcasty mają autora w polu `author`.
                public let author: String?
                public let narratorName: String?
                public let seriesName: String?
                public let genres: [String]?
                public let description: String?
                public let publishedYear: String?
                public let language: String?
            }

            public let metadata: Metadata
            public let coverPath: String?
            public let duration: Double?
        }

        public let id: String
        public let libraryId: String
        public let mediaType: String
        public let media: Media
        /// Milisekundy od 1970 — chwila ostatniej zmiany pozycji na serwerze.
        public let updatedAt: Double?
        public let addedAt: Double?

        public var isPodcast: Bool { mediaType == "podcast" }
    }

    public func indexPage(libraryID: String, page: Int, limit: Int, token: String) async throws -> Page<IndexItem> {
        let query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "minified", value: "1"),
            URLQueryItem(name: "sort", value: "addedAt"),
            URLQueryItem(name: "desc", value: "1"),
        ]
        return try decode(Page<IndexItem>.self, from: await send("GET", "api/libraries/\(libraryID)/items", query: query, token: token))
    }
}
