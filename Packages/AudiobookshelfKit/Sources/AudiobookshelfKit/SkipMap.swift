// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 13a).

import CryptoKit
import Foundation

/// Znaczniki segmentów sponsorowanych odcinka podcastu (etap 13a): plik `<odcinek>.skip.json`
/// obok pliku audio w folderze podcastu, jak mapa tekstu `.sync.json` przy książkach.
///
/// **Zasady formatu.**
/// - `segments` to wynik wykrywania; każde źródło (`source`) zastępuje przy ponownym liczeniu tylko
///   swoje segmenty (`replacingSegments(from:with:)`), więc etap 13b dopisze segmenty z modelu bez
///   zmiany formatu i bez kasowania wyników z opisu.
/// - Poprawki użytkownika są osobno (`corrections`): dodane segmenty i odrzucone zakresy czasu.
///   Odrzucenie działa na każdy wykryty segment, który pokrywa się z zakresem, więc przeżywa ponowne
///   wykrywanie (także z innymi granicami). Przesunięcie granic = odrzucenie starego zakresu + dodanie nowego.
/// - Rodzaj (`kind`) i źródło (`source`) to tekst: nieznane wartości z nowszej wersji czytają się bez błędu.
/// - „Reklamy wstawione, ale nie wiadomo gdzie” to pole odcinka (`insertedAds`), nie segment.
/// - Odcisk pliku (`audio`) mówi, do którego pliku pasują czasy; przy niezgodności odtwarzacz nie pomija.
public struct SkipMap: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let formatName = "rapsod-skip"
    /// Nazwa formatu sprzed zmiany nazwy aplikacji (Rapsod). Pliki z nią czytają się
    /// jak bieżące, a przy ponownym zapisie dostają `formatName`.
    public static let legacyFormatNames: Set<String> = ["abswift-skip"]
    public static let fileSuffix = ".skip.json"

    public var format: String
    public var version: Int
    public var generatedAt: Date
    public var episode: EpisodeRef
    public var audio: SkipAudioFingerprint
    public var segments: [SkipSegment]
    /// Reklamy wstawiane dynamicznie, których położenia nie da się ustalić (albo potwierdzenie, że są
    /// i gdzie — wtedy `located == true`, a segmenty są w `segments` ze źródłem `megaphone`).
    public var insertedAds: InsertedAds?
    /// Wzmianki bez czasu albo bez końca (np. „[autopromocja]” na górze opisu) — tylko do pokazania.
    public var notices: [SkipNotice]
    public var corrections: SkipCorrections
    /// Które wykrywania się odbyły (żeby odróżnić „nic nie znaleziono” od „nie sprawdzano”).
    public var runs: [SkipRun]

    public struct EpisodeRef: Codable, Sendable, Equatable {
        public var itemID: String?
        public var episodeID: String?
        public var guid: String?
        public var title: String?
        public var enclosureURL: String?

        public init(itemID: String? = nil, episodeID: String? = nil, guid: String? = nil, title: String? = nil, enclosureURL: String? = nil) {
            self.itemID = itemID
            self.episodeID = episodeID
            self.guid = guid
            self.title = title
            self.enclosureURL = enclosureURL
        }
    }

    public init(episode: EpisodeRef, audio: SkipAudioFingerprint, segments: [SkipSegment] = [], insertedAds: InsertedAds? = nil,
                notices: [SkipNotice] = [], corrections: SkipCorrections = .init(), runs: [SkipRun] = [], generatedAt: Date = .now) {
        self.format = Self.formatName
        self.version = Self.currentVersion
        self.generatedAt = generatedAt
        self.episode = episode
        self.audio = audio
        self.segments = segments
        self.insertedAds = insertedAds
        self.notices = notices
        self.corrections = corrections
        self.runs = runs
    }

    private enum CodingKeys: String, CodingKey {
        case format, version, generatedAt, episode, audio, segments, insertedAds, notices, corrections, runs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let format = try c.decodeIfPresent(String.self, forKey: .format) ?? Self.formatName
        self.format = Self.legacyFormatNames.contains(format) ? Self.formatName : format
        version = try c.decode(Int.self, forKey: .version)
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .distantPast
        episode = try c.decodeIfPresent(EpisodeRef.self, forKey: .episode) ?? .init()
        audio = try c.decode(SkipAudioFingerprint.self, forKey: .audio)
        // Pojedynczy uszkodzony segment nie odbiera reszty.
        segments = (try? c.decodeIfPresent(Lenient<SkipSegment>.self, forKey: .segments))?.values ?? []
        insertedAds = try? c.decodeIfPresent(InsertedAds.self, forKey: .insertedAds)
        notices = (try? c.decodeIfPresent(Lenient<SkipNotice>.self, forKey: .notices))?.values ?? []
        corrections = (try? c.decodeIfPresent(SkipCorrections.self, forKey: .corrections)) ?? .init()
        runs = (try? c.decodeIfPresent(Lenient<SkipRun>.self, forKey: .runs))?.values ?? []
    }

    // MARK: - Plik

    /// Nazwa pliku znaczników dla pliku audio: `Odcinek 12.mp3` → `Odcinek 12.skip.json`.
    public static func fileName(forAudio audioFileName: String) -> String {
        let base = (audioFileName as NSString).deletingPathExtension
        return (base.isEmpty ? audioFileName : base) + fileSuffix
    }

    public static func isSkipFile(_ name: String) -> Bool {
        name.lowercased().hasSuffix(fileSuffix)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public struct Damaged: LocalizedError {
        public var errorDescription: String? { "Plik znaczników jest uszkodzony albo pochodzi z nowszej wersji aplikacji." }
    }

    /// Dekoduje plik i sprawdza, że to naprawdę znaczniki tej aplikacji w znanej wersji.
    public static func decode(_ data: Data) throws -> SkipMap {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let map = try? decoder.decode(SkipMap.self, from: data), map.format == formatName, map.version >= 1, map.version <= currentVersion else {
            throw Damaged()
        }
        return map
    }

    // MARK: - Segmenty po poprawkach

    /// Segmenty do użycia: wykryte bez odrzuconych i bez zdublowanych (model a opis), plus dodane przez
    /// użytkownika, posortowane.
    ///
    /// **Model a zakresy z opisu i rozdziałów (13b).** Ten sam fragment nie jest pokazywany ani pomijany dwa razy:
    /// - Zakres z opisu albo rozdziałów, który pomija się sam (do 3 min, pliki bez reklam w nieznanych
    ///   miejscach), wygrywa z nachodzącym segmentem modelu — na zestawie z rozpoznania jego granice były
    ///   lepsze (Kryminatorium: opis 105–225 s przy prawdzie 104,9–219,4 s, model zgubił środek bloku).
    /// - Zakres niepewny (tylko znacznik: dłuższy niż 3 min albo czasy przesunięte przez wstawione reklamy)
    ///   zastępuje pewny segment modelu, który na niego nachodzi — model wyznacza w nim prawdziwe granice.
    ///   Niepewny segment modelu go nie zastępuje (zostają oba znaczniki).
    /// - Gdzie model nic nie znalazł, zakres z opisu zostaje jak w 13a. Sloty Megaphone zostają zawsze.
    /// Liczy się przy odczycie, nie przy zapisie: ponowne wykrywanie z opisu niczego nie przywraca ani nie dubluje.
    public var effectiveSegments: [SkipSegment] {
        let model = segments.filter { $0.source == .model }
        let hints = segments.filter { Self.supersededSources.contains($0.source) }
        let detected = segments.filter { segment in
            if corrections.removed.contains(where: { $0.rejects(segment) }) { return false }
            if Self.supersededSources.contains(segment.source), !segment.autoSkip {
                return !model.contains { $0.autoSkip && Self.supersedes($0, segment) }
            }
            if segment.source == .model {
                return !hints.contains { $0.autoSkip && Self.supersedes(segment, $0) }
            }
            return true
        }
        return (detected + corrections.added)
            .filter { $0.end > $0.start }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// Źródła zakresów, z którymi segment modelu się nie dubluje (patrz `effectiveSegments`).
    static let supersededSources: Set<SkipSource> = [.description, .chapters]

    /// Segment modelu i zakres z opisu dotyczą tego samego fragmentu: co najmniej 5 s wspólnego czasu
    /// albo połowa krótszego z nich (krótkie autopromocje).
    static func supersedes(_ model: SkipSegment, _ other: SkipSegment) -> Bool {
        let overlap = max(0, min(model.end, other.end) - max(model.start, other.start))
        return overlap >= min(5, 0.5 * min(model.duration, other.duration)) && overlap > 0
    }

    /// Ostatnie uruchomienie modelu (13b), jeśli było.
    public var modelRun: SkipRun? {
        runs.last { $0.source == .model }
    }

    /// Wynik wykrywania jednego źródła zastępuje jego poprzednie segmenty; reszta (inne źródła,
    /// poprawki) zostaje.
    public func replacingSegments(from source: SkipSource, with fresh: [SkipSegment]) -> SkipMap {
        var copy = self
        copy.segments = segments.filter { $0.source != source } + fresh.filter { $0.source == source }
        return copy
    }

    /// Przenosi poprawki użytkownika (i segmenty źródeł, które tym razem nie liczyły) z poprzedniej
    /// wersji pliku — wywołuje Mac przy ponownym liczeniu.
    public func carryingOver(from previous: SkipMap, keeping sources: Set<SkipSource>) -> SkipMap {
        var copy = self
        copy.corrections = previous.corrections
        let kept = previous.segments.filter { sources.contains($0.source) }
        copy.segments = segments.filter { !sources.contains($0.source) } + kept
        let ranNow = Set(runs.map(\.source))
        copy.runs = runs + previous.runs.filter { sources.contains($0.source) && !ranNow.contains($0.source) }
        return copy
    }

    // MARK: - Poprawki

    /// Usuwa segment: dodany przez użytkownika znika, wykryty — trafia do odrzuconych.
    public mutating func remove(_ segment: SkipSegment) {
        if let index = corrections.added.firstIndex(where: { $0.id == segment.id }) {
            corrections.added.remove(at: index)
        } else {
            corrections.removed.append(.init(start: segment.start, end: segment.end))
        }
    }

    /// Nowe granice (albo rodzaj) segmentu. Wykryty zostaje odrzucony i zastąpiony segmentem użytkownika.
    public mutating func adjust(_ segment: SkipSegment, start: Double, end: Double, kind: SkipKind? = nil) {
        let range = SkipSegment.clamped(start: start, end: end, duration: audio.duration)
        // Poprawka wykrytego segmentu ma stały identyfikator — kolejna edycja (także z nieaktualnego
        // widoku) nadpisuje ją zamiast dokładać duplikat.
        let editID = segment.source == .user ? segment.id : segment.id + "-edit"
        if let index = corrections.added.firstIndex(where: { $0.id == segment.id || $0.id == editID }) {
            corrections.added[index].start = range.start
            corrections.added[index].end = range.end
            if let kind { corrections.added[index].kind = kind }
            return
        }
        let rejected = SkipTimeRange(start: segment.start, end: segment.end)
        if !corrections.removed.contains(rejected) { corrections.removed.append(rejected) }
        corrections.added.append(SkipSegment(id: editID, start: range.start, end: range.end, kind: kind ?? segment.kind, source: .user,
                                             confidence: 1, label: segment.label))
    }

    /// Dodaje segment użytkownika.
    @discardableResult
    public mutating func add(start: Double, end: Double, kind: SkipKind) -> SkipSegment {
        let range = SkipSegment.clamped(start: start, end: end, duration: audio.duration)
        let segment = SkipSegment(start: range.start, end: range.end, kind: kind, source: .user, confidence: 1)
        corrections.added.append(segment)
        return segment
    }

    /// Bez poprawek użytkownika (przywraca wynik wykrywania).
    public mutating func resetCorrections() {
        corrections = .init()
    }
}

// MARK: - Segment

/// Rodzaj segmentu. Kategorie z ustaleń użytkownika: sponsor (reklama czytana i wstawiana)
/// i autopromocja (własne produkty, książki, newsletter, zbiórki prowadzącego).
public struct SkipKind: RawRepresentable, Codable, Sendable, Hashable, CaseIterable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let sponsor = SkipKind(rawValue: "sponsor")
    public static let selfPromo = SkipKind(rawValue: "selfpromo")
    public static let allCases: [SkipKind] = [.sponsor, .selfPromo]

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// Nazwa w interfejsie (rzeczownik).
    public var title: String {
        switch self {
        case .sponsor: "Reklama"
        case .selfPromo: "Autopromocja"
        default: "Segment"
        }
    }
}

/// Skąd wziął się segment. 13a: opis odcinka, rozdziały, nagłówek Megaphone, użytkownik;
/// 13b dopisze `model` (i ewentualnie inne) bez zmiany formatu.
public struct SkipSource: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let description = SkipSource(rawValue: "description")
    public static let chapters = SkipSource(rawValue: "chapters")
    public static let megaphone = SkipSource(rawValue: "megaphone")
    /// Różnica `itunes:duration` z kanału i długości pliku (tylko w `insertedAds`).
    public static let durationDifference = SkipSource(rawValue: "duration")
    public static let user = SkipSource(rawValue: "user")
    /// Zarezerwowane dla etapu 13b (transkrypcja i klasyfikator).
    public static let model = SkipSource(rawValue: "model")

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var title: String {
        switch self {
        case .description: "opis odcinka"
        case .chapters: "rozdziały"
        case .megaphone: "nagłówek Megaphone"
        case .durationDifference: "długość pliku"
        case .user: "poprawka ręczna"
        case .model: "model językowy"
        default: rawValue
        }
    }
}

public struct SkipSegment: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Sekundy na osi czasu pliku audio.
    public var start: Double
    public var end: Double
    public var kind: SkipKind
    public var source: SkipSource
    /// 0…1. Źródła 13a są pewne co do istnienia segmentu; granice z opisu mają dokładność wpisu w opisie.
    public var confidence: Double
    /// Skąd dokładnie (np. wiersz opisu „1:45 – [autopromocja] Akta tajemnic”).
    public var label: String?
    /// `false` — tylko znacznik, bez automatycznego pomijania (np. czasy z opisu, gdy plik ma
    /// wstawione reklamy w nieznanych miejscach i czasy mogą być przesunięte).
    public var autoSkip: Bool

    public init(id: String = UUID().uuidString, start: Double, end: Double, kind: SkipKind, source: SkipSource, confidence: Double,
                label: String? = nil, autoSkip: Bool = true) {
        self.id = id
        self.start = start
        self.end = end
        self.kind = kind
        self.source = source
        self.confidence = confidence
        self.label = label
        self.autoSkip = autoSkip
    }

    private enum CodingKeys: String, CodingKey { case id, start, end, kind, source, confidence, label, autoSkip }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        kind = try c.decodeIfPresent(SkipKind.self, forKey: .kind) ?? .sponsor
        source = try c.decodeIfPresent(SkipSource.self, forKey: .source) ?? .user
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
        label = try c.decodeIfPresent(String.self, forKey: .label)
        autoSkip = try c.decodeIfPresent(Bool.self, forKey: .autoSkip) ?? true
        guard start.isFinite, end.isFinite, end > start, start >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .end, in: c, debugDescription: "Nieprawidłowy zakres segmentu")
        }
    }

    public var duration: Double { end - start }

    static func clamped(start: Double, end: Double, duration: Double) -> (start: Double, end: Double) {
        let limit = duration > 0 ? duration : .greatestFiniteMagnitude
        let a = min(max(0, start), limit)
        let b = min(max(a + 1, end), limit)
        return (a, max(a, b))
    }
}

/// Zakres czasu odrzucony przez użytkownika („to nie reklama”).
public struct SkipTimeRange: Codable, Sendable, Hashable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    /// Wykryty segment, który w większości (≥ 50% swojej długości) leży w odrzuconym zakresie.
    public func rejects(_ segment: SkipSegment) -> Bool {
        let overlap = max(0, min(end, segment.end) - max(start, segment.start))
        return overlap >= 0.5 * max(segment.duration, 0.001)
    }
}

public struct SkipCorrections: Codable, Sendable, Equatable {
    public var added: [SkipSegment]
    public var removed: [SkipTimeRange]

    public init(added: [SkipSegment] = [], removed: [SkipTimeRange] = []) {
        self.added = added
        self.removed = removed
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }

    private enum CodingKeys: String, CodingKey { case added, removed }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        added = (try? c.decodeIfPresent(Lenient<SkipSegment>.self, forKey: .added))?.values ?? []
        removed = (try? c.decodeIfPresent([SkipTimeRange].self, forKey: .removed)) ?? []
    }
}

/// Reklamy wstawiane dynamicznie (DAI).
public struct InsertedAds: Codable, Sendable, Equatable {
    /// `megaphone` albo `duration`.
    public var source: SkipSource
    /// Ile sekund pliku to reklamy wstawione (z różnicy długości albo z sumy slotów).
    public var seconds: Double?
    /// Liczba wypełnionych slotów (Megaphone).
    public var slots: Int?
    /// Położenia są znane (segmenty `megaphone` w `segments`).
    public var located: Bool
    public var note: String?

    public init(source: SkipSource, seconds: Double?, slots: Int? = nil, located: Bool, note: String? = nil) {
        self.source = source
        self.seconds = seconds
        self.slots = slots
        self.located = located
        self.note = note
    }
}

/// Wzmianka bez zakresu czasu (bez czasu albo bez końca) — do pokazania, nie do pomijania.
public struct SkipNotice: Codable, Sendable, Hashable {
    public var kind: SkipKind
    public var source: SkipSource
    public var text: String
    /// Czas początku, jeśli opis go podaje (bez końca).
    public var time: Double?

    public init(kind: SkipKind, source: SkipSource, text: String, time: Double? = nil) {
        self.kind = kind
        self.source = source
        self.text = text
        self.time = time
    }
}

/// Jedno uruchomienie wykrywania.
public struct SkipRun: Codable, Sendable, Hashable {
    public var source: SkipSource
    public var date: Date
    /// Np. wersja reguł albo nazwa modelu (13b).
    public var detail: String?

    public init(source: SkipSource, date: Date = .now, detail: String? = nil) {
        self.source = source
        self.date = date
        self.detail = detail
    }
}

// MARK: - Odcisk pliku

/// Do którego pliku audio pasują czasy: rozmiar, długość i skrót SHA-256 pierwszych i ostatnich 64 KiB.
public struct SkipAudioFingerprint: Codable, Sendable, Equatable {
    public var filename: String?
    public var size: Int64?
    public var duration: Double
    public var headSHA256: String?
    public var tailSHA256: String?

    public static let chunk = 64 * 1024
    /// Tolerancja długości: dekodery liczą długość MP3 różnie o ułamki sekundy.
    public static let durationTolerance: Double = 1.0

    public init(filename: String? = nil, size: Int64? = nil, duration: Double, headSHA256: String? = nil, tailSHA256: String? = nil) {
        self.filename = filename
        self.size = size
        self.duration = duration
        self.headSHA256 = headSHA256
        self.tailSHA256 = tailSHA256
    }

    /// Odcisk pliku na dysku (czyta tylko dwa fragmenty po 64 KiB).
    public static func of(fileAt url: URL, duration: Double) throws -> SkipAudioFingerprint {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int64(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: chunk) ?? Data()
        let tailStart = max(0, size - Int64(chunk))
        try handle.seek(toOffset: UInt64(tailStart))
        let tail = try handle.read(upToCount: chunk) ?? Data()
        return SkipAudioFingerprint(filename: url.lastPathComponent, size: size, duration: duration,
                                    headSHA256: sha256(head), tailSHA256: sha256(tail))
    }

    /// Rozmiar nagłówka ID3v2 na początku pliku (0, gdy go nie ma).
    public static func id3Size(fileAt url: URL) -> Int64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 10) else { return 0 }
        return id3Size(head)
    }

    static func id3Size(_ head: Data) -> Int64 {
        let b = [UInt8](head.prefix(10))
        guard b.count == 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return 0 }
        let size = (Int64(b[6] & 0x7f) << 21) | (Int64(b[7] & 0x7f) << 14) | (Int64(b[8] & 0x7f) << 7) | Int64(b[9] & 0x7f)
        return size + 10 + (b[5] & 0x10 != 0 ? 10 : 0)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public enum Match: Sendable, Equatable {
        /// Ten sam plik (rozmiar albo skróty zgodne, długość w tolerancji).
        case exact
        /// Długość w tolerancji, nic więcej do porównania (np. strumień).
        case duration
        /// Inny plik — bez automatycznego pomijania.
        case mismatch(String)

        public var allowsSkipping: Bool { if case .mismatch = self { false } else { true } }
    }

    /// Czy znaczniki policzone dla `self` pasują do odtwarzanego pliku `actual`.
    public func match(_ actual: SkipAudioFingerprint) -> Match {
        if let a = size, let b = actual.size, a != b { return .mismatch("inny rozmiar pliku") }
        if let a = headSHA256, let b = actual.headSHA256, a != b { return .mismatch("inny początek pliku") }
        if let a = tailSHA256, let b = actual.tailSHA256, a != b { return .mismatch("inny koniec pliku") }
        guard duration > 0, actual.duration > 0 else { return .mismatch("nieznana długość") }
        if abs(duration - actual.duration) > Self.durationTolerance {
            return .mismatch("inna długość (\(Int(duration.rounded())) s zamiast \(Int(actual.duration.rounded())) s)")
        }
        let comparedContent = (size != nil && actual.size != nil) || (headSHA256 != nil && actual.headSHA256 != nil)
        return comparedContent ? .exact : .duration
    }
}

/// Tablica, w której uszkodzony element jest pomijany zamiast psuć całość.
struct Lenient<Element: Decodable>: Decodable {
    var values: [Element]

    init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var values: [Element] = []
        while !c.isAtEnd {
            if let value = try? c.decode(Element.self) {
                values.append(value)
            } else {
                if (try? c.decode(AudiobookshelfClient.JSONValue.self)) == nil { break }
            }
        }
        self.values = values
    }

}
