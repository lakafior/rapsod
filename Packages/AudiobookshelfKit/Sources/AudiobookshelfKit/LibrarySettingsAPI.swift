// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Ustawienia biblioteki (etap 9g; wzorzec: `components/modals/libraries/EditModal.vue` z kartami
/// `EditLibrary`, `LibrarySettings`, `LibraryScannerSettings`, `ScheduleScan` i `LibraryTools`).
/// Kształty z upstreamu v2.38.0: `models/Library.js` (`LibrarySettingsObject`) i
/// `LibraryController.update` / `removeAllMetadataFiles`. Tokenem root.
///
/// Foldery biblioteki zostają poza arkuszem: usunięcie folderu w `PATCH` usuwa z bazy wszystkie
/// jego pozycje, a aplikacja ma własny przepływ „Dodaj folder…” i „Usuń bibliotekę”.
extension AudiobookshelfClient {
    public struct LibrarySettings: Codable, Sendable, Equatable {
        /// 0 — okładki prostokątne (1,6 : 1), 1 — kwadratowe (`BookCoverAspectRatio`).
        public var coverAspectRatio: Int?
        public var disableWatcher: Bool?
        public var skipMatchingMediaWithAsin: Bool?
        public var skipMatchingMediaWithIsbn: Bool?
        public var audiobooksOnly: Bool?
        public var epubsAllowScriptedContent: Bool?
        public var hideSingleBookSeries: Bool?
        public var onlyShowLaterBooksInContinueSeries: Bool?
        public var metadataPrecedence: [String]?
        /// Kod kraju sklepu iTunes do szukania podcastów (tylko biblioteki podcastów).
        public var podcastSearchRegion: String?
        public var markAsFinishedTimeRemaining: Double?
        public var markAsFinishedPercentComplete: Double?
        /// `nil` — bez automatycznego skanu.
        public var autoScanCronExpression: String?

        private enum CodingKeys: String, CodingKey {
            case coverAspectRatio, disableWatcher, skipMatchingMediaWithAsin, skipMatchingMediaWithIsbn,
                 audiobooksOnly, epubsAllowScriptedContent, hideSingleBookSeries, onlyShowLaterBooksInContinueSeries,
                 metadataPrecedence, podcastSearchRegion, markAsFinishedTimeRemaining, markAsFinishedPercentComplete,
                 autoScanCronExpression
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            coverAspectRatio = (try? c.decodeIfPresent(Double.self, forKey: .coverAspectRatio)).flatMap { $0.map(Int.init) }
            disableWatcher = try? c.decodeIfPresent(Bool.self, forKey: .disableWatcher)
            skipMatchingMediaWithAsin = try? c.decodeIfPresent(Bool.self, forKey: .skipMatchingMediaWithAsin)
            skipMatchingMediaWithIsbn = try? c.decodeIfPresent(Bool.self, forKey: .skipMatchingMediaWithIsbn)
            audiobooksOnly = try? c.decodeIfPresent(Bool.self, forKey: .audiobooksOnly)
            epubsAllowScriptedContent = try? c.decodeIfPresent(Bool.self, forKey: .epubsAllowScriptedContent)
            hideSingleBookSeries = try? c.decodeIfPresent(Bool.self, forKey: .hideSingleBookSeries)
            onlyShowLaterBooksInContinueSeries = try? c.decodeIfPresent(Bool.self, forKey: .onlyShowLaterBooksInContinueSeries)
            metadataPrecedence = try? c.decodeIfPresent([String].self, forKey: .metadataPrecedence)
            podcastSearchRegion = try? c.decodeIfPresent(String.self, forKey: .podcastSearchRegion)
            markAsFinishedTimeRemaining = try? c.decodeIfPresent(Double.self, forKey: .markAsFinishedTimeRemaining)
            markAsFinishedPercentComplete = try? c.decodeIfPresent(Double.self, forKey: .markAsFinishedPercentComplete)
            autoScanCronExpression = try? c.decodeIfPresent(String.self, forKey: .autoScanCronExpression)
        }

        /// Wysyłamy tylko pola, które dana biblioteka ma (serwer odrzuca obce typy), a tam,
        /// gdzie `null` coś znaczy (harmonogram, „oznacz jako ukończone”) — jawne `null`.
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(coverAspectRatio, forKey: .coverAspectRatio)
            try c.encodeIfPresent(disableWatcher, forKey: .disableWatcher)
            try c.encodeIfPresent(skipMatchingMediaWithAsin, forKey: .skipMatchingMediaWithAsin)
            try c.encodeIfPresent(skipMatchingMediaWithIsbn, forKey: .skipMatchingMediaWithIsbn)
            try c.encodeIfPresent(audiobooksOnly, forKey: .audiobooksOnly)
            try c.encodeIfPresent(epubsAllowScriptedContent, forKey: .epubsAllowScriptedContent)
            try c.encodeIfPresent(hideSingleBookSeries, forKey: .hideSingleBookSeries)
            try c.encodeIfPresent(onlyShowLaterBooksInContinueSeries, forKey: .onlyShowLaterBooksInContinueSeries)
            try c.encodeIfPresent(metadataPrecedence, forKey: .metadataPrecedence)
            try c.encodeIfPresent(podcastSearchRegion, forKey: .podcastSearchRegion)
            try c.encode(markAsFinishedTimeRemaining, forKey: .markAsFinishedTimeRemaining)
            try c.encode(markAsFinishedPercentComplete, forKey: .markAsFinishedPercentComplete)
            try c.encode(autoScanCronExpression, forKey: .autoScanCronExpression)
        }
    }

    public struct LibraryDetails: Decodable, Sendable {
        public let id: String
        public let name: String
        public let icon: String?
        public let mediaType: String
        public let provider: String?
        public let folders: [Library.Folder]
        public let settings: LibrarySettings
    }

    public struct LibraryUpdate: Encodable, Sendable {
        public let name: String
        public let icon: String
        public let provider: String
        public let settings: LibrarySettings

        public init(name: String, icon: String, provider: String, settings: LibrarySettings) {
            self.name = name
            self.icon = icon
            self.provider = provider
            self.settings = settings
        }
    }

    /// Dostawcy do wyboru jako domyślne źródło (`GET /api/search/providers` → `books`/`podcasts`).
    public struct ProviderChoice: Decodable, Sendable, Hashable {
        public let value: String
        public let text: String

        public init(value: String, text: String) {
            self.value = value
            self.text = text
        }
    }

    public func libraryDetails(id: String, token: String) async throws -> LibraryDetails {
        try decode(LibraryDetails.self, from: await send("GET", "api/libraries/\(id)", token: token))
    }

    public func updateLibrary(id: String, _ update: LibraryUpdate, token: String) async throws {
        _ = try await send("PATCH", "api/libraries/\(id)", body: update, token: token)
    }

    public func libraryProviders(token: String) async throws -> (books: [ProviderChoice], podcasts: [ProviderChoice]) {
        struct Response: Decodable {
            struct Providers: Decodable {
                let books: [ProviderChoice]
                let podcasts: [ProviderChoice]?
            }
            let providers: Providers
        }
        let response = try decode(Response.self, from: await send("GET", "api/search/providers", token: token))
        return (response.providers.books, response.providers.podcasts ?? [])
    }

    /// Usuwa pliki `metadata.json` albo `metadata.abs` z folderów pozycji biblioteki.
    public func removeMetadataFiles(libraryID: String, ext: String, token: String) async throws -> (found: Int, removed: Int) {
        struct Response: Decodable {
            let found: Int?
            let removed: Int?
        }
        let response = try decode(Response.self, from: await send("POST", "api/libraries/\(libraryID)/remove-metadata", query: [URLQueryItem(name: "ext", value: ext)], token: token))
        return (response.found ?? 0, response.removed ?? 0)
    }
}

extension AudiobookshelfClient {
    /// Czy obserwator plików pilnuje biblioteki (`scannerDisableWatcher` serwera i `disableWatcher` biblioteki).
    public func isWatcherActive(libraryID: String, token: String) async throws -> Bool {
        struct Authorize: Decodable {
            struct Settings: Decodable { let scannerDisableWatcher: Bool? }
            let serverSettings: Settings
        }
        struct Library: Decodable {
            struct Settings: Decodable { let disableWatcher: Bool? }
            let settings: Settings?
        }
        let server = try decode(Authorize.self, from: await send("POST", "api/authorize", token: token))
        if server.serverSettings.scannerDisableWatcher == true { return false }
        let library = try decode(Library.self, from: await send("GET", "api/libraries/\(libraryID)", token: token))
        return library.settings?.disableWatcher != true
    }
}
