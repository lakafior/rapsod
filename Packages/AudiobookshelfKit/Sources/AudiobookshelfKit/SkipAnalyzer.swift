// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 13a).

import Foundation

/// Zbiera dane do wykrywania (opis, rozdziały, `itunes:duration`, nagłówek Megaphone) i składa plik
/// znaczników. Mac woła to po pobraniu odcinka na serwer i przyciskiem, iOS — dla odcinka granego
/// prosto z kanału (bez zapisu na serwerze).
public enum SkipAnalyzer {
    /// Odcinek z serwera z plikiem audio na dysku (Mac).
    public static func analyze(serverEpisode episode: AudiobookshelfClient.PodcastEpisode, podcastID: String, feed: RSSPodcast?,
                               audioFile: URL, previous: SkipMap?, session: URLSession = .shared) async throws -> SkipMap {
        let duration = episode.audioFile?.duration ?? episode.duration ?? 0
        let audio = try await Task.detached(priority: .utility) { try SkipAudioFingerprint.of(fileAt: audioFile, duration: duration) }.value
        let rss = feed.flatMap { match(episode, in: $0) }
        let description = HTMLText.plain(episode.description) ?? rss?.summary
        var chapters = (episode.chapters ?? []).map { SkipDetection.Chapter(start: $0.start, end: $0.end, title: $0.title) }
        if chapters.count < 2 { chapters = await feedChapters(rss, duration: duration, session: session) }
        var megaphone: (payload: MegaphonePayload, totalSize: Int64?)?
        if let url = (episode.enclosure?.url).flatMap(RSSFeedParser.webURL) {
            megaphone = await SkipNetwork.megaphone(for: url, session: session)
        }
        let input = SkipDetection.Input(description: description, chapters: chapters, feedDuration: rss?.durationSeconds,
                                        fileDuration: duration, fileSize: audio.size,
                                        fileAudioBytes: audio.size.map { $0 - SkipAudioFingerprint.id3Size(fileAt: audioFile) },
                                        megaphone: megaphone?.payload,
                                        megaphoneTotalSize: megaphone?.totalSize)
        let result = SkipDetection.analyze(input)
        let ref = SkipMap.EpisodeRef(itemID: podcastID, episodeID: episode.id, guid: episode.guid, title: episode.title,
                                     enclosureURL: episode.enclosure?.url)
        return SkipDetection.map(result: result, episode: ref, audio: audio, previous: previous)
    }

    /// Odcinek grany prosto z kanału (iOS): plik u wydawcy, długość z odtwarzacza. Nagłówek Megaphone
    /// pasuje tylko, gdy długość z niego zgadza się z długością odtwarzanego pliku.
    public static func analyze(feedEpisode rss: RSSEpisode?, summary: String?, enclosureURL: String, podcastID: String, feedKey: String,
                               feedDuration: Double?, playedDuration: Double, session: URLSession = .shared) async -> SkipMap {
        var megaphone: (payload: MegaphonePayload, totalSize: Int64?)?
        if let url = RSSFeedParser.webURL(enclosureURL) {
            megaphone = await SkipNetwork.megaphone(for: url, session: session)
        }
        let chapters = await feedChapters(rss, duration: playedDuration, session: session)
        let input = SkipDetection.Input(description: summary ?? rss?.summary, chapters: chapters, feedDuration: feedDuration ?? rss?.durationSeconds,
                                        fileDuration: playedDuration, megaphone: megaphone?.payload, megaphoneTotalSize: megaphone?.totalSize)
        let result = SkipDetection.analyze(input)
        let ref = SkipMap.EpisodeRef(itemID: podcastID, guid: rss?.guid, title: rss?.title, enclosureURL: enclosureURL)
        return SkipDetection.map(result: result, episode: ref, audio: SkipAudioFingerprint(duration: playedDuration), previous: nil)
    }

    /// Odcinek kanału odpowiadający odcinkowi z serwera (guid, adres pliku, tytuł i data).
    public static func match(_ episode: AudiobookshelfClient.PodcastEpisode, in feed: RSSPodcast) -> RSSEpisode? {
        let identity = EpisodeIdentity(episode)
        return feed.episodes
            .compactMap { rss in EpisodeMatching.strength(identity, EpisodeIdentity(rss)).map { (rss, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    static func feedChapters(_ rss: RSSEpisode?, duration: Double, session: URLSession) async -> [SkipDetection.Chapter] {
        guard let rss else { return [] }
        if let inline = rss.chapters, inline.count > 1 { return RSSChapter.ranges(inline, duration: duration) }
        if let url = rss.chaptersURL { return await SkipNetwork.chapters(from: url, duration: duration, session: session) }
        return []
    }
}
