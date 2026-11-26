// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu. Kształty odpowiedzi według publicznej dokumentacji
// API Podcast Index (podcastindex-org.github.io/docs-api) i fyyd (github.com/eazyliving/fyyd-api).

import CryptoKit
import Foundation

/// Katalog podcastów, w którym szuka okno „Dodaj podcast”.
public enum PodcastDirectory: String, Codable, Sendable, CaseIterable {
    case itunes, podcastIndex, fyyd

    public var title: String {
        switch self {
        case .itunes: "iTunes"
        case .podcastIndex: "Podcast Index"
        case .fyyd: "fyyd"
        }
    }
}

/// Klucz i sekret API Podcast Index (darmowe konto na api.podcastindex.org). Trzymane w pęku kluczy.
public struct PodcastIndexCredentials: Codable, Sendable, Equatable {
    public var key: String
    public var secret: String

    public init(key: String, secret: String) {
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isComplete: Bool { !key.isEmpty && !secret.isEmpty }
}

/// Wyszukiwanie w katalogach poza iTunes — prosto z aplikacji, nie przez serwer. Wyniki mają
/// postać `PodcastSearchResult`, więc dalej idą tą samą drogą co z iTunes (kanał przez serwer).
public enum PodcastDirectories {
    public enum SearchError: LocalizedError, Equatable {
        case rejectedKey
        case http(PodcastDirectory, Int)
        case invalidResponse(PodcastDirectory)

        public var errorDescription: String? {
            switch self {
            case .rejectedKey: "Podcast Index odrzucił klucz API — sprawdź klucz i sekret w ustawieniach."
            case .http(let directory, let status): "\(directory.title) odpowiedział błędem \(status)."
            case .invalidResponse(let directory): "\(directory.title) zwrócił nieczytelną odpowiedź."
            }
        }
    }

    static let userAgent = "Rapsod/1.0"

    // MARK: Podcast Index

    /// Nagłówek `Authorization`: SHA-1 (szesnastkowo) z klucza, sekretu i czasu w sekundach.
    public static func podcastIndexAuthorization(key: String, secret: String, epoch: Int) -> String {
        Insecure.SHA1.hash(data: Data((key + secret + String(epoch)).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func podcastIndex(term: String, credentials: PodcastIndexCredentials, max: Int = 40,
                                    session: URLSession = .shared, now: Date = .now) async throws -> [AudiobookshelfClient.PodcastSearchResult] {
        var components = URLComponents(string: "https://api.podcastindex.org/api/1.0/search/byterm")!
        components.queryItems = [URLQueryItem(name: "q", value: term), URLQueryItem(name: "max", value: String(max))]
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        let epoch = Int(now.timeIntervalSince1970)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(credentials.key, forHTTPHeaderField: "X-Auth-Key")
        request.setValue(String(epoch), forHTTPHeaderField: "X-Auth-Date")
        request.setValue(podcastIndexAuthorization(key: credentials.key, secret: credentials.secret, epoch: epoch), forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw SearchError.rejectedKey }
        guard (200..<300).contains(status) else { throw SearchError.http(.podcastIndex, status) }
        return try parsePodcastIndex(data)
    }

    static func parsePodcastIndex(_ data: Data) throws -> [AudiobookshelfClient.PodcastSearchResult] {
        guard let root = try? JSONDecoder().decode(AudiobookshelfClient.JSONValue.self, from: data),
              case .array(let feeds)? = root["feeds"] else { throw SearchError.invalidResponse(.podcastIndex) }
        return feeds.compactMap { feed in
            guard let url = feed["url"]?.string else { return nil }
            var genres: [String]?
            if case .object(let categories)? = feed["categories"] {
                // Klucze to numery kategorii — porządek po numerze, żeby był stały.
                genres = categories.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }.compactMap { $0.value.string }
            }
            let itunesID = feed["itunesId"]?.number.map { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
            return .init(id: itunesID, title: feed["title"]?.string, artistName: feed["author"]?.string ?? feed["ownerName"]?.string,
                         description: feed["description"]?.string, genres: genres,
                         cover: feed["artwork"]?.string ?? feed["image"]?.string,
                         trackCount: feed["episodeCount"]?.number.map { Int($0) }, feedUrl: url,
                         explicit: flag(feed["explicit"]), source: .podcastIndex)
        }
    }

    // MARK: fyyd

    public static func fyyd(term: String, count: Int = 40, session: URLSession = .shared) async throws -> [AudiobookshelfClient.PodcastSearchResult] {
        var components = URLComponents(string: "https://api.fyyd.de/0.2/search/podcast")!
        components.queryItems = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "count", value: String(count))]
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SearchError.http(.fyyd, status) }
        return try parseFyyd(data)
    }

    static func parseFyyd(_ data: Data) throws -> [AudiobookshelfClient.PodcastSearchResult] {
        guard let root = try? JSONDecoder().decode(AudiobookshelfClient.JSONValue.self, from: data) else {
            throw SearchError.invalidResponse(.fyyd)
        }
        guard case .array(let podcasts)? = root["data"] else { return [] }
        return podcasts.compactMap { podcast in
            guard let url = podcast["xmlURL"]?.string else { return nil }
            return .init(title: podcast["title"]?.string, artistName: podcast["author"]?.string,
                         description: podcast["description"]?.string, genres: nil,
                         cover: podcast["imgURL"]?.string ?? podcast["layoutImageURL"]?.string,
                         trackCount: podcast["episode_count"]?.number.map { Int($0) }, feedUrl: url,
                         explicit: nil, source: .fyyd)
        }
    }

    // MARK: Wszystkie naraz

    /// Wynik wyszukiwania we wszystkich katalogach: połączona lista i katalogi, które zawiodły.
    public struct Outcome: Sendable {
        public let results: [AudiobookshelfClient.PodcastSearchResult]
        public let failures: [(directory: PodcastDirectory, message: String)]
    }

    /// iTunes (przez serwer), Podcast Index (gdy jest klucz) i fyyd równolegle; w wynikach tylko
    /// pozycje z adresem kanału, iTunes pierwszy (ma najpełniejsze dane do formularza).
    public static func searchAll(term: String, podcastIndex credentials: PodcastIndexCredentials?, session: URLSession = .shared,
                                 itunes: @escaping @Sendable () async throws -> [AudiobookshelfClient.PodcastSearchResult]) async -> Outcome {
        typealias Part = Result<[AudiobookshelfClient.PodcastSearchResult], any Error>
        func run(_ work: () async throws -> [AudiobookshelfClient.PodcastSearchResult]) async -> Part {
            do { return .success(try await work()) } catch { return .failure(error) }
        }
        async let fromITunes = run { try await itunes() }
        async let fromIndex: Part? = credentials.flatMap { $0.isComplete ? $0 : nil } == nil ? nil
            : await run { try await podcastIndex(term: term, credentials: credentials!, session: session) }
        async let fromFyyd = run { try await fyyd(term: term, session: session) }
        let parts: [(PodcastDirectory, Part?)] = [(.itunes, await fromITunes), (.podcastIndex, await fromIndex), (.fyyd, await fromFyyd)]
        var lists: [[AudiobookshelfClient.PodcastSearchResult]] = []
        var failures: [(directory: PodcastDirectory, message: String)] = []
        for (directory, part) in parts {
            switch part {
            case .success(let list)?: lists.append(list.filter { $0.feedUrl != nil })
            case .failure(let error)?: failures.append((directory, error.localizedDescription))
            case nil: break
            }
        }
        return Outcome(results: merge(lists), failures: failures)
    }

    // MARK: Łączenie

    /// Listy z kilku katalogów w jedną: kolejność list zostaje (pierwsza wygrywa), ten sam kanał
    /// (adres bez schematu, `www.` i ukośnika na końcu, bez wielkości liter) — tylko raz.
    public static func merge(_ lists: [[AudiobookshelfClient.PodcastSearchResult]]) -> [AudiobookshelfClient.PodcastSearchResult] {
        var seen = Set<String>()
        var result: [AudiobookshelfClient.PodcastSearchResult] = []
        for list in lists {
            for item in list {
                guard let feed = item.feedUrl else { continue }
                if seen.insert(feedKey(feed)).inserted { result.append(item) }
            }
        }
        return result
    }

    public static func feedKey(_ url: String) -> String {
        var key = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where key.hasPrefix(prefix) { key.removeFirst(prefix.count) }
        if key.hasPrefix("www.") { key.removeFirst(4) }
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }

    private static func flag(_ value: AudiobookshelfClient.JSONValue?) -> Bool? {
        switch value {
        case .bool(let flag)?: flag
        case .number(let number)?: number != 0
        case .string(let text)?: ["yes", "true", "explicit", "1"].contains(text.lowercased())
        default: nil
        }
    }
}
