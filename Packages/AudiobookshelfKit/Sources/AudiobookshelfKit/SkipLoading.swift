// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 13a).

import Foundation
import OSLog

private let logger = Logger(subsystem: "net.smigi.rapsod", category: "Skip")

/// Plik znaczników odcinka na serwerze: leży obok pliku audio w folderze podcastu i jest jednym
/// z plików pozycji (`libraryFiles`), więc każde konto z dostępem pobierze go przez
/// `GET /api/items/:id/file/:ino` — jak mapę tekstu (etap 11b).
public enum SkipMapLoader {
    /// Plik audio odcinka i jego plik znaczników wśród plików pozycji.
    public struct Located: Sendable {
        public var episode: AudiobookshelfClient.PodcastEpisode
        public var audioSize: Int64?
        public var audioFileName: String?
        public var skipFile: AudiobookshelfClient.ItemDetail.LibraryFile?

        /// Długość odcinka według serwera (plik audio, a bez niego — odcinek).
        public var audioDuration: Double? {
            (episode.audioFile?.duration ?? episode.duration).flatMap { $0 > 0 ? $0 : nil }
        }

        /// Odcisk pliku odcinka na serwerze, bez pobierania nagrania (rozmiar i długość) — do znaczników
        /// oglądanych bez odtwarzania (menu odcinka). `duration` — długość znana skądinąd (np. z odtwarzacza).
        public func streamFingerprint(duration: Double? = nil) -> SkipAudioFingerprint? {
            guard let length = duration ?? audioDuration else { return nil }
            return SkipAudioFingerprint(size: audioSize, duration: length)
        }
    }

    public static func locate(episodeID: String, in item: AudiobookshelfClient.ItemDetail) -> Located? {
        guard let episode = item.media.episodes?.elements.first(where: { $0.id == episodeID }) else { return nil }
        let audioPath = episode.audioFile?.metadata?.path
        let audioName = episode.audioFile?.metadata?.filename ?? audioPath.map { ($0 as NSString).lastPathComponent }
        var skipFile: AudiobookshelfClient.ItemDetail.LibraryFile?
        if let audioName {
            let name = SkipMap.fileName(forAudio: audioName)
            let folder = audioPath.map { ($0 as NSString).deletingLastPathComponent }
            skipFile = item.libraryFiles?.elements.first { file in
                guard file.metadata.filename == name else { return false }
                guard let folder, let path = file.metadata.path else { return true }
                return (path as NSString).deletingLastPathComponent == folder
            }
        }
        return Located(episode: episode, audioSize: episode.audioFile?.metadata?.size.map { Int64($0) }, audioFileName: audioName, skipFile: skipFile)
    }

    /// Znaczniki odcinka z serwera; `nil` — nie ma pliku albo jest uszkodzony.
    public static func load(episodeID: String, item: AudiobookshelfClient.ItemDetail,
                            fetchFile: @Sendable (_ ino: String) async throws -> Data) async -> (located: Located, map: SkipMap?, data: Data?)? {
        guard let located = locate(episodeID: episodeID, in: item) else { return nil }
        guard let file = located.skipFile else { return (located, nil, nil) }
        do {
            let data = try await fetchFile(file.ino)
            return (located, try SkipMap.decode(data), data)
        } catch {
            logger.error("Znaczniki odcinka \(episodeID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return (located, nil, nil)
        }
    }
}

/// Zapytania do wydawcy potrzebne przy wykrywaniu (Mac po pobraniu odcinka, iOS dla odcinka z kanału).
public enum SkipNetwork {
    /// Adres wygląda na plik składany przez Megaphone (także za przedrostkami statystyk, np. Podtrac).
    public static func isMegaphone(_ url: URL) -> Bool {
        url.absoluteString.lowercased().contains("megaphone.fm/")
    }

    /// Nagłówek `x-megaphone-payload-2` i całkowity rozmiar pliku z odpowiedzi na zapytanie o jeden
    /// bajt (bez pobierania nagrania). `nil` — nie Megaphone albo brak nagłówka.
    public static func megaphone(for url: URL, session: URLSession = .shared) async -> (payload: MegaphonePayload, totalSize: Int64?)? {
        guard isMegaphone(url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, let header = http.value(forHTTPHeaderField: MegaphonePayload.headerName),
                  let payload = MegaphonePayload.parse(header) else { return nil }
            let total = MegaphonePayload.totalSize(contentRange: http.value(forHTTPHeaderField: "Content-Range"))
                ?? (http.statusCode == 200 ? http.expectedContentLength : nil)
            return (payload, total.flatMap { $0 > 0 ? $0 : nil })
        } catch {
            logger.notice("Nagłówek Megaphone: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Rozdziały z pliku JSON Podcasting 2.0 (do 1 MB).
    public static func chapters(from url: URL, duration: Double, session: URLSession = .shared) async -> [SkipDetection.Chapter] {
        guard let (data, response) = try? await session.data(for: URLRequest(url: url, timeoutInterval: 20)),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000 else { return [] }
        return RSSChapter.parseJSON(data, duration: duration)
    }
}

/// Poprawki znaczników zrobione na telefonie (iOS nie zapisuje plików w folderze podcastu na Macu).
/// Jeden plik na odcinek; przy wczytaniu poprawki nakładają się na znaczniki z serwera.
public struct SkipCorrectionsStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func standard() -> SkipCorrectionsStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SkipCorrectionsStore(directory: support.appending(path: "SkipCorrections", directoryHint: .isDirectory))
    }

    private func url(_ key: String) -> URL {
        directory.appending(path: DownloadedItem.folderName(for: key) + ".json")
    }

    /// Zapisane poprawki odcinka (klucz odtwarzacza: pozycja i odcinek albo odcinek z kanału).
    public func corrections(key: String, audio: SkipAudioFingerprint) -> SkipCorrections? {
        guard let data = try? Data(contentsOf: url(key)), let stored = try? SkipMap.decode(data),
              stored.audio.match(audio).allowsSkipping else { return nil }
        return stored.corrections
    }

    public func save(_ map: SkipMap, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var copy = map
        copy.segments = []
        try copy.encoded().write(to: url(key), options: .atomic)
    }

    public func remove(key: String) {
        try? FileManager.default.removeItem(at: url(key))
    }

    /// Znaczniki z serwera (albo z kanału) z poprawkami z telefonu: dodane i odrzucone z obu stron.
    public static func merged(_ map: SkipMap, with local: SkipCorrections?) -> SkipMap {
        guard let local, !local.isEmpty else { return map }
        var copy = map
        let known = Set(copy.corrections.added.map(\.id))
        copy.corrections.added += local.added.filter { !known.contains($0.id) }
        copy.corrections.removed += local.removed.filter { !copy.corrections.removed.contains($0) }
        return copy
    }
}
