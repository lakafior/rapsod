// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 10e).

import Foundation
import OSLog

private let logger = Logger(subsystem: "net.smigi.rapsod", category: "Feeds")

/// Kanał RSS pobierany przez telefon wprost od wydawcy (bez serwera i bez uprawnień
/// administratora), z granicą rozmiaru i czasu, warunkowym pobraniem (`ETag`, `Last-Modified`)
/// i pamięcią podręczną na dysku: lista odcinków pokazuje się od razu, odświeżana w tle.
public final class PodcastFeedLoader: Sendable {
    public enum LoadError: LocalizedError, Equatable {
        case invalidURL
        case tooLarge
        case timedOut
        case http(Int)
        /// Kanał jest dostępny tylko przez niezabezpieczone HTTP, a aplikacja łączy się z internetem
        /// wyłącznie przez HTTPS (App Transport Security).
        case insecureOnly

        public var errorDescription: String? {
            switch self {
            case .invalidURL: "Podcast nie ma poprawnego adresu kanału RSS."
            case .tooLarge: "Kanał RSS jest zbyt duży, by go wczytać na telefonie."
            case .timedOut: "Wydawca nie odpowiedział na czas."
            case .http(let status): "Wydawca odpowiedział błędem \(status)."
            case .insecureOnly: "Wydawca udostępnia kanał tylko przez niezabezpieczone połączenie HTTP, którego aplikacja nie używa."
            }
        }
    }

    public struct Snapshot: Sendable {
        public let podcast: RSSPodcast
        public let fetchedAt: Date
        /// Z pamięci podręcznej, bez sprawdzenia u wydawcy.
        public let isCached: Bool
    }

    public static let maxBytes = 30 * 1024 * 1024
    public static let timeout: Duration = .seconds(45)
    /// Po takim czasie wpis z pamięci jest „świeży” i nie ma potrzeby pytać wydawcy.
    public static let freshness: TimeInterval = 30 * 60

    private let directory: URL?
    private let session: URLSession

    /// `directory == nil` — bez zapisu na dysk.
    public init(directory: URL?, session: URLSession? = nil) {
        self.directory = directory
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.httpAdditionalHeaders = ["User-Agent": "Rapsod (podcast reader)"]
            self.session = URLSession(configuration: configuration)
        }
    }

    private struct Entry: Codable {
        var feedURL: String
        var fetchedAt: Date
        var etag: String?
        var lastModified: String?
        var podcast: RSSPodcast
    }

    /// Kanał z pamięci podręcznej (bez sieci).
    public func cached(_ feedURL: String) -> Snapshot? {
        guard let entry = readEntry(feedURL) else { return nil }
        return Snapshot(podcast: entry.podcast, fetchedAt: entry.fetchedAt, isCached: true)
    }

    /// Kanał od wydawcy; `force == false` i świeży wpis w pamięci — bez sieci.
    public func load(_ feedURL: String, force: Bool) async throws -> Snapshot {
        let previous = readEntry(feedURL)
        if !force, let previous, Date.now.timeIntervalSince(previous.fetchedAt) < Self.freshness {
            return Snapshot(podcast: previous.podcast, fetchedAt: previous.fetchedAt, isCached: true)
        }
        guard let url = RSSFeedParser.webURL(feedURL) else { throw LoadError.invalidURL }
        let candidates = Self.candidates(for: url)
        var lastError: (any Error)?
        for candidate in candidates {
            do {
                let result = try await fetch(candidate, etag: previous?.etag, lastModified: previous?.lastModified)
                switch result {
                case .notModified:
                    guard var entry = previous else { continue }
                    entry.fetchedAt = .now
                    writeEntry(entry)
                    return Snapshot(podcast: entry.podcast, fetchedAt: entry.fetchedAt, isCached: false)
                case .data(let data, let etag, let lastModified):
                    let podcast = try await Task.detached(priority: .userInitiated) { try RSSFeedParser.parse(data) }.value
                    let entry = Entry(feedURL: feedURL, fetchedAt: .now, etag: etag, lastModified: lastModified, podcast: podcast)
                    writeEntry(entry)
                    return Snapshot(podcast: podcast, fetchedAt: entry.fetchedAt, isCached: false)
                }
            } catch let error as RSSFeedParser.ParseError {
                throw error
            } catch {
                if Self.isCancellation(error) { throw CancellationError() }
                lastError = error
            }
        }
        if let lastError, Self.isATSRefusal(lastError) { throw LoadError.insecureOnly }
        throw lastError ?? LoadError.invalidURL
    }

    /// Kanał `http://`: najpierw ten sam adres po HTTPS (większość wydawców go obsługuje).
    static func candidates(for url: URL) -> [URL] {
        guard url.scheme?.lowercased() == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [url] }
        components.scheme = "https"
        if components.port == 80 { components.port = nil }
        return [components.url, url].compactMap(\.self)
    }

    public static func isATSRefusal(_ error: any Error) -> Bool {
        (error as? URLError)?.code == .appTransportSecurityRequiresSecureConnection
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private enum FetchResult {
        case notModified
        case data(Data, etag: String?, lastModified: String?)
    }

    private func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> FetchResult {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let session = session
        let prepared = request
        return try await withThrowingTaskGroup(of: FetchResult.self) { group in
            group.addTask {
                let (bytes, response) = try await session.bytes(for: prepared)
                guard let http = response as? HTTPURLResponse else { throw LoadError.http(0) }
                // Przekierowanie na schemat inny niż http(s) — nie idziemy dalej.
                if let final = http.url, RSSFeedParser.webURL(final.absoluteString) == nil { throw LoadError.invalidURL }
                if http.statusCode == 304 { return .notModified }
                guard http.statusCode == 200 else { throw LoadError.http(http.statusCode) }
                if http.expectedContentLength > Int64(Self.maxBytes) { throw LoadError.tooLarge }
                var data = Data()
                data.reserveCapacity(Int(min(max(http.expectedContentLength, 64 * 1024), Int64(Self.maxBytes))))
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > Self.maxBytes { throw LoadError.tooLarge }
                }
                return .data(data, etag: http.value(forHTTPHeaderField: "ETag"), lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
            }
            group.addTask {
                try await Task.sleep(for: Self.timeout)
                throw LoadError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw LoadError.timedOut }
            return first
        }
    }

    // MARK: Pamięć na dysku

    private func fileURL(_ feedURL: String) -> URL? {
        directory?.appending(path: Self.fileName(feedURL))
    }

    /// Stała nazwa pliku z adresu kanału (FNV-1a, 64 bity) — bez CryptoKit i bez adresu w nazwie.
    static func fileName(_ feedURL: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in feedURL.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16) + ".json"
    }

    private func readEntry(_ feedURL: String) -> Entry? {
        guard let url = fileURL(feedURL), let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.feedURL == feedURL
        else { return nil }
        return entry
    }

    private func writeEntry(_ entry: Entry) {
        guard let url = fileURL(entry.feedURL) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: url, options: .atomic)
        } catch {
            logger.error("Zapis kanału w pamięci podręcznej: \(error.localizedDescription, privacy: .public)")
        }
    }
}
