// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu — wydzielony z odtwarzacza aplikacji na Maca
// (`AudiobookSwift/Listening/AudiobookPlayer.swift`, który sam wywodzi się z Dove, MPL-2.0)
// i z `ListeningController.swift` / `ChapterTitles.swift` (napisane w etapie 9a, nie tłumaczone
// z audiobookshelf). Same wartości i obliczenia — bez AVFoundation, więc łatwe do testów.

import Foundation
import AudiobookshelfKit

/// Plik audio książki na wspólnej osi czasu.
public struct PlaybackTrack: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// Plik z dysku (pobrany albo serwer na tym samym komputerze).
        case file(URL)
        /// Plik przez otwartą sesję: `public/session/<sesja>/track/<index>`. Identyfikator
        /// sesji jest jedynym „kluczem”, więc ani klucz API, ani nagłówek nie są potrzebne.
        case sessionTrack(index: Int)
        /// Transkodowanie (HLS): `hls/<sesja>/output.m3u8`, też bez uwierzytelniania.
        case sessionStream
        /// Plik wprost od wydawcy podcastu (adres `enclosure` z kanału RSS, etap 10e) —
        /// bez serwera, bez sesji i bez żadnego klucza w adresie.
        case remote(URL)
        /// Plik pozycji serwera czytany prosto z dysku — serwer działa na tym samym komputerze
        /// (aplikacja na Maca, etap 12). Postęp idzie przez sesję serwera jak przy `.sessionTrack`;
        /// w odróżnieniu od `.file` to nie jest pozycja pobrana na urządzenie.
        case serverFile(URL)

        /// Plik przez sesję serwera audiobookshelf (adres zależy od bieżącego adresu serwera).
        public var isServer: Bool {
            switch self {
            case .sessionTrack, .sessionStream: true
            case .file, .remote, .serverFile: false
            }
        }
    }

    /// Początek pliku na osi czasu książki — z serwera, nie z AVFoundation
    /// (długości plików według obu potrafią się różnić o ułamki sekund).
    public let startOffset: Double
    public let duration: Double
    public let title: String
    public var source: Source

    public var end: Double { startOffset + duration }

    public init(startOffset: Double, duration: Double, title: String, source: Source) {
        self.startOffset = startOffset
        self.duration = duration
        self.title = title
        self.source = source
    }
}

public struct PlaybackChapter: Sendable, Hashable, Identifiable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let title: String

    public var duration: Double { end - start }

    public init(id: Int, start: Double, end: Double, title: String) {
        self.id = id
        self.start = start
        self.end = end
        self.title = title
    }
}

/// Książka (albo odcinek podcastu) załadowana do odtwarzacza.
public struct PlaybackBook: Sendable, Equatable {
    public let itemID: String
    public let episodeID: String?
    public let title: String
    public let author: String?
    public let duration: Double
    public var tracks: [PlaybackTrack]
    public var chapters: [PlaybackChapter]
    public var coverPath: String?
    /// Odcinek z kanału RSS, którego (jeszcze) nie ma na serwerze: `RSSEpisode.id`.
    /// Wtedy `episodeID == nil`, a `itemID` to podcast na serwerze.
    public var feedKey: String?

    public var key: String {
        feedKey.map { PlaybackTimeline.feedKey(itemID, $0) } ?? PlaybackTimeline.key(itemID, episodeID)
    }

    public init(itemID: String, episodeID: String?, title: String, author: String?, duration: Double, tracks: [PlaybackTrack], chapters: [PlaybackChapter], coverPath: String? = nil, feedKey: String? = nil) {
        self.itemID = itemID
        self.episodeID = episodeID
        self.title = title
        self.author = author
        self.duration = duration
        self.tracks = tracks
        self.chapters = chapters
        self.coverPath = coverPath
        self.feedKey = feedKey
    }
}

public enum SleepTimer: Hashable, Sendable {
    case minutes(Int)
    /// Zatrzymuje się na końcu bieżącego rozdziału.
    case endOfChapter

    public static let choices: [SleepTimer] = [.minutes(5), .minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfChapter]

    public var label: String {
        switch self {
        case .minutes(let minutes): "\(minutes) min"
        case .endOfChapter: "Do końca rozdziału"
        }
    }
}

/// Miejsce w bieżącym rozdziale — do suwaka „w obrębie rozdziału”.
public struct ChapterPosition: Sendable, Equatable {
    public let chapter: PlaybackChapter?
    /// Początek przedziału na osi książki (początek rozdziału albo 0).
    public let start: Double
    /// Długość przedziału (rozdziału albo całej książki).
    public let length: Double
    /// Czas od początku przedziału, 0…length.
    public let elapsed: Double

    public var remaining: Double { max(0, length - elapsed) }
    public var fraction: Double { length > 0 ? elapsed / length : 0 }

    /// Pozycja na osi książki dla wartości suwaka (sekundy od początku rozdziału).
    public func bookTime(forElapsed value: Double) -> Double {
        start + min(max(0, value), length)
    }
}

/// Obliczenia na osi czasu książki.
public enum PlaybackTimeline {
    public static func key(_ itemID: String, _ episodeID: String?) -> String {
        episodeID.map { "\(itemID)/\($0)" } ?? itemID
    }

    /// Klucz odcinka słuchanego wprost z kanału (nie myli się z identyfikatorem odcinka serwera).
    public static func feedKey(_ itemID: String, _ feedKey: String) -> String {
        "\(itemID)/feed:\(feedKey)"
    }

    // MARK: Pliki

    /// Plik obejmujący `time`.
    public static func trackIndex(in tracks: [PlaybackTrack], at time: Double) -> Int {
        tracks.lastIndex { $0.startOffset <= time + 0.001 } ?? 0
    }

    /// Czas w pliku, przycięty do jego długości według serwera.
    public static func localTime(_ time: Double, in track: PlaybackTrack) -> Double {
        min(max(0, time - track.startOffset), max(0, track.duration - 0.25))
    }

    /// Pozycja na osi książki z czasu odtwarzanego pliku.
    public static func bookTime(local: Double, in track: PlaybackTrack) -> Double {
        let local = local.isFinite ? max(0, local) : 0
        return min(track.startOffset + local, track.end)
    }

    /// Miejsce, do którego wolno przewinąć: książka „kończy się” pół sekundy przed końcem,
    /// żeby przewinięcie na sam koniec nie ominęło zdarzenia końca pliku.
    public static func clamp(_ time: Double, duration: Double) -> Double {
        min(max(0, time), max(0, duration - 0.5))
    }

    /// Co po końcu pliku `index`: następny plik albo koniec książki.
    public enum AfterTrack: Equatable, Sendable {
        case next(index: Int, startsAt: Double)
        case finished
    }

    public static func afterTrack(_ index: Int, in tracks: [PlaybackTrack]) -> AfterTrack {
        let next = index + 1
        guard tracks.indices.contains(next) else { return .finished }
        return .next(index: next, startsAt: tracks[next].startOffset)
    }

    // MARK: Rozdziały

    /// Rozdział w chwili `time` (pół sekundy zapasu: przewinięcie na początek rozdziału
    /// bywa minimalnie przed nim).
    public static func chapter(in chapters: [PlaybackChapter], at time: Double) -> PlaybackChapter? {
        chapters.last { $0.start <= time + 0.5 } ?? chapters.first
    }

    public static func nextChapter(in chapters: [PlaybackChapter], at time: Double) -> PlaybackChapter? {
        guard let current = chapter(in: chapters, at: time), let index = chapters.firstIndex(of: current),
              chapters.indices.contains(index + 1) else { return nil }
        return chapters[index + 1]
    }

    /// Początek bieżącego rozdziału albo poprzedni, gdy ten dopiero się zaczął (≤ 3 s).
    public static func previousChapterTarget(in chapters: [PlaybackChapter], at time: Double) -> PlaybackChapter? {
        guard let current = chapter(in: chapters, at: time), let index = chapters.firstIndex(of: current) else { return nil }
        if time - current.start > 3 || index == 0 { return current }
        return chapters[index - 1]
    }

    /// Suwak w obrębie rozdziału; bez rozdziałów — w obrębie całej książki.
    public static func chapterPosition(in chapters: [PlaybackChapter], at time: Double, duration: Double) -> ChapterPosition {
        guard let chapter = chapter(in: chapters, at: time), chapter.duration > 0 else {
            return ChapterPosition(chapter: nil, start: 0, length: duration, elapsed: min(max(0, time), duration))
        }
        return ChapterPosition(chapter: chapter, start: chapter.start, length: chapter.duration, elapsed: min(max(0, time - chapter.start), chapter.duration))
    }

    /// Czy timer „do końca rozdziału” kończy się razem z plikiem `track`.
    public static func chapterEndsWithTrack(_ chapter: PlaybackChapter, _ track: PlaybackTrack) -> Bool {
        chapter.end <= track.end + 0.5
    }

    // MARK: Z sesji serwera

    /// Pliki z sesji. Przy transkodowaniu serwer zwraca jeden „plik” — strumień HLS.
    /// `localFile` — plik serwera dostępny na tym komputerze (ścieżka z serwera → adres pliku
    /// do odczytu albo `nil`); wtedy dźwięk idzie prosto z dysku zamiast przez HTTP.
    public static func tracks(from session: AudiobookshelfClient.PlaybackSession, localFile: ((String) -> URL?)? = nil) -> [PlaybackTrack] {
        let transcoded = session.playMethod == 2
        return session.audioTracks.map { track in
            let fileName = track.metadata?.path.map { ($0 as NSString).lastPathComponent }
            let source: PlaybackTrack.Source
            if transcoded {
                source = .sessionStream
            } else if let path = track.metadata?.path, let url = localFile?(path) {
                source = .serverFile(url)
            } else {
                source = .sessionTrack(index: track.index)
            }
            return PlaybackTrack(
                startOffset: track.startOffset,
                duration: track.duration,
                title: track.title ?? fileName ?? "Plik \(track.index)",
                source: source
            )
        }
    }

    /// Rozdziały z serwera; bez nich — po jednym na plik.
    public static func chapters(from session: AudiobookshelfClient.PlaybackSession, tracks: [PlaybackTrack]) -> [PlaybackChapter] {
        if !session.chapters.isEmpty {
            let titles = displayTitles(session.chapters.map(\.title))
            return session.chapters.enumerated().map {
                PlaybackChapter(id: $0.offset, start: $0.element.start, end: $0.element.end, title: titles[$0.offset])
            }
        }
        let titles = displayTitles(tracks.map(\.title))
        return tracks.enumerated().map {
            PlaybackChapter(id: $0.offset, start: $0.element.startOffset, end: $0.element.end,
                            title: tracks.count == 1 ? (session.displayTitle ?? $0.element.title) : titles[$0.offset])
        }
    }

    /// Kontenery, których AVFoundation nie otwiera (sprawdzone na macOS 27 w etapie 9a: WMA,
    /// Matroska, WebM) — dla nich serwer transkoduje do HLS.
    public static let unplayableExtensions: Set<String> = ["wma", "mka", "webm", "webma"]

    public static func needsTranscoding(_ session: AudiobookshelfClient.PlaybackSession) -> Bool {
        session.audioTracks.contains { track in
            let ext = ((track.metadata?.path ?? track.contentUrl) as NSString).pathExtension.lowercased()
            return unplayableExtensions.contains(ext)
        }
    }

    /// Tytuły rozdziałów do pokazania. Książki bez opisanych rozdziałów mają tytuły z nazw plików,
    /// np. „38 Polskie morderczynie”: różnią się tylko numerem — zamieniamy je na „Rozdział 1”…
    public static func displayTitles(_ titles: [String]) -> [String] {
        guard titles.count > 1 else { return titles }
        let noise = CharacterSet.decimalDigits.union(.whitespacesAndNewlines).union(.punctuationCharacters)
        let stems = Set(titles.map { $0.trimmingCharacters(in: noise).lowercased() })
        guard stems.count == 1 else { return titles }
        return titles.indices.map { "Rozdział \($0 + 1)" }
    }

    // MARK: Wznowienie

    /// Start od pozycji z serwera kilka sekund wcześniej: wejście w połowie zdania trudno śledzić.
    public static func rewoundStart(_ position: Double) -> Double {
        max(0, position - (position > 10 ? 3 : 0))
    }
}
