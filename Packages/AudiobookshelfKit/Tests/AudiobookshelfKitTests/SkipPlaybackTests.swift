// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import Foundation
import Testing
@testable import AudiobookshelfKit
@testable import AudiobookshelfPlayback

/// Pomijanie w prawdziwym odtwarzaczu (AVQueuePlayer na pliku WAV z dysku).
@Suite(.serialized) @MainActor
struct SkipPlaybackTests {
    /// Plik WAV z cichym sygnałem (8 kHz, mono, 16 bit).
    static func wav(seconds: Int) throws -> URL {
        let rate = 8000
        let samples = rate * seconds
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples * 2)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(samples * 2))
        for i in 0..<samples { u16(UInt16(bitPattern: Int16(sin(Double(i) * 0.05) * 200))) }
        let url = FileManager.default.temporaryDirectory.appending(path: "skip-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    static func book(_ url: URL, duration: Double) -> PlaybackBook {
        PlaybackBook(itemID: "li", episodeID: "ep", title: "Odcinek", author: "Podcast", duration: duration,
                     tracks: [PlaybackTrack(startOffset: 0, duration: duration, title: "Odcinek", source: .file(url))],
                     chapters: [PlaybackChapter(id: 0, start: 0, end: duration, title: "Odcinek")])
    }

    static func plan(_ segments: [(String, Double, Double)], duration: Double) -> SkipPlan {
        SkipPlan(entries: segments.map { SkipPlan.Entry(id: $0.0, start: $0.1, end: $0.2, kind: .sponsor, source: .description, action: .skip) },
                 duration: duration)
    }

    static func waitUntil(_ timeout: Double = 8, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func makePlayer() -> AudiobookPlayer {
        let player = AudiobookPlayer()
        player.assetProvider = { track, _ in
            guard case .file(let url) = track.source else { throw CancellationError() }
            return AVURLAsset(url: url)
        }
        return player
    }

    @Test func skipsWhilePlayingFastAndUndoPlaysThrough() async throws {
        let url = try Self.wav(seconds: 14)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = makePlayer()
        let savedRate = player.rate
        defer { player.rate = savedRate; player.stop() }
        player.rate = 3
        player.start(Self.book(url, duration: 14), at: 0)
        player.setSkipPlan(Self.plan([("s", 3, 7)], duration: 14))
        #expect(await Self.waitUntil { player.lastSkip != nil })
        let event = try #require(player.lastSkip)
        #expect(event.entry.id == "s")
        #expect(event.automatic)
        #expect(player.currentTime >= 7 - 0.01)
        #expect(player.isDirty)

        // „Cofnij”: z powrotem na początek, segment gra do końca bez ponownego pominięcia.
        player.undoSkip()
        #expect(abs(player.currentTime - 3) < 0.6)
        #expect(player.lastSkip == nil)
        #expect(await Self.waitUntil { player.currentTime > 5 })
        #expect(player.currentTime < 7)
        #expect(player.lastSkip == nil)
    }

    @Test func preRollSkippedWhenPlanArrivesDuringLoad() async throws {
        let url = try Self.wav(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = makePlayer()
        defer { player.stop() }
        player.start(Self.book(url, duration: 10), at: 0)
        player.setSkipPlan(Self.plan([("pre", 0, 4)], duration: 10))
        #expect(await Self.waitUntil { player.lastSkip != nil })
        #expect(player.currentTime >= 4 - 0.01)
    }

    @Test func seekIntoSegmentDoesNotSkipButSkipButtonWorks() async throws {
        let url = try Self.wav(seconds: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = makePlayer()
        defer { player.stop() }
        player.start(Self.book(url, duration: 12), at: 0)
        player.setSkipPlan(Self.plan([("s", 2, 9)], duration: 12))
        #expect(await Self.waitUntil { player.isPlaying && !player.isLoading })
        player.seek(to: 4)
        try await Task.sleep(for: .seconds(1.2))
        #expect(player.lastSkip == nil)
        #expect(player.currentTime < 9)
        #expect(player.skipPlan.entry(at: player.currentTime)?.id == "s")
        player.skipCurrentSegment()
        #expect(player.currentTime >= 9 - 0.01)
        #expect(player.lastSkip?.automatic == false)
        // „Cofnij” po „Pomiń” wraca tam, skąd pominięto.
        player.undoSkip()
        #expect(abs(player.currentTime - 5) < 1)
    }

    @Test func noSkipWhilePaused() async throws {
        let url = try Self.wav(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = makePlayer()
        defer { player.stop() }
        player.start(Self.book(url, duration: 10), at: 0, autoplay: false)
        #expect(await Self.waitUntil { !player.isLoading })
        player.setSkipPlan(Self.plan([("pre", 0, 4)], duration: 10))
        try await Task.sleep(for: .milliseconds(600))
        #expect(player.lastSkip == nil)
        #expect(player.currentTime < 1)
    }

    @Test func skipToEndFinishesEpisode() async throws {
        let url = try Self.wav(seconds: 8)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = makePlayer()
        defer { player.stop() }
        var finished = false
        player.onEvent = { if case .finished = $0 { finished = true } }
        player.start(Self.book(url, duration: 8), at: 0)
        player.setSkipPlan(Self.plan([("post", 2, 8)], duration: 8))
        #expect(await Self.waitUntil { finished })
    }

    @Test func endOfChapterTimerStopsAtChapterEnd() async throws {
        let url = try Self.wav(seconds: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = makePlayer()
        defer { player.stop() }
        var book = Self.book(url, duration: 12)
        book.chapters = [PlaybackChapter(id: 0, start: 0, end: 4, title: "Jeden"), PlaybackChapter(id: 1, start: 4, end: 12, title: "Dwa")]
        player.start(book, at: 0)
        player.setSleepTimer(.endOfChapter)
        // Segment przechodzi przez koniec rozdziału — pominięcie kończy się na końcu rozdziału i timer zatrzymuje.
        player.setSkipPlan(Self.plan([("s", 1, 9)], duration: 12))
        #expect(await Self.waitUntil { player.lastSkip != nil })
        #expect(await Self.waitUntil { !player.wantsToPlay })
        #expect(abs(player.currentTime - 4) < 0.6)
    }
}
