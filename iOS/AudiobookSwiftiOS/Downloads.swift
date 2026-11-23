// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 10f).

import Foundation
import Observation
import OSLog
import UIKit
import AudiobookshelfKit
import AudiobookshelfPlayback

private let logger = Logger(subsystem: "net.smigi.abswift.ios", category: "Downloads")

/// Pobieranie na telefon: menedżer z pakietu (sesja tła), ustawienia „skąd pobierać”, budowa
/// wpisów z danych serwera i książka z plików dla odtwarzacza. Żyje tyle, co aplikacja — system
/// może ją obudzić w tle tylko po to, żeby oddać pobrane pliki.
@MainActor
final class DownloadsController {
    /// Ustawienie „Usuwaj pobrane po wysłuchaniu” (etap 10i).
    static let removeFinishedKey = "downloads.removeFinished"
    static let sessionIdentifier = "net.smigi.abswift.ios.downloads"
    /// Zakończenie od systemu, gdy obudził aplikację dla sesji pobierania, zanim powstał kontroler.
    static var pendingBackgroundCompletion: (() -> Void)?
    static weak var current: DownloadsController?

    static let wifiOnlyKey = "downloads.wifiOnly"
    static let tunnelKey = "downloads.allowTunnel"

    let manager: DownloadManager
    /// System obudził aplikację dla pobierania — warto sprawdzić połączenie (kolejne pliki).
    var backgroundWake: (() -> Void)?

    var policy: DownloadPolicy {
        let defaults = UserDefaults.standard
        return DownloadPolicy(
            wifiOnly: defaults.object(forKey: Self.wifiOnlyKey) as? Bool ?? true,
            allowsTunnel: defaults.bool(forKey: Self.tunnelKey)
        )
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appending(path: "Downloads")
        manager = DownloadManager(
            configuration: DownloadManager.backgroundConfiguration(identifier: Self.sessionIdentifier),
            directory: directory,
            indexURL: support.appending(path: "downloads-index.json")
        )
        if let completion = Self.pendingBackgroundCompletion {
            manager.backgroundEventsCompletion = completion
            Self.pendingBackgroundCompletion = nil
        }
        Self.current = self
    }

    /// Stan połączenia zamieniony na bramkę: adres, którym telefon właśnie rozmawia z serwerem.
    func updateGate(connectedURL: URL?, isLocalAddress: Bool, onWiFi: Bool) {
        manager.setGate(policy.gate(baseURL: connectedURL, isLocalAddress: isLocalAddress, onWiFi: onWiFi))
    }

    // MARK: - Dodawanie

    enum AddError: LocalizedError {
        case noFiles
        var errorDescription: String? { "Na serwerze nie ma plików audio tej pozycji." }
    }

    /// Książka: wszystkie ścieżki (w kolejności serwera), rozdziały, okładka.
    func download(book item: Client.ItemDetail, session: ServerSession) async throws {
        let tracks = (item.media.tracks?.elements ?? []).sorted { $0.index < $1.index }
        var offset = 0.0
        let files: [DownloadedFile] = tracks.compactMap { track in
            guard let ino = track.ino else { return nil }
            let duration = track.duration ?? 0
            let start = track.startOffset ?? offset
            offset = start + duration
            let name = track.metadata?.filename
            return DownloadedFile(
                ino: ino, index: track.index, fileName: DownloadedFile.localName(index: track.index, ino: ino, originalName: name),
                title: name.map { ($0 as NSString).deletingPathExtension } ?? "Plik \(track.index)",
                startOffset: start, duration: duration, expectedSize: track.metadata?.size.map { Int64($0) }
            )
        }
        guard !files.isEmpty else { throw AddError.noFiles }
        let entry = DownloadedItem(
            scope: session.scope, itemID: item.id, episodeID: nil, libraryID: item.libraryId, mediaType: "book",
            title: item.title, author: item.media.metadata.authors?.map(\.name).joined(separator: ", "),
            duration: item.media.duration ?? offset,
            chapters: (item.media.chapters ?? []).map { DownloadedChapter(start: $0.start, end: $0.end, title: $0.title) },
            files: files
        )
        try manager.enqueue(entry, cover: await coverData(itemID: item.id, session: session), textSync: await textSyncData(item: item, session: session))
        if let progress = session.library.progress.value(item.id) { session.journal.recordServer(progress) }
    }

    /// Mapa tekstu książki (etap 11b), żeby tryb „Tekst” działał bez sieci. Mała (kilka MB),
    /// więc pobiera się od razu, nie przez sesję tła; brak albo błąd nie blokuje pobrania audio.
    private func textSyncData(item: Client.ItemDetail, session: ServerSession) async -> Data? {
        guard let file = TextSyncMap.file(in: item) else { return nil }
        guard let data = try? await session.auth.perform({ try await $0.libraryFile(itemID: item.id, ino: file.ino, token: $1) }),
              (try? TextSyncLoader.decode(data)) != nil
        else {
            logger.error("Mapa tekstu \(item.id, privacy: .public) nie pobrała się z książką")
            return nil
        }
        return data
    }

    /// Odcinek podcastu, który jest na serwerze.
    func download(episode: Client.PodcastEpisode, itemID: String, podcastTitle: String?, libraryID: String?, session: ServerSession) async throws {
        var episode = episode
        if episode.audioFile?.ino == nil {
            // Półki odcinków nie zawsze mają opis pliku — pełna pozycja podcastu go ma.
            let item = try await session.auth.perform { try await $0.item(id: itemID, token: $1) }
            if let full = item.media.episodes?.elements.first(where: { $0.id == episode.id }) { episode = full }
        }
        guard let ino = episode.audioFile?.ino else { throw AddError.noFiles }
        let duration = episode.length ?? 0
        let name = episode.audioFile?.metadata?.filename
        let file = DownloadedFile(
            ino: ino, index: 1, fileName: DownloadedFile.localName(index: 1, ino: ino, originalName: name),
            title: episode.title ?? "Odcinek", startOffset: 0, duration: duration,
            expectedSize: (episode.audioFile?.metadata?.size ?? episode.size).map { Int64($0) }
        )
        let entry = DownloadedItem(
            scope: session.scope, itemID: itemID, episodeID: episode.id, libraryID: libraryID, mediaType: "podcast",
            title: episode.title ?? "Odcinek", author: podcastTitle ?? episode.podcast?.metadata?.title, duration: duration,
            chapters: [], files: [file]
        )
        try manager.enqueue(entry, cover: await coverData(itemID: itemID, session: session))
        // Znaczniki segmentów sponsorowanych (etap 13a) — pomijanie działa też bez sieci.
        await SkipSupport.downloadWithEpisode(itemID: itemID, episodeID: episode.id, session: session)
        let key = PlaybackTimeline.key(itemID, episode.id)
        if let progress = session.library.progress.value(key) { session.journal.recordServer(progress) }
    }

    /// Książka z karty albo wyszukiwarki: pełna pozycja z serwera, potem jak wyżej.
    func download(itemID: String, session: ServerSession) async throws {
        let item = try await session.auth.perform { try await $0.item(id: itemID, token: $1) }
        try await download(book: item, session: session)
    }

    private func coverData(itemID: String, session: ServerSession) async -> Data? {
        try? await session.auth.perform { try await $0.cover(itemID: itemID, width: 600, token: $1) }
    }

    func remove(itemID: String, episodeID: String?) {
        manager.remove(key: ProgressJournal.key(itemID, episodeID))
    }

    // MARK: - Odtwarzanie i okładki bez sieci

    /// Pobrana w całości pozycja jako książka z plików.
    func playbackBook(itemID: String, episodeID: String?) -> PlaybackBook? {
        guard let item = manager.completeItem(itemID: itemID, episodeID: episodeID) else { return nil }
        let tracks = item.files.map {
            PlaybackTrack(startOffset: $0.startOffset, duration: $0.duration, title: $0.title, source: .file(manager.fileURL(item, $0)))
        }
        let chapters: [PlaybackChapter]
        if !item.chapters.isEmpty {
            let titles = PlaybackTimeline.displayTitles(item.chapters.map(\.title))
            chapters = item.chapters.enumerated().map { PlaybackChapter(id: $0.offset, start: $0.element.start, end: $0.element.end, title: titles[$0.offset]) }
        } else {
            let titles = PlaybackTimeline.displayTitles(tracks.map(\.title))
            chapters = tracks.enumerated().map {
                PlaybackChapter(id: $0.offset, start: $0.element.startOffset, end: $0.element.end, title: tracks.count == 1 ? item.title : titles[$0.offset])
            }
        }
        return PlaybackBook(itemID: item.itemID, episodeID: item.episodeID, title: item.title, author: item.author,
                            duration: item.duration, tracks: tracks, chapters: chapters)
    }

    /// Okładka pobranej pozycji (dowolnego jej wpisu — odcinki mają okładkę podcastu).
    func coverURL(itemID: String) -> URL? {
        if let item = manager.items[itemID], let url = manager.coverURL(item) { return url }
        return manager.items.values.first { $0.itemID == itemID && $0.hasCover }.flatMap(manager.coverURL)
    }

    nonisolated static func thumbnail(at url: URL, pixels: Int) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let image = UIImage(contentsOfFile: url.path), image.size.width > 0, image.size.height > 0 else { return nil }
            let scale = min(1, CGFloat(max(1, pixels)) / max(image.size.width, image.size.height))
            let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
            return image.preparingThumbnail(of: size) ?? image
        }.value
    }
}
