// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Punkty API zarządzania pozycją (etap 9b2): dopasowanie metadanych i edycja szczegółów,
/// okładki i rozdziałów. **Wymagają uprawnień `update`/`upload`** — woła je wyłącznie
/// `ItemManager` tokenem konta root, nigdy `ListeningAuth` (konto słuchacza ich nie ma).
///
/// Kształty z upstreamu v2.38.0: `server/controllers/SearchController.js`
/// (`/search/providers|books|covers|chapters`), `LibraryItemController.js` (`updateMedia`,
/// `uploadCover`, `updateCover`, `removeCover`, `updateMediaChapters`), `models/Book.js`
/// (`updateFromRequest`, `updateSeriesFromRequest`) i `providers/CustomProviderAdapter.js`.
extension AudiobookshelfClient {
    // MARK: Modele

    public struct SearchProvider: Decodable, Sendable, Hashable, Identifiable {
        /// `google`, `audible.de`, `custom-<id>`…
        public let value: String
        public let text: String
        public var id: String { value }
    }

    public struct SearchProviders: Decodable, Sendable {
        public let books: [SearchProvider]
        /// Do szukania okładek: z `best` i `all` na brzegach.
        public let booksCovers: [SearchProvider]
    }

    /// Wynik dostawcy (`BookFinder.search`). Dostawcy różnie podają typy (liczba albo napis,
    /// lista albo napis z przecinkami), więc dekodowanie jest pobłażliwe pole po polu.
    public struct BookMatch: Decodable, Sendable, Identifiable {
        public struct Series: Sendable, Hashable {
            public let name: String
            public let sequence: String?
        }

        public let id = UUID()
        public let title: String?
        public let subtitle: String?
        public let authors: [String]
        public let narrators: [String]
        public let publisher: String?
        public let publishedYear: String?
        /// HTML albo zwykły tekst.
        public let description: String?
        public let cover: String?
        public let isbn: String?
        public let asin: String?
        public let genres: [String]
        public let tags: [String]
        public let series: [Series]
        public let language: String?
        /// Minuty (jak w `BookMatchCard.vue`).
        public let duration: Double?
        public let explicit: Bool?
        public let abridged: Bool?

        private enum CodingKeys: String, CodingKey {
            case title, subtitle, author, narrator, publisher, publishedYear, description, cover, isbn, asin, genres, tags, series, language, duration, explicit, abridged
        }

        private struct SeriesEntry: Decodable {
            public let series: String?
            public let sequence: Loose?
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? {
                (try? c.decodeIfPresent(Loose.self, forKey: key))??.text
            }
            func list(_ key: CodingKeys) -> [String] {
                (try? c.decodeIfPresent(Loose.self, forKey: key))??.list ?? []
            }
            title = text(.title)
            subtitle = text(.subtitle)
            authors = list(.author)
            narrators = list(.narrator)
            publisher = text(.publisher)
            publishedYear = text(.publishedYear)
            description = text(.description)
            cover = text(.cover)
            isbn = text(.isbn)
            asin = text(.asin)
            genres = list(.genres)
            tags = list(.tags)
            language = text(.language)
            duration = text(.duration).flatMap(Double.init)
            explicit = try? c.decodeIfPresent(Bool.self, forKey: .explicit)
            abridged = try? c.decodeIfPresent(Bool.self, forKey: .abridged)
            let entries = (try? c.decodeIfPresent(LenientList<SeriesEntry>.self, forKey: .series))??.elements ?? []
            series = entries.compactMap { entry in
                guard let name = entry.series?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
                return Series(name: name, sequence: entry.sequence?.text)
            }
        }
    }

    /// Napis, liczba albo lista napisów — co dostawca przyśle.
    public struct Loose: Decodable, Sendable {
        public let values: [String]

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                values = [string]
            } else if let number = try? container.decode(Double.self) {
                values = [number.rounded() == number ? String(Int(number)) : String(number)]
            } else if let array = try? container.decode([String].self) {
                values = array
            } else {
                values = []
            }
        }

        public var text: String? {
            let joined = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: ", ")
            return joined.isEmpty ? nil : joined
        }

        /// Lista; pojedynczy napis z przecinkami jest dzielony (jak `Match.vue`).
        public var list: [String] {
            let parts = values.count == 1 ? values[0].split(separator: ",").map(String.init) : values
            return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
    }

    /// Rozdziały z Audnexus (`GET /api/search/chapters`). Błąd przychodzi jako HTTP 200 z `error`.
    public struct ChapterLookup: Decodable, Sendable {
        public struct Chapter: Decodable, Sendable {
            public let title: String
            public let startOffsetMs: Double
            public let lengthMs: Double

            public init(title: String, startOffsetMs: Double, lengthMs: Double) {
                self.title = title
                self.startOffsetMs = startOffsetMs
                self.lengthMs = lengthMs
            }
        }
        public let chapters: [Chapter]?
        public let brandIntroDurationMs: Double?
        public let brandOutroDurationMs: Double?
        public let error: String?
    }

    /// Zmiana pozycji dla `PATCH /api/items/:id/media`. Pola `nil` nie są wysyłane (serwer ich
    /// nie rusza); pusty napis czyści pole. Autorzy po nazwach, serie po nazwach z numerem.
    public struct MediaUpdate: Encodable, Sendable {
        public struct Metadata: Encodable, Sendable {
            public struct Author: Encodable, Sendable { public let name: String; public init(name: String) { self.name = name } }
            public struct Series: Encodable, Sendable {
                public let name: String
                /// `nil` usuwa numer tomu.
                public let sequence: String?

                public init(name: String, sequence: String?) {
                    self.name = name
                    self.sequence = sequence
                }
            }
            public var title: String?
            public var subtitle: String?
            public var authors: [Author]?
            public var narrators: [String]?
            public var series: [Series]?
            public var genres: [String]?
            public var publishedYear: String?
            public var publishedDate: String?
            public var publisher: String?
            public var description: String?
            public var isbn: String?
            public var asin: String?
            public var language: String?
            public var explicit: Bool?
            public var abridged: Bool?

            public var isEmpty: Bool {
                title == nil && subtitle == nil && authors == nil && narrators == nil && series == nil && genres == nil
                    && publishedYear == nil && publishedDate == nil && publisher == nil && description == nil
                    && isbn == nil && asin == nil && language == nil && explicit == nil && abridged == nil
            }

            public init(title: String? = nil, subtitle: String? = nil, authors: [Author]? = nil, narrators: [String]? = nil, series: [Series]? = nil, genres: [String]? = nil, publishedYear: String? = nil, publishedDate: String? = nil, publisher: String? = nil, description: String? = nil, isbn: String? = nil, asin: String? = nil, language: String? = nil, explicit: Bool? = nil, abridged: Bool? = nil) {
                self.title = title
                self.subtitle = subtitle
                self.authors = authors
                self.narrators = narrators
                self.series = series
                self.genres = genres
                self.publishedYear = publishedYear
                self.publishedDate = publishedDate
                self.publisher = publisher
                self.description = description
                self.isbn = isbn
                self.asin = asin
                self.language = language
                self.explicit = explicit
                self.abridged = abridged
            }
        }
        public var metadata = Metadata()
        /// Tagi są na poziomie `media`, nie `metadata`.
        public var tags: [String]?

        public var isEmpty: Bool { metadata.isEmpty && tags == nil }

        public init(metadata: Metadata = Metadata(), tags: [String]? = nil) {
            self.metadata = metadata
            self.tags = tags
        }
    }

    public struct ChapterUpdate: Encodable, Sendable {
        public let start: Double
        public let end: Double
        public let title: String

        public init(start: Double, end: Double, title: String) {
            self.start = start
            self.end = end
            self.title = title
        }
    }

    // MARK: Wyszukiwanie

    public func searchProviders(token: String) async throws -> SearchProviders {
        struct Response: Decodable { let providers: SearchProviders }
        return try decode(Response.self, from: await send("GET", "api/search/providers", token: token)).providers
    }

    /// Wyniki dostawcy. Pusta lista bywa też przekroczeniem czasu (serwer czeka na własnego
    /// dostawcę 10 s i wtedy zwraca `[]` bez błędu).
    public func searchBooks(provider: String, title: String, author: String, itemID: String, token: String) async throws -> [BookMatch] {
        var query = [URLQueryItem(name: "provider", value: provider), URLQueryItem(name: "fallbackTitleOnly", value: "1"), URLQueryItem(name: "title", value: title)]
        if !author.isEmpty { query.append(URLQueryItem(name: "author", value: author)) }
        query.append(URLQueryItem(name: "id", value: itemID))
        let data = try await send("GET", "api/search/books", query: query, token: token, timeout: 60)
        return try decode(LenientList<BookMatch>.self, from: data).elements.filter { $0.title != nil }
    }

    public func searchCovers(provider: String, title: String, author: String, token: String) async throws -> [String] {
        struct Response: Decodable { let results: LenientList<String>? }
        var query = [URLQueryItem(name: "provider", value: provider), URLQueryItem(name: "title", value: title)]
        if !author.isEmpty { query.append(URLQueryItem(name: "author", value: author)) }
        let data = try await send("GET", "api/search/covers", query: query, token: token, timeout: 90)
        var seen = Set<String>()
        return (try decode(Response.self, from: data).results?.elements ?? []).filter { seen.insert($0).inserted }
    }

    public func searchChapters(asin: String, region: String, token: String) async throws -> ChapterLookup {
        let query = [URLQueryItem(name: "asin", value: asin), URLQueryItem(name: "region", value: region)]
        return try decode(ChapterLookup.self, from: await send("GET", "api/search/chapters", query: query, token: token, timeout: 60))
    }

    /// Czy właściciel tokenu widzi pozycje „dla dorosłych” (`permissions.accessExplicitContent` z `/api/me`).
    /// Wołane tokenem słuchacza — to jego uprawnienie decyduje, czy oznaczona książka zniknie mu z listy.
    public func canAccessExplicitContent(token: String) async throws -> Bool {
        struct Response: Decodable {
            struct Permissions: Decodable { let accessExplicitContent: Bool? }
            let type: String?
            let permissions: Permissions?
        }
        let me = try decode(Response.self, from: await send("GET", "api/me", token: token))
        return me.type == "root" || me.type == "admin" || me.permissions?.accessExplicitContent == true
    }

    // MARK: Zapis

    /// Zwraca, czy serwer coś zmienił (`updated`).
    public func updateMedia(itemID: String, _ update: MediaUpdate, token: String) async throws -> Bool {
        struct Response: Decodable { let updated: Bool? }
        return try decode(Response.self, from: await send("PATCH", "api/items/\(itemID)/media", body: update, token: token)).updated ?? false
    }

    /// Okładka z adresu — serwer sam ją pobiera i zapisuje w folderze pozycji.
    public func setCover(itemID: String, url: String, token: String) async throws {
        struct Body: Encodable { let url: String }
        _ = try await send("POST", "api/items/\(itemID)/cover", body: Body(url: url), token: token, timeout: 60)
    }

    /// Okładka z pliku (`multipart/form-data`, pole `cover` jak w `Cover.vue`).
    public func uploadCover(itemID: String, data: Data, filename: String, mimeType: String, token: String) async throws {
        let boundary = "Rapsod-\(UUID().uuidString)"
        let safeName = filename.replacingOccurrences(of: "\"", with: "")
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"cover\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: baseURL.appending(path: "api/items/\(itemID)/cover"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try await execute(request)
    }

    /// Okładka z pliku obrazu, który już leży w folderze pozycji.
    public func setLocalCover(itemID: String, path: String, token: String) async throws {
        struct Body: Encodable { let cover: String }
        _ = try await send("PATCH", "api/items/\(itemID)/cover", body: Body(cover: path), token: token)
    }

    /// Usuwa okładkę z pozycji (plik zostaje na dysku — jak w upstreamie).
    public func removeCover(itemID: String, token: String) async throws {
        _ = try await send("DELETE", "api/items/\(itemID)/cover", token: token)
    }

    /// Zastępuje rozdziały. Serwer odpowiada gołym statusem (400/403/500), więc sprawdzamy je wcześniej.
    public func updateChapters(itemID: String, _ chapters: [ChapterUpdate], token: String) async throws -> Bool {
        struct Body: Encodable { let chapters: [ChapterUpdate] }
        struct Response: Decodable { let updated: Bool? }
        return try decode(Response.self, from: await send("POST", "api/items/\(itemID)/chapters", body: Body(chapters: chapters), token: token)).updated ?? false
    }
}
