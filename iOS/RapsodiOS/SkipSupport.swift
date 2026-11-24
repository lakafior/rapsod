// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 13a).

import AudiobookshelfKit
import AudiobookshelfPlayback
import Foundation
import OSLog

private let logger = Logger(subsystem: "net.smigi.rapsod", category: "Skip")

/// Segmenty sponsorowane na telefonie (etap 13a). Skąd znaczniki:
/// - **odcinek z serwera** (strumień) — plik `.skip.json` policzony na Macu, pobrany przez
///   `GET /api/items/:id/file/:ino`; pasuje, bo to ten sam plik (rozmiar i długość);
/// - **odcinek pobrany na telefon** — kopia pobrana razem z odcinkiem (działa bez sieci),
///   odświeżana z serwera, gdy jest połączenie; odcisk liczony z pliku na telefonie;
/// - **odcinek prosto z kanału** — liczone na telefonie z opisu i kanału (bez modelu), nagłówek
///   Megaphone tylko, gdy opisuje plik o tej samej długości co odtwarzany.
///
/// Poprawki z telefonu zostają na telefonie (`SkipCorrectionsStore`) — aplikacja nie zapisuje plików
/// w folderze podcastu na Macu; Mac zapisuje poprawki w pliku na serwerze.
@MainActor
enum SkipSupport {
    static let settings = SkipSettingsStore()
    static let corrections = SkipCorrectionsStore.standard()

    static func configure(_ model: AppModel) {
        let playback = model.playback
        playback.skipSettings = { settings.settings(podcastID: $0) }
        playback.skipLoader = { [weak model] book, external in
            guard let model else { return nil }
            return await context(for: book, external: external, model: model)
        }
        playback.skipSaver = { book, context in
            guard let map = context.map else { return }
            try corrections.save(map, key: book.key)
        }
    }

    /// Ustawienia podcastu zmienione na stronie podcastu.
    static func setSettings(_ value: SkipSettings, podcastID: String, playback: PlaybackCoordinator) {
        settings.set(value, podcastID: podcastID)
        if playback.player.book?.itemID == podcastID { playback.refreshSkipPlan() }
    }

    static func context(for book: PlaybackBook, external: PlaybackCoordinator.ExternalEpisode?, model: AppModel) async -> PlaybackCoordinator.SkipContext? {
        var context: PlaybackCoordinator.SkipContext?
        if let external, book.feedKey != nil {
            context = await feedContext(book: book, episode: external)
        } else if let episodeID = book.episodeID {
            context = await serverContext(book: book, episodeID: episodeID, model: model)
        }
        guard var result = context else { return nil }
        if let map = result.map {
            result.map = SkipCorrectionsStore.merged(map, with: corrections.corrections(key: book.key, audio: result.actual))
        } else if let local = corrections.corrections(key: book.key, audio: result.actual) {
            // Bez znaczników z serwera, ale z segmentami dodanymi ręcznie na telefonie.
            result.map = SkipMap(episode: .init(itemID: book.itemID, episodeID: book.episodeID), audio: result.actual, corrections: local)
        }
        return result
    }

    private static func serverContext(book: PlaybackBook, episodeID: String, model: AppModel) async -> PlaybackCoordinator.SkipContext? {
        let session = model.currentSession
        let downloads = model.downloads.manager
        let localFile: URL? = book.tracks.count == 1 ? { if case .file(let url) = book.tracks[0].source { url } else { nil } }() : nil
        var localPrint: SkipAudioFingerprint?
        if let localFile {
            let duration = book.duration
            localPrint = await Task.detached(priority: .userInitiated) { try? SkipAudioFingerprint.of(fileAt: localFile, duration: duration) }.value
        }
        // Z serwera (także dla pobranego odcinka — Mac mógł policzyć od nowa albo poprawić).
        if !model.isOffline, let auth = session?.auth {
            let itemID = book.itemID
            if let item = try? await auth.perform({ try await $0.item(id: itemID, token: $1) }),
               let loaded = await SkipMapLoader.load(episodeID: episodeID, item: item, fetchFile: { ino in
                   try await auth.perform { try await $0.libraryFile(itemID: itemID, ino: ino, token: $1) }
               }) {
                if let data = loaded.data { downloads.storeSkip(data, itemID: itemID, episodeID: episodeID) }
                let actual = localPrint ?? SkipAudioFingerprint(size: loaded.located.audioSize, duration: book.duration)
                return .init(podcastID: itemID, map: loaded.map, actual: actual, origin: localFile == nil ? .server : .downloaded, savesToServer: false)
            }
        }
        // Bez sieci: kopia pobrana z odcinkiem.
        guard let localPrint else { return nil }
        let map = downloads.skipData(itemID: book.itemID, episodeID: episodeID).flatMap { try? SkipMap.decode($0) }
        return .init(podcastID: book.itemID, map: map, actual: localPrint, origin: .downloaded, savesToServer: false)
    }

    private static func feedContext(book: PlaybackBook, episode: PlaybackCoordinator.ExternalEpisode) async -> PlaybackCoordinator.SkipContext {
        let map = await SkipAnalyzer.analyze(feedEpisode: nil, summary: episode.summary, enclosureURL: episode.enclosureURL,
                                             podcastID: book.itemID, feedKey: episode.feedKey, feedDuration: episode.feedDuration,
                                             playedDuration: book.duration)
        return .init(podcastID: book.itemID, map: map, actual: SkipAudioFingerprint(duration: book.duration), origin: .feed, savesToServer: false)
    }

    /// Znaczniki pobierane razem z odcinkiem na telefon (mały plik, od razu, nie przez sesję tła).
    static func downloadWithEpisode(itemID: String, episodeID: String, session: ServerSession) async {
        let auth = session.auth
        guard let item = try? await auth.perform({ try await $0.item(id: itemID, token: $1) }),
              let loaded = await SkipMapLoader.load(episodeID: episodeID, item: item, fetchFile: { ino in
                  try await auth.perform { try await $0.libraryFile(itemID: itemID, ino: ino, token: $1) }
              }), let data = loaded.data else { return }
        session.downloads.manager.storeSkip(data, itemID: itemID, episodeID: episodeID)
        logger.info("Znaczniki pobrane z odcinkiem \(episodeID, privacy: .public)")
    }
}
