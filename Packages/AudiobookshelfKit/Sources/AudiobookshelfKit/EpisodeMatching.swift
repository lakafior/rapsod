// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 10e). Reguła pewnego dopasowania odpowiada temu, co
// robi serwer audiobookshelf v2.38.0 (`PodcastEpisode.checkMatchesGuidOrEnclosureUrl`: równy guid
// albo równy adres `enclosure`) — opisana słowami, nie przepisana. Słabsze poziomy (adres bez
// przekierowań śledzących, tytuł z datą) są pomysłem tego projektu i służą tylko do wyświetlania.

import Foundation

/// To, po czym da się rozpoznać ten sam odcinek w kanale RSS, na serwerze i w kolejce pobierania.
public struct EpisodeIdentity: Sendable, Hashable {
    public var guid: String?
    /// Adres pliku dokładnie jak w kanale (serwer zapisuje go bez zmian).
    public var url: String?
    public var title: String?
    public var published: Date?

    public init(guid: String?, url: String?, title: String?, published: Date?) {
        self.guid = guid?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.url = url?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.title = title
        self.published = published
    }

    public init(_ episode: RSSEpisode) {
        self.init(guid: episode.guid, url: episode.enclosure.url, title: episode.title, published: episode.published)
    }

    public init(_ episode: AudiobookshelfClient.PodcastEpisode) {
        self.init(guid: episode.guid, url: episode.enclosure?.url, title: episode.title, published: episode.published)
    }
}

public enum EpisodeMatching {
    /// Jak pewne jest dopasowanie — od najsłabszego.
    public enum Strength: Int, Comparable, Sendable {
        /// Ten sam tytuł i data publikacji z dokładnością do półtorej doby.
        case titleAndDate = 1
        /// Ten sam plik po zdjęciu przekierowań śledzących i parametrów adresu.
        case normalizedURL = 2
        /// Dokładnie ten sam adres pliku (reguła serwera).
        case exactURL = 3
        /// Ten sam guid (reguła serwera).
        case guid = 4

        public static func < (a: Strength, b: Strength) -> Bool { a.rawValue < b.rawValue }

        /// Tylko takie dopasowanie pozwala przenieść postęp albo zlecić pobranie — to samo
        /// uznałby za „ten sam odcinek” serwer.
        public var isCertain: Bool { self >= .exactURL }
    }

    public struct Match: Sendable, Hashable {
        public let other: Int
        public let strength: Strength
    }

    /// Siła dopasowania dwóch odcinków albo `nil`.
    public static func strength(_ a: EpisodeIdentity, _ b: EpisodeIdentity) -> Strength? {
        if let x = a.guid, let y = b.guid, x == y { return .guid }
        if let x = a.url, let y = b.url, x == y { return .exactURL }
        // Dwa różne guidy to dwa różne odcinki — słabsze poziomy tylko bez sprzeczności.
        if let x = a.guid, let y = b.guid, x != y { return nil }
        if let x = a.url.flatMap(normalizedURL), let y = b.url.flatMap(normalizedURL), x == y { return .normalizedURL }
        if let x = a.title.map(normalizedTitle), let y = b.title.map(normalizedTitle), !x.isEmpty, x == y, datesClose(a.published, b.published) {
            return .titleAndDate
        }
        return nil
    }

    /// Para do pary: każdy odcinek z `left` z co najwyżej jednym z `right`. Najpierw wszystkie
    /// dopasowania najpewniejsze, potem słabsze między tym, co zostało. Remis na słabym poziomie
    /// (dwa odcinki o tym samym tytule i dacie) zostaje bez dopasowania.
    public static func match(_ left: [EpisodeIdentity], _ right: [EpisodeIdentity]) -> [Int: Match] {
        var result: [Int: Match] = [:]
        var taken = Set<Int>()

        func assign(_ strength: Strength, key: (EpisodeIdentity) -> String?) {
            var index: [String: [Int]] = [:]
            for (j, item) in right.enumerated() where !taken.contains(j) {
                if let k = key(item) { index[k, default: []].append(j) }
            }
            var claims: [Int: [Int]] = [:]
            for (i, item) in left.enumerated() where result[i] == nil {
                guard let k = key(item), let candidates = index[k] else { continue }
                let fitting = candidates.filter { Self.strength(item, right[$0]) == strength }
                guard let j = Self.pick(fitting, for: item, in: right, strength: strength) else { continue }
                claims[j, default: []].append(i)
            }
            for (j, lefts) in claims {
                // Dwa odcinki z lewej chcą tego samego z prawej: pewny poziom — pierwszy, słaby — nikt.
                if lefts.count > 1, strength < .exactURL { continue }
                let i = lefts.min()!
                result[i] = Match(other: j, strength: strength)
                taken.insert(j)
            }
        }

        assign(.guid) { $0.guid }
        assign(.exactURL) { $0.url }
        assign(.normalizedURL) { $0.url.flatMap(normalizedURL) }
        assign(.titleAndDate) { $0.title.map(normalizedTitle).flatMap { $0.isEmpty ? nil : $0 } }
        return result
    }

    private static func pick(_ candidates: [Int], for item: EpisodeIdentity, in right: [EpisodeIdentity], strength: Strength) -> Int? {
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 || strength >= .exactURL { return candidates.first }
        // Słaby poziom z kilkoma kandydatami: najbliższa data, o ile wyraźnie najbliższa.
        guard let date = item.published else { return nil }
        let sorted = candidates.compactMap { j in right[j].published.map { (j, abs($0.timeIntervalSince(date))) } }.sorted { $0.1 < $1.1 }
        guard let best = sorted.first else { return nil }
        if sorted.count > 1, sorted[1].1 - best.1 < 3600 { return nil }
        return best.0
    }

    private static func datesClose(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case (let x?, let y?): abs(x.timeIntervalSince(y)) <= 36 * 3600
        // Data tylko po jednej stronie: sam tytuł to za mało.
        default: false
        }
    }

    /// Tytuł do porównania: małe litery, bez znaków interpunkcyjnych i nadmiaru spacji.
    public static func normalizedTitle(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    // MARK: Adresy

    /// Przekierowania śledzące, które wydawcy doklejają przed właściwy adres pliku: liczba
    /// segmentów ścieżki do zdjęcia (po nich zaczyna się host pliku). `nil` — host znany,
    /// a długość przedrostka zmienna: zdejmujemy do pierwszego segmentu wyglądającego jak host.
    static let trackingPrefixes: [String: Int?] = [
        "dts.podtrac.com": 1,            // /redirect.mp3/<adres>
        "www.podtrac.com": 2,            // /pts/redirect.mp3/<adres>
        "chtbl.com": 2,                  // /track/<id>/<adres>
        "chrt.fm": 2,                    // /track/<id>/<adres>
        "pdst.fm": 1,                    // /e/<adres>
        "pdcn.co": 1,                    // /e/<adres>
        "op3.dev": 1,                    // /e/<adres> albo /e,pg=…/<adres>
        "prfx.byspotify.com": 1,         // /e/<adres>
        "pscrb.fm": 2,                   // /rss/p/<adres>
        "verifi.podscribe.com": 2,       // /rss/p/<adres>
        "arttrk.com": 2,                 // /p/<id>/<adres>
        "mgln.ai": 2,                    // /e/<id>/<adres>
        "pfx.vpixl.com": 1,              // /<id>/<adres>
        "claritaspod.com": nil,
        "clrtpod.com": nil,
        "tracking.swap.fm": nil,
        "growx.podkite.com": nil,
        "media.blubrry.com": 1,          // /<program>/<adres>
    ]

    static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "mp4", "ogg", "oga", "opus", "wav", "flac", "mpga"]

    /// Adres pliku bez schematu, `www.`, przekierowań śledzących, kotwicy i — gdy ścieżka kończy
    /// się plikiem audio — bez parametrów. Do porównania, nie do pobierania.
    public static func normalizedURL(_ text: String) -> String? {
        var current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<6 {
            guard let (host, segments, query) = split(current) else { return nil }
            if let rest = strippedTracking(host: host, segments: segments) {
                // Pozostała część to „host/ścieżka” właściwego pliku; parametry zostały przy nim.
                current = "https://" + rest.joined(separator: "/") + (query.map { "?" + $0 } ?? "")
                continue
            }
            var normalizedHost = host
            if normalizedHost.hasPrefix("www.") { normalizedHost.removeFirst(4) }
            let path = segments.map { $0.removingPercentEncoding ?? $0 }.joined(separator: "/")
            let ext = (segments.last.map { ($0 as NSString).pathExtension.lowercased() }) ?? ""
            var result = normalizedHost + "/" + path
            if !audioExtensions.contains(ext), let query, !query.isEmpty {
                // Adres bez rozszerzenia (np. `download.php?id=12`): parametry wyróżniają plik,
                // zostają — bez typowych śledzących.
                let kept = query.split(separator: "&").filter { pair in
                    let name = pair.split(separator: "=").first.map { $0.lowercased() } ?? ""
                    return !name.hasPrefix("utm_") && !["aid", "source", "from", "ref", "awcollectionid", "awepisodeid", "_from"].contains(name)
                }.sorted()
                if !kept.isEmpty { result += "?" + kept.joined(separator: "&") }
            }
            return result
        }
        return nil
    }

    private static func split(_ text: String) -> (host: String, segments: [String], query: String?)? {
        var rest = Substring(text)
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        var query: String?
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
        if let mark = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: mark)...])
            rest = rest[..<mark]
        }
        var parts = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return nil }
        var host = parts.removeFirst().lowercased()
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if let colon = host.lastIndex(of: ":"), host[host.index(after: colon)...].allSatisfy(\.isNumber) { host = String(host[..<colon]) }
        guard host.contains(".") else { return nil }
        return (host, parts, query)
    }

    /// Reszta adresu po przekierowaniu śledzącym (zaczyna się od hosta pliku) albo `nil`.
    private static func strippedTracking(host: String, segments: [String]) -> [String]? {
        let bare = host.hasPrefix("www.") && trackingPrefixes[host] == nil ? String(host.dropFirst(4)) : host
        guard let rule = trackingPrefixes[bare] else { return nil }
        var rest: [String]
        if let count = rule {
            guard segments.count > count else { return nil }
            rest = Array(segments.dropFirst(count))
        } else {
            guard let start = segments.firstIndex(where: looksLikeHost), start < segments.count - 1 else { return nil }
            rest = Array(segments[start...])
        }
        // `op3.dev/e/https://host/…` — schemat wewnątrz ścieżki.
        if let first = rest.first, first.lowercased() == "https:" || first.lowercased() == "http:" { rest.removeFirst() }
        guard let first = rest.first, looksLikeHost(first), rest.count >= 2 else { return nil }
        return rest
    }

    private static func looksLikeHost(_ segment: String) -> Bool {
        let parts = segment.split(separator: ".")
        guard parts.count >= 2, let tld = parts.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        // „redirect.mp3” to plik, nie host.
        return !audioExtensions.contains(tld.lowercased())
    }

    // MARK: Kolejka pobierania serwera

    /// Czy wpis kolejki serwera dotyczy tego odcinka z kanału. Serwer przepuszcza adres przez
    /// `encodeURI`, więc adres porównujemy także po zakodowaniu i odkodowaniu.
    public static func isSame(_ download: AudiobookshelfClient.EpisodeDownload, as episode: EpisodeIdentity) -> Bool {
        if let a = download.guid?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, let b = episode.guid { return a == b }
        guard let queued = download.url, let url = episode.url else { return false }
        if queued == url { return true }
        if let encoded = url.addingPercentEncoding(withAllowedCharacters: uriAllowed), queued == encoded { return true }
        if let decoded = queued.removingPercentEncoding, decoded == url || decoded == url.removingPercentEncoding { return true }
        return false
    }

    /// Znaki, których `encodeURI` z JavaScriptu nie koduje.
    private static let uriAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'();/?:@&=+$,#")
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
