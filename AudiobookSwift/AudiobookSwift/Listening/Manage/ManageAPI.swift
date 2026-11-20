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

    struct SearchProvider: Decodable, Sendable, Hashable, Identifiable {
        /// `google`, `audible.de`, `custom-<id>`…
        let value: String
        let text: String
        var id: String { value }
    }

    struct SearchProviders: Decodable, Sendable {
        let books: [SearchProvider]
        /// Do szukania okładek: z `best` i `all` na brzegach.
        let booksCovers: [SearchProvider]
    }

    /// Wynik dostawcy (`BookFinder.search`). Dostawcy różnie podają typy (liczba albo napis,
    /// lista albo napis z przecinkami), więc dekodowanie jest pobłażliwe pole po polu.
    struct BookMatch: Decodable, Sendable, Identifiable {
        struct Series: Sendable, Hashable {
            let name: String
            let sequence: String?
        }

        let id = UUID()
        let title: String?
        let subtitle: String?
        let authors: [String]
        let narrators: [String]
        let publisher: String?
        let publishedYear: String?
        /// HTML albo zwykły tekst.
        let description: String?
        let cover: String?
        let isbn: String?
        let asin: String?
        let genres: [String]
        let tags: [String]
        let series: [Series]
        let language: String?
        /// Minuty (jak w `BookMatchCard.vue`).
        let duration: Double?
        let explicit: Bool?
        let abridged: Bool?

        private enum CodingKeys: String, CodingKey {
            case title, subtitle, author, narrator, publisher, publishedYear, description, cover, isbn, asin, genres, tags, series, language, duration, explicit, abridged
        }

        private struct SeriesEntry: Decodable {
            let series: String?
            let sequence: Loose?
        }

        init(from decoder: any Decoder) throws {
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
    struct Loose: Decodable, Sendable {
        let values: [String]

        init(from decoder: any Decoder) throws {
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

        var text: String? {
            let joined = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: ", ")
            return joined.isEmpty ? nil : joined
        }

        /// Lista; pojedynczy napis z przecinkami jest dzielony (jak `Match.vue`).
        var list: [String] {
            let parts = values.count == 1 ? values[0].split(separator: ",").map(String.init) : values
            return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
    }

    /// Rozdziały z Audnexus (`GET /api/search/chapters`). Błąd przychodzi jako HTTP 200 z `error`.
    struct ChapterLookup: Decodable, Sendable {
        struct Chapter: Decodable, Sendable {
            let title: String
            let startOffsetMs: Double
            let lengthMs: Double
        }
        let chapters: [Chapter]?
        let brandIntroDurationMs: Double?
        let brandOutroDurationMs: Double?
        let error: String?
    }

    /// Zmiana pozycji dla `PATCH /api/items/:id/media`. Pola `nil` nie są wysyłane (serwer ich
    /// nie rusza); pusty napis czyści pole. Autorzy po nazwach, serie po nazwach z numerem.
    struct MediaUpdate: Encodable, Sendable {
        struct Metadata: Encodable, Sendable {
            struct Author: Encodable, Sendable { let name: String }
            struct Series: Encodable, Sendable {
                let name: String
                /// `nil` usuwa numer tomu.
                let sequence: String?
            }
            var title: String?
            var subtitle: String?
            var authors: [Author]?
            var narrators: [String]?
            var series: [Series]?
            var genres: [String]?
            var publishedYear: String?
            var publishedDate: String?
            var publisher: String?
            var description: String?
            var isbn: String?
            var asin: String?
            var language: String?
            var explicit: Bool?
            var abridged: Bool?

            var isEmpty: Bool {
                title == nil && subtitle == nil && authors == nil && narrators == nil && series == nil && genres == nil
                    && publishedYear == nil && publishedDate == nil && publisher == nil && description == nil
                    && isbn == nil && asin == nil && language == nil && explicit == nil && abridged == nil
            }
        }
        var metadata = Metadata()
        /// Tagi są na poziomie `media`, nie `metadata`.
        var tags: [String]?

        var isEmpty: Bool { metadata.isEmpty && tags == nil }
    }

    struct ChapterUpdate: Encodable, Sendable {
        let start: Double
        let end: Double
        let title: String
    }

    // MARK: Wyszukiwanie

    func searchProviders(token: String) async throws -> SearchProviders {
        struct Response: Decodable { let providers: SearchProviders }
        return try decode(Response.self, from: await send("GET", "api/search/providers", token: token)).providers
    }

    /// Wyniki dostawcy. Pusta lista bywa też przekroczeniem czasu (serwer czeka na własnego
    /// dostawcę 10 s i wtedy zwraca `[]` bez błędu).
    func searchBooks(provider: String, title: String, author: String, itemID: String, token: String) async throws -> [BookMatch] {
        var query = [URLQueryItem(name: "provider", value: provider), URLQueryItem(name: "fallbackTitleOnly", value: "1"), URLQueryItem(name: "title", value: title)]
        if !author.isEmpty { query.append(URLQueryItem(name: "author", value: author)) }
        query.append(URLQueryItem(name: "id", value: itemID))
        let data = try await send("GET", "api/search/books", query: query, token: token, timeout: 60)
        return try decode(LenientList<BookMatch>.self, from: data).elements.filter { $0.title != nil }
    }

    func searchCovers(provider: String, title: String, author: String, token: String) async throws -> [String] {
        struct Response: Decodable { let results: LenientList<String>? }
        var query = [URLQueryItem(name: "provider", value: provider), URLQueryItem(name: "title", value: title)]
        if !author.isEmpty { query.append(URLQueryItem(name: "author", value: author)) }
        let data = try await send("GET", "api/search/covers", query: query, token: token, timeout: 90)
        var seen = Set<String>()
        return (try decode(Response.self, from: data).results?.elements ?? []).filter { seen.insert($0).inserted }
    }

    func searchChapters(asin: String, region: String, token: String) async throws -> ChapterLookup {
        let query = [URLQueryItem(name: "asin", value: asin), URLQueryItem(name: "region", value: region)]
        return try decode(ChapterLookup.self, from: await send("GET", "api/search/chapters", query: query, token: token, timeout: 60))
    }

    /// Czy właściciel tokenu widzi pozycje „dla dorosłych” (`permissions.accessExplicitContent` z `/api/me`).
    /// Wołane tokenem słuchacza — to jego uprawnienie decyduje, czy oznaczona książka zniknie mu z listy.
    func canAccessExplicitContent(token: String) async throws -> Bool {
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
    func updateMedia(itemID: String, _ update: MediaUpdate, token: String) async throws -> Bool {
        struct Response: Decodable { let updated: Bool? }
        return try decode(Response.self, from: await send("PATCH", "api/items/\(itemID)/media", body: update, token: token)).updated ?? false
    }

    /// Okładka z adresu — serwer sam ją pobiera i zapisuje w folderze pozycji.
    func setCover(itemID: String, url: String, token: String) async throws {
        struct Body: Encodable { let url: String }
        _ = try await send("POST", "api/items/\(itemID)/cover", body: Body(url: url), token: token, timeout: 60)
    }

    /// Okładka z pliku (`multipart/form-data`, pole `cover` jak w `Cover.vue`).
    func uploadCover(itemID: String, data: Data, filename: String, mimeType: String, token: String) async throws {
        let boundary = "AudiobookSwift-\(UUID().uuidString)"
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
    func setLocalCover(itemID: String, path: String, token: String) async throws {
        struct Body: Encodable { let cover: String }
        _ = try await send("PATCH", "api/items/\(itemID)/cover", body: Body(cover: path), token: token)
    }

    /// Usuwa okładkę z pozycji (plik zostaje na dysku — jak w upstreamie).
    func removeCover(itemID: String, token: String) async throws {
        _ = try await send("DELETE", "api/items/\(itemID)/cover", token: token)
    }

    /// Zastępuje rozdziały. Serwer odpowiada gołym statusem (400/403/500), więc sprawdzamy je wcześniej.
    func updateChapters(itemID: String, _ chapters: [ChapterUpdate], token: String) async throws -> Bool {
        struct Body: Encodable { let chapters: [ChapterUpdate] }
        struct Response: Decodable { let updated: Bool? }
        return try decode(Response.self, from: await send("POST", "api/items/\(itemID)/chapters", body: Body(chapters: chapters), token: token)).updated ?? false
    }
}
