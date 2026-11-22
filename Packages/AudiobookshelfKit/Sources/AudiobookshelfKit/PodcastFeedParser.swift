// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 10e), napisany od zera według specyfikacji RSS 2.0
// (rssboard.org), przestrzeni nazw iTunes (Apple Podcasts), `content:encoded` i Media RSS.
// Nie jest tłumaczeniem parsera audiobookshelf — z serwera wzięte jest tylko to, które pola
// zapisuje on przy pobraniu odcinka (guid, adres `enclosure`), bo po nich dopasowujemy odcinki.

import Foundation

/// Kanał podcastu odczytany przez telefon wprost od wydawcy: do wyświetlenia listy odcinków
/// i do odtwarzania strumienia. Treść z internetu jest niezaufana — opisy trafiają tu wyłącznie
/// jako czysty tekst, adresy tylko `http`/`https`.
public struct RSSPodcast: Codable, Sendable, Hashable {
    public var title: String?
    public var author: String?
    /// Opis jako czysty tekst.
    public var summary: String?
    public var imageURL: URL?
    public var link: String?
    public var language: String?
    public var episodes: [RSSEpisode]
    /// Dokument był uszkodzony w połowie — to, co udało się przeczytać do miejsca błędu.
    public var isPartial: Bool = false

    public init(title: String? = nil, author: String? = nil, summary: String? = nil, imageURL: URL? = nil, link: String? = nil, language: String? = nil, episodes: [RSSEpisode], isPartial: Bool = false) {
        self.title = title
        self.author = author
        self.summary = summary
        self.imageURL = imageURL
        self.link = link
        self.language = language
        self.episodes = episodes
        self.isPartial = isPartial
    }
}

public struct RSSEpisode: Codable, Sendable, Hashable, Identifiable {
    public struct Enclosure: Codable, Sendable, Hashable {
        /// Adres dokładnie tak, jak w kanale (bez białych znaków na brzegach) — ten sam tekst
        /// zapisuje serwer jako `enclosureURL`, więc po nim dopasowujemy odcinki.
        public var url: String
        public var type: String?
        public var length: Int64?
    }

    public var guid: String?
    public var title: String
    public var subtitle: String?
    /// Opis jako czysty tekst (z `content:encoded`, `description` albo `itunes:summary`).
    public var summary: String?
    /// Data w postaci z kanału (zwykle RFC 822).
    public var pubDate: String?
    public var published: Date?
    public var durationSeconds: Double?
    public var enclosure: Enclosure
    public var season: String?
    public var episode: String?
    /// `full`, `trailer`, `bonus`.
    public var episodeType: String?
    public var imageURL: URL?
    public var explicit: Bool?

    /// Stały klucz odcinka w obrębie kanału: guid, a bez niego adres pliku.
    public var id: String { Self.key(guid: guid, url: enclosure.url) }

    public static func key(guid: String?, url: String) -> String {
        if let guid = guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty { return "g:" + guid }
        return "u:" + url
    }

    /// Adres pliku do odtworzenia, tylko `http`/`https`.
    public var audioURL: URL? { RSSFeedParser.webURL(enclosure.url) }

    public init(guid: String?, title: String, subtitle: String? = nil, summary: String? = nil, pubDate: String? = nil, published: Date? = nil, durationSeconds: Double? = nil, enclosure: Enclosure, season: String? = nil, episode: String? = nil, episodeType: String? = nil, imageURL: URL? = nil, explicit: Bool? = nil) {
        self.guid = guid
        self.title = title
        self.subtitle = subtitle
        self.summary = summary
        self.pubDate = pubDate
        self.published = published
        self.durationSeconds = durationSeconds
        self.enclosure = enclosure
        self.season = season
        self.episode = episode
        self.episodeType = episodeType
        self.imageURL = imageURL
        self.explicit = explicit
    }
}

/// Parser kanału RSS podcastu. Wywoływany poza aktorem głównym na gotowych bajtach.
public enum RSSFeedParser {
    public enum ParseError: LocalizedError, Equatable {
        case notRSS
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .notRSS: "To nie jest kanał RSS podcastu."
            case .malformed(let detail): "Kanał RSS jest uszkodzony (\(detail))."
            }
        }
    }

    /// Granice na treść z internetu: liczba odcinków i długość tekstu jednego pola.
    public static let maxEpisodes = 10_000
    public static let maxFieldLength = 100_000

    public static func parse(_ data: Data) throws -> RSSPodcast {
        do {
            return try parseOnce(data)
        } catch ParseError.malformed {
            // Częste odstępstwa: encje HTML (`&nbsp;`) i gołe `&` w adresach. Druga próba po naprawie.
            guard let repaired = repairEntities(data) else { throw ParseError.malformed("nieprawidłowy XML") }
            return try parseOnce(repaired)
        }
    }

    private static func parseOnce(_ data: Data) throws -> RSSPodcast {
        let delegate = Delegate()
        let parser = XMLParser(data: trimmedStart(data))
        // Bez przetwarzania przestrzeni nazw przez libxml2: przedrostki rozwiązujemy sami, a kanał
        // z niezadeklarowanym `itunes:` nie przerywa odczytu. Encje zewnętrzne wyłączone (domyślnie).
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let ok = parser.parse()
        guard delegate.sawChannel else {
            if !ok { throw ParseError.malformed(parser.parserError?.localizedDescription ?? "nieprawidłowy XML") }
            throw ParseError.notRSS
        }
        var podcast = delegate.podcast
        if !ok, !delegate.stoppedAtLimit {
            // Uszkodzenie po kilku odcinkach: lepiej pokazać to, co jest, niż nic.
            guard !podcast.episodes.isEmpty else { throw ParseError.malformed(parser.parserError?.localizedDescription ?? "nieprawidłowy XML") }
            podcast.isPartial = true
        }
        return podcast
    }

    /// Białe znaki przed `<?xml` zdarzają się (generator dopisał pustą linię) i wywracają libxml2.
    private static func trimmedStart(_ data: Data) -> Data {
        guard let first = data.firstIndex(where: { !($0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D) }) else { return data }
        return first == data.startIndex ? data : data[first...]
    }

    /// Encje HTML spoza XML zamienione na liczbowe, a `&` bez encji — na `&amp;`.
    static func repairEntities(_ data: Data) -> Data? {
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let named: [String: Int] = [
            "nbsp": 160, "hellip": 8230, "mdash": 8212, "ndash": 8211, "rsquo": 8217, "lsquo": 8216,
            "ldquo": 8220, "rdquo": 8221, "bdquo": 8222, "laquo": 171, "raquo": 187, "copy": 169, "reg": 174,
            "trade": 8482, "euro": 8364, "eacute": 233, "egrave": 232, "aacute": 225, "oacute": 243, "uuml": 252,
            "ouml": 246, "auml": 228, "szlig": 223, "middot": 183, "bull": 8226, "deg": 176, "times": 215,
        ]
        let pattern = try! NSRegularExpression(pattern: "&(#[0-9]+;|#x[0-9A-Fa-f]+;|[A-Za-z][A-Za-z0-9]*;)?")
        let source = text as NSString
        var result = ""
        var last = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let entity = match.range(at: 1)
            if entity.location == NSNotFound {
                result += "&amp;"
            } else {
                let body = source.substring(with: entity).dropLast()
                if body.hasPrefix("#") || ["amp", "lt", "gt", "quot", "apos"].contains(String(body)) {
                    result += "&" + body + ";"
                } else if let code = named[String(body)] {
                    result += "&#\(code);"
                } else {
                    result += "&amp;" + body + ";"
                }
            }
            last = match.range.location + match.range.length
        }
        result += source.substring(from: last)
        text = result
        // Deklaracja kodowania mogła mówić co innego niż UTF-8, na który właśnie przeszliśmy.
        text = text.replacingOccurrences(of: "encoding=\"[^\"]*\"", with: "encoding=\"UTF-8\"", options: .regularExpression, range: text.startIndex..<text.index(text.startIndex, offsetBy: min(200, text.count)))
        return Data(text.utf8)
    }

    /// Adres `http`/`https` z tekstu z kanału; inne schematy (`file:`, `javascript:`…) odrzucane.
    public static func webURL(_ text: String?) -> URL? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let url = URL(string: text) ?? text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap { URL(string: $0) }
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
    }

    // MARK: Odczyt

    private enum Namespace {
        case none, itunes, content, media, podcast, other
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var podcast = RSSPodcast(episodes: [])
        var sawChannel = false
        var stoppedAtLimit = false

        private var prefixes: [String: String] = [:]
        /// Ścieżka elementów od korzenia (nazwy lokalne z przestrzenią).
        private var path: [(ns: Namespace, name: String)] = []
        private var text = ""
        private var inItem = false
        private var inChannelImage = false

        // Pola bieżącego odcinka.
        private var item: [String: String] = [:]
        private var itemEnclosure: RSSEpisode.Enclosure?
        private var mediaEnclosure: RSSEpisode.Enclosure?
        private var itemImage: URL?

        private func resolve(_ qName: String) -> (Namespace, String) {
            guard let colon = qName.firstIndex(of: ":") else { return (.none, qName) }
            let prefix = String(qName[..<colon])
            let local = String(qName[qName.index(after: colon)...])
            let uri = prefixes[prefix]?.lowercased()
            if let uri {
                if uri.contains("itunes.com/dtds/podcast") { return (.itunes, local) }
                if uri.contains("purl.org/rss/1.0/modules/content") { return (.content, local) }
                if uri.contains("search.yahoo.com/mrss") { return (.media, local) }
                if uri.contains("podcastindex.org/namespace") { return (.podcast, local) }
                return (.other, local)
            }
            // Przedrostek bez deklaracji: zwyczajowe nazwy.
            switch prefix.lowercased() {
            case "itunes": return (.itunes, local)
            case "content": return (.content, local)
            case "media": return (.media, local)
            case "podcast": return (.podcast, local)
            default: return (.other, local)
            }
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
            for (key, value) in attributes where key.hasPrefix("xmlns:") {
                prefixes[String(key.dropFirst(6))] = value
            }
            let (ns, name) = resolve(elementName)
            path.append((ns, name))
            text = ""
            let depthName = path.map(\.name)

            if ns == .none, name == "channel" { sawChannel = true }
            if ns == .none, name == "item", depthName.contains("channel") {
                inItem = true
                item = [:]
                itemEnclosure = nil
                mediaEnclosure = nil
                itemImage = nil
                return
            }
            if ns == .none, name == "image", !inItem, path.count >= 2, path[path.count - 2].name == "channel" {
                inChannelImage = true
            }
            if inItem {
                if ns == .none, name == "enclosure", itemEnclosure == nil, let url = attributes["url"]?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                    itemEnclosure = .init(url: url, type: attributes["type"]?.nilIfBlank, length: attributes["length"].flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) })
                } else if ns == .media, name == "content", mediaEnclosure == nil,
                          let url = attributes["url"]?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty,
                          (attributes["type"] ?? "").lowercased().hasPrefix("audio") || attributes["medium"]?.lowercased() == "audio" {
                    mediaEnclosure = .init(url: url, type: attributes["type"]?.nilIfBlank, length: attributes["fileSize"].flatMap { Int64($0) })
                } else if ns == .itunes, name == "image", let href = attributes["href"] {
                    itemImage = RSSFeedParser.webURL(href)
                }
            } else if sawChannel, ns == .itunes, name == "image", podcast.imageURL == nil || !imageFromITunes {
                if let url = RSSFeedParser.webURL(attributes["href"]) {
                    podcast.imageURL = url
                    imageFromITunes = true
                }
            }
        }

        private var imageFromITunes = false

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard text.utf16.count < RSSFeedParser.maxFieldLength else { return }
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard text.utf16.count < RSSFeedParser.maxFieldLength else { return }
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let (ns, name) = resolve(elementName)
            defer {
                if !path.isEmpty { path.removeLast() }
                text = ""
            }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if inItem {
                if ns == .none, name == "item" {
                    finishItem()
                    if podcast.episodes.count >= RSSFeedParser.maxEpisodes {
                        stoppedAtLimit = true
                        parser.abortParsing()
                    }
                    return
                }
                // Tylko bezpośrednie dzieci `item` (nie np. `media:group/media:title`).
                guard path.count >= 2, path[path.count - 2].name == "item" || ns == .media else { return }
                let key: String? = switch (ns, name) {
                case (.none, "title"): "title"
                case (.none, "guid"): "guid"
                case (.none, "pubDate"): "pubDate"
                case (.none, "description"): "description"
                case (.content, "encoded"): "encoded"
                case (.itunes, "summary"): "summary"
                case (.itunes, "subtitle"): "subtitle"
                case (.itunes, "title"): "itunesTitle"
                case (.itunes, "duration"): "duration"
                case (.itunes, "season"): "season"
                case (.itunes, "episode"): "episode"
                case (.itunes, "episodeType"): "episodeType"
                case (.itunes, "explicit"): "explicit"
                case (.podcast, "season"): "podcastSeason"
                case (.podcast, "episode"): "podcastEpisode"
                default: nil
                }
                if let key, !value.isEmpty, item[key] == nil { item[key] = value }
                return
            }

            if inChannelImage {
                if ns == .none, name == "image" { inChannelImage = false }
                else if ns == .none, name == "url", podcast.imageURL == nil { podcast.imageURL = RSSFeedParser.webURL(value) }
                return
            }
            // Pola kanału: tylko bezpośrednie dzieci `channel`.
            guard sawChannel, path.count >= 2, path[path.count - 2].name == "channel", !value.isEmpty else { return }
            switch (ns, name) {
            case (.none, "title"): if podcast.title == nil { podcast.title = value }
            case (.none, "link"): if podcast.link == nil { podcast.link = value }
            case (.none, "language"): if podcast.language == nil { podcast.language = value }
            case (.itunes, "author"): podcast.author = value
            case (.none, "description"): if podcast.summary == nil { podcast.summary = HTMLText.plain(value) }
            case (.itunes, "summary"): if podcast.summary == nil { podcast.summary = HTMLText.plain(value) }
            default: break
            }
        }

        private func finishItem() {
            inItem = false
            // Odcinek bez pliku audio nie jest odcinkiem do słuchania (tak samo pomija go serwer).
            guard let enclosure = itemEnclosure ?? mediaEnclosure else { return }
            let html = item["encoded"] ?? item["description"] ?? item["summary"]
            let title = item["title"] ?? item["itunesTitle"] ?? "Bez tytułu"
            let episode = RSSEpisode(
                guid: item["guid"],
                title: HTMLText.plain(title) ?? title,
                subtitle: item["subtitle"].flatMap(HTMLText.plain),
                summary: HTMLText.plain(html),
                pubDate: item["pubDate"],
                published: item["pubDate"].flatMap(FeedDate.parse),
                durationSeconds: item["duration"].flatMap(FeedDuration.seconds),
                enclosure: enclosure,
                season: item["season"] ?? item["podcastSeason"],
                episode: item["episode"] ?? item["podcastEpisode"],
                episodeType: item["episodeType"]?.lowercased(),
                imageURL: itemImage,
                explicit: item["explicit"].map { ["yes", "true", "explicit"].contains($0.lowercased()) }
            )
            podcast.episodes.append(episode)
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {}
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Daty i czasy trwania

/// Data publikacji z kanału. Specyfikacja RSS mówi „RFC 822”, ale w praktyce bywa: bez dnia
/// tygodnia, z jednocyfrowym dniem, pełną nazwą miesiąca, bez sekund, ze strefą słowną (`EST`)
/// albo `+01:00`, bez strefy (traktowane jak UTC), a niektóre kanały piszą ISO 8601.
public enum FeedDate {
    public static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let first = text.first, first.isNumber, text.count >= 10, text.dropFirst(4).first == "-" {
            return iso8601(text)
        }
        return rfc822(text)
    }

    private static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]
    private static let zones: [String: Int] = [
        "GMT": 0, "UT": 0, "UTC": 0, "Z": 0, "EST": -5, "EDT": -4, "CST": -6, "CDT": -5, "MST": -7, "MDT": -6, "PST": -8, "PDT": -7,
        "CET": 1, "CEST": 2, "BST": 1, "EET": 2, "EEST": 3,
    ]

    private static func rfc822(_ text: String) -> Date? {
        var tokens = text.replacingOccurrences(of: ",", with: " ").split(whereSeparator: \.isWhitespace).map(String.init)
        // Dzień tygodnia (dowolna nazwa z liter) na początku.
        if let first = tokens.first, first.allSatisfy(\.isLetter), monthNumber(first) == nil { tokens.removeFirst() }
        guard tokens.count >= 3 else { return nil }
        var day: Int?
        var month: Int?
        // „5 Nov 2024” albo (rzadziej) „Nov 5 2024”.
        if let d = Int(tokens[0]), let m = monthNumber(tokens[1]) {
            day = d; month = m
        } else if let m = monthNumber(tokens[0]), let d = Int(tokens[1]) {
            day = d; month = m
        }
        guard let day, let month, (1...31).contains(day), var year = Int(tokens[2]) else { return nil }
        if year < 100 { year += year < 50 ? 2000 : 1900 }
        var hour = 0, minute = 0, second = 0
        var offset = 0
        var index = 3
        if index < tokens.count, tokens[index].contains(":") {
            let parts = tokens[index].split(separator: ":").map { Int($0.prefix(2)) }
            guard parts.count >= 2, let h = parts[0], let m = parts[1] else { return nil }
            hour = h; minute = m; second = parts.count > 2 ? (parts[2] ?? 0) : 0
            index += 1
        }
        if index < tokens.count {
            offset = zoneOffset(tokens[index]) ?? 0
        }
        guard (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }
        return make(year: year, month: month, day: day, hour: hour, minute: minute, second: min(second, 59), offsetSeconds: offset)
    }

    private static func monthNumber(_ token: String) -> Int? {
        let lower = token.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard lower.count >= 3, lower.allSatisfy(\.isLetter) else { return nil }
        return months[String(lower.prefix(3))]
    }

    /// `+0100`, `-05:00`, `+01`, `GMT`, `EST`, `GMT+1`.
    private static func zoneOffset(_ token: String) -> Int? {
        var t = token.uppercased()
        if let zone = zones[t] { return zone * 3600 }
        for name in ["GMT", "UTC", "UT"] where t.hasPrefix(name) && t.count > name.count {
            t = String(t.dropFirst(name.count))
            break
        }
        guard let sign = t.first, sign == "+" || sign == "-" else { return nil }
        let digits = t.dropFirst().filter(\.isNumber)
        let hours: Int
        let minutes: Int
        switch digits.count {
        case 1, 2: hours = Int(digits) ?? 0; minutes = 0
        case 3: hours = Int(digits.prefix(1)) ?? 0; minutes = Int(digits.suffix(2)) ?? 0
        case 4: hours = Int(digits.prefix(2)) ?? 0; minutes = Int(digits.suffix(2)) ?? 0
        default: return nil
        }
        guard hours <= 14, minutes < 60 else { return nil }
        let value = hours * 3600 + minutes * 60
        return sign == "-" ? -value : value
    }

    private static func iso8601(_ text: String) -> Date? {
        let scalars = Array(text)
        func number(_ from: Int, _ count: Int) -> Int? {
            guard from + count <= scalars.count else { return nil }
            return Int(String(scalars[from..<(from + count)]))
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var hour = 0, minute = 0, second = 0, offset = 0
        if scalars.count > 10, scalars[10] == "T" || scalars[10] == " " {
            guard let h = number(11, 2), let m = number(14, 2) else { return nil }
            hour = h; minute = m
            var index = 16
            if index < scalars.count, scalars[index] == ":" {
                second = number(17, 2) ?? 0
                index = 19
            }
            // Ułamki sekund.
            if index < scalars.count, scalars[index] == "." || scalars[index] == "," {
                index += 1
                while index < scalars.count, scalars[index].isNumber { index += 1 }
            }
            if index < scalars.count {
                let zone = String(scalars[index...]).trimmingCharacters(in: .whitespaces)
                offset = zone.uppercased() == "Z" ? 0 : (zoneOffset(zone) ?? 0)
            }
        }
        guard (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }
        return make(year: year, month: month, day: day, hour: hour, minute: minute, second: min(second, 59), offsetSeconds: offset)
    }

    private static func make(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, offsetSeconds: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
        return date.addingTimeInterval(TimeInterval(-offsetSeconds))
    }
}

/// `itunes:duration`: „1:02:03”, „62:03”, „3723”, „3723.5”.
public enum FeedDuration {
    public static func seconds(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            guard let value = isLast ? Double(part) : Double(Int(part) ?? -1), value >= 0, value.isFinite else { return nil }
            if parts.count > 1, index > 0, value >= 60 { return nil }
            total = total * 60 + value
        }
        return total > 0 ? total : nil
    }
}
