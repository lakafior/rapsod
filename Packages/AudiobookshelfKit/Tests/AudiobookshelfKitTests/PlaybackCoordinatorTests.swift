// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
import AudiobookshelfKit
import AudiobookshelfPlayback

/// Synchronizacja postępu na zaślepce serwera. Samego dźwięku tu nie ma (AVPlayer nie przechodzi
/// przez zaślepkę) — sprawdzamy zapytania do API.
extension Stubbed {
@Suite @MainActor struct PlaybackCoordinatorTests {
    init() { StubServer.reset() }

    private static let session = """
    {"id":"ses","libraryItemId":"li","mediaType":"book","displayTitle":"Książka","duration":100,"currentTime":42,"playMethod":0,
     "audioTracks":[{"index":1,"startOffset":0,"duration":100,"contentUrl":"/api/items/li/file/1","metadata":{"path":"/x/01.m4a"}}],
     "chapters":[]}
    """

    private func makeCoordinator() -> (PlaybackCoordinator, ConnectionErrors) {
        let auth = ListeningAuth(client: StubServer.client(), secret: .apiKey("KLUCZ"))
        let device = AudiobookshelfClient.DeviceInfo(deviceId: "telefon-test", clientName: "AudiobookSwift", clientVersion: "1", manufacturer: "Apple", model: "iPhone")
        let coordinator = PlaybackCoordinator(device: device) { auth }
        let errors = ConnectionErrors()
        coordinator.onConnectionError = { errors.count += 1 }
        return (coordinator, errors)
    }

    private func body(_ key: String) -> [String: Any]? {
        StubServer.requests.last { "\($0.request.httpMethod ?? "") \($0.request.url!.path())".hasSuffix(key) }
            .flatMap { $0.body }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    @Test func startUsesDeviceAndServerPosition() async throws {
        StubServer.on("POST api/items/li/play", .json(Self.session))
        let (coordinator, _) = makeCoordinator()
        await coordinator.play(itemID: "li")
        let start = try #require(body("api/items/li/play"))
        #expect((start["deviceInfo"] as? [String: Any])?["deviceId"] as? String == "telefon-test")
        #expect(start["forceDirectPlay"] as? Bool == true)
        #expect(coordinator.player.book?.key == "li")
        // 42 s z serwera, 3 s wcześniej.
        #expect(coordinator.player.currentTime == 39)
        coordinator.player.stop()
    }

    @Test func unknownSessionFallsBackToProgress() async throws {
        StubServer.on("POST api/items/li/play", .json(Self.session))
        StubServer.on("POST api/session/ses/sync", .status(404))
        StubServer.on("PATCH api/me/progress/li", .json("{}"))
        let (coordinator, _) = makeCoordinator()
        await coordinator.play(itemID: "li")
        coordinator.player.isDirty = true
        await coordinator.sync()
        let patch = try #require(body("api/me/progress/li"))
        #expect(patch["currentTime"] as? Double == coordinator.player.currentTime)
        #expect(coordinator.pending.isEmpty)
        #expect(!coordinator.player.isDirty)
        coordinator.player.stop()
    }

    @Test func failedSyncWaitsAndIsFlushedLater() async throws {
        StubServer.on("POST api/items/li/play", .json(Self.session))
        // Tunel bez Maca za nim.
        StubServer.on("POST api/session/ses/sync", .status(530))
        let (coordinator, errors) = makeCoordinator()
        await coordinator.play(itemID: "li")
        coordinator.player.isDirty = true
        await coordinator.sync()
        #expect(coordinator.pending["li"]?.currentTime == coordinator.player.currentTime)
        #expect(coordinator.player.isDirty, "pozycja zostaje do ponownej wysyłki")
        #expect(errors.count >= 1)

        // Połączenie wróciło; serwer nie ma nowszego postępu.
        StubServer.on("GET api/me/progress/li", .status(404))
        StubServer.on("PATCH api/me/progress/li", .json("{}"))
        coordinator.player.isDirty = false
        await coordinator.flushPending()
        #expect(coordinator.pending.isEmpty)
        #expect(body("api/me/progress/li")?["currentTime"] as? Double == coordinator.player.currentTime)
        coordinator.player.stop()
    }

    @Test func newerServerProgressWinsOverPending() async throws {
        StubServer.on("POST api/items/li/play", .json(Self.session))
        StubServer.on("POST api/session/ses/sync", .status(530))
        let (coordinator, _) = makeCoordinator()
        await coordinator.play(itemID: "li")
        coordinator.player.isDirty = true
        await coordinator.sync()
        #expect(coordinator.pending["li"] != nil)

        // W międzyczasie słuchano na Macu: serwer ma zapis późniejszy niż nasz.
        let later = (Date.now.timeIntervalSince1970 + 60) * 1000
        StubServer.on("GET api/me/progress/li", .json(#"{"libraryItemId":"li","episodeId":null,"duration":100,"progress":0.8,"currentTime":80,"isFinished":false,"lastUpdate":\#(later)}"#))
        StubServer.clearRequests()
        coordinator.player.isDirty = false
        await coordinator.flushPending()
        #expect(coordinator.pending.isEmpty)
        #expect(!StubServer.requests.contains { $0.request.httpMethod == "PATCH" }, "nie nadpisujemy nowszej pozycji z Maca")
        coordinator.player.stop()
    }
}
}

/// Odtwarzanie na Macu (etap 12): pliki serwera prosto z dysku, ale postęp przez sesję serwera.
extension Stubbed {
@Suite @MainActor struct LocalServerFileTests {
    init() { StubServer.reset() }

    /// Sekunda ciszy w WAV — plik, który AVFoundation naprawdę otworzy.
    private static func silentWAV() throws -> URL {
        let rate = 8000, samples = rate
        var data = Data("RIFF".utf8)
        func le<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        le(UInt32(36 + samples * 2)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(rate)); le(UInt32(rate * 2)); le(UInt16(2)); le(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); le(UInt32(samples * 2)); data.append(Data(count: samples * 2))
        let url = FileManager.default.temporaryDirectory.appending(path: "etap12-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    private static func session(path: String, method: Int = 0) -> String {
        """
        {"id":"ses\(method)","libraryItemId":"li","mediaType":"book","displayTitle":"Książka","duration":1,"currentTime":0,"playMethod":\(method),
         "audioTracks":[{"index":1,"startOffset":0,"duration":1,"contentUrl":"/api/items/li/file/1","metadata":{"path":"\(path)"}}],
         "chapters":[]}
        """
    }

    private func makeCoordinator() -> PlaybackCoordinator {
        let auth = ListeningAuth(client: StubServer.client(), secret: .apiKey("KLUCZ"))
        let device = AudiobookshelfClient.DeviceInfo(deviceId: "mac-test", clientName: "AudiobookSwift", clientVersion: "1", manufacturer: "Apple", model: "Mac")
        let coordinator = PlaybackCoordinator(device: device) { auth }
        coordinator.localFile = { FileManager.default.isReadableFile(atPath: $0) ? URL(filePath: $0) : nil }
        return coordinator
    }

    private var calls: [String] { StubServer.requests.map { "\($0.request.httpMethod ?? "") \($0.request.url!.path())" } }

    @Test func playsFromDiskWithServerSession() async throws {
        let file = try Self.silentWAV()
        defer { try? FileManager.default.removeItem(at: file) }
        StubServer.on("POST api/items/li/play", .json(Self.session(path: file.path)))
        StubServer.on("POST api/session/ses0/sync", .json("{}"))
        let coordinator = makeCoordinator()
        var saved: [PositionRecord] = []
        coordinator.onProgressSaved = { saved.append($0) }
        await coordinator.play(itemID: "li")
        #expect(coordinator.player.book?.tracks.map(\.source) == [.serverFile(file)])
        coordinator.player.isDirty = true
        await coordinator.sync()
        // Sesja serwera, nie „sesja lokalna” pozycji pobranej na urządzenie.
        #expect(calls.contains { $0.hasSuffix("api/session/ses0/sync") }, "\(calls)")
        #expect(!calls.contains { $0.contains("local") })
        #expect(saved.map(\.itemID) == ["li"])
        #expect(saved.first?.isUnsent == false)
        coordinator.player.stop()
    }

    @Test func unreadableFileFallsBackToTranscoding() async throws {
        let bad = FileManager.default.temporaryDirectory.appending(path: "etap12-\(UUID().uuidString).m4a")
        try Data("to nie jest dźwięk".utf8).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        StubServer.on("POST api/items/li/play", .json(Self.session(path: bad.path)), .json(Self.session(path: bad.path, method: 2)))
        let coordinator = makeCoordinator()
        await coordinator.play(itemID: "li")
        let starts = StubServer.requests.filter { $0.request.url!.path().hasSuffix("api/items/li/play") }
        #expect(starts.count == 2)
        #expect(starts.last.flatMap { $0.body }.map { String(decoding: $0, as: UTF8.self).contains("forceTranscode") } == true)
        #expect(coordinator.player.book?.tracks.map(\.source) == [.sessionStream])
        coordinator.player.stop()
    }

    @Test func discardClosesWithoutPosition() async throws {
        let file = try Self.silentWAV()
        defer { try? FileManager.default.removeItem(at: file) }
        StubServer.on("POST api/items/li/play", .json(Self.session(path: file.path)))
        StubServer.on("POST api/session/ses0/close", .json("{}"))
        let coordinator = makeCoordinator()
        await coordinator.play(itemID: "li")
        coordinator.journal.recordLocal(itemID: "li", episodeID: nil, currentTime: 0.5, duration: 1)
        coordinator.player.isDirty = true
        await coordinator.discardCurrent()
        #expect(coordinator.player.book == nil)
        #expect(coordinator.journal.position(itemID: "li", episodeID: nil) == nil, "wyzerowany postęp nie wraca z dziennika")
        let close = try #require(StubServer.requests.last { $0.request.url!.path().hasSuffix("api/session/ses0/close") })
        #expect((close.body ?? Data()).isEmpty || String(decoding: close.body!, as: UTF8.self) == "{}", "bez pozycji")
        #expect(!calls.contains { $0.hasPrefix("PATCH") || $0.hasSuffix("/sync") })
    }

    @Test func serverStoppedKeepsPositionInJournal() async throws {
        let file = try Self.silentWAV()
        defer { try? FileManager.default.removeItem(at: file) }
        StubServer.on("POST api/items/li/play", .json(Self.session(path: file.path)))
        let coordinator = makeCoordinator()
        var reachable = true
        coordinator.isReachable = { reachable }
        await coordinator.play(itemID: "li")
        coordinator.player.seek(to: 0.4)
        StubServer.clearRequests()
        // Serwer (proces potomny na Macu) zatrzymany: zamknięcie bez sieci, pozycja do dziennika.
        reachable = false
        await coordinator.stop()
        #expect(calls.isEmpty, "\(calls)")
        let unsent = try #require(coordinator.journal.position(itemID: "li", episodeID: nil))
        #expect(unsent.isUnsent)
        #expect(unsent.currentTime == 0.4)
    }

    @Test func replacingChaptersKeepsPosition() {
        let player = AudiobookPlayer()
        let book = PlaybackBook(itemID: "li", episodeID: nil, title: "K", author: nil, duration: 100,
                                tracks: [PlaybackTrack(startOffset: 0, duration: 100, title: "01", source: .sessionTrack(index: 1))],
                                chapters: [PlaybackChapter(id: 0, start: 0, end: 100, title: "Całość")])
        player.start(book, at: 60, autoplay: false)
        #expect(player.currentChapter?.title == "Całość")
        player.replaceChapters([PlaybackChapter(id: 0, start: 0, end: 50, title: "Jeden"), PlaybackChapter(id: 1, start: 50, end: 100, title: "Dwa")])
        #expect(player.currentChapter?.title == "Dwa")
        #expect(player.currentTime == 60)
        player.replaceCoverPath("/okladka.jpg")
        #expect(player.book?.coverPath == "/okladka.jpg")
        player.stop()
    }
}
}

@MainActor private final class ConnectionErrors {
    var count = 0
}

/// Odcinek prosto z kanału: postęp na telefonie, a po pobraniu przez serwer — na serwer.
extension Stubbed {
@Suite @MainActor struct ExternalEpisodeTests {
    init() { StubServer.reset() }

    func makeCoordinator(_ store: ProgressJournal) -> PlaybackCoordinator {
        let auth = ListeningAuth(client: StubServer.client(), secret: .apiKey("KLUCZ"))
        let device = AudiobookshelfClient.DeviceInfo(deviceId: "telefon-test", clientName: "AudiobookSwift", clientVersion: "1", manufacturer: "Apple", model: "iPhone")
        let coordinator = PlaybackCoordinator(device: device) { auth }
        coordinator.journal = store
        coordinator.streamProbe = { url in (url, 600) }
        return coordinator
    }

    let episode = PlaybackCoordinator.ExternalEpisode(
        itemID: "li", feedKey: "g:ep1", title: "Odcinek", podcastTitle: "Podcast", guid: "ep1",
        enclosureURL: "https://wydawca.invalid/ep1.mp3", published: nil, feedDuration: 590
    )

    private var serverCalls: [String] {
        StubServer.requests.map { "\($0.request.httpMethod ?? "") \($0.request.url!.path())" }
    }

    @Test func progressStaysOnPhone() async throws {
        let store = ProgressJournal(fileURL: nil)
        let coordinator = makeCoordinator(store)
        await coordinator.play(external: episode)
        #expect(coordinator.player.book?.key == "li/feed:g:ep1")
        #expect(coordinator.player.duration == 600, "długość z pliku, nie z kanału")
        #expect(coordinator.isProgressLocal)
        #expect(store.record(itemID: "li", feedKey: "g:ep1") != nil, "wpis od razu po starcie")

        coordinator.player.seek(to: 200)
        await coordinator.sync()
        #expect(store.record(itemID: "li", feedKey: "g:ep1")?.currentTime == 200)
        #expect(serverCalls.isEmpty, "żadnego zapytania do serwera: \(serverCalls)")

        // Ponowny start po „zamknięciu aplikacji”: od zapisanej pozycji minus 3 s.
        coordinator.player.stop()
        let again = makeCoordinator(store)
        await again.play(external: episode)
        #expect(again.player.currentTime == 197)
        again.player.stop()
    }

    @Test func switchesTargetWhenServerHasEpisode() async throws {
        StubServer.on("PATCH api/me/progress/li/se1", .json("{}"))
        let store = ProgressJournal(fileURL: nil)
        let coordinator = makeCoordinator(store)
        await coordinator.play(external: episode)
        coordinator.player.seek(to: 321)
        let handled = await coordinator.serverEpisodeAvailable(itemID: "li", feedKey: "g:ep1", episodeID: "se1")
        #expect(handled)
        let patch = try #require(StubServer.requests.last { $0.request.url!.path().hasSuffix("api/me/progress/li/se1") }?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: patch) as? [String: Any])
        #expect(json["currentTime"] as? Double == 321)
        #expect(store.record(itemID: "li", feedKey: "g:ep1") == nil, "lokalny wpis zbędny po zapisie na serwerze")
        #expect(!coordinator.isProgressLocal)
        // Źródło dźwięku bez zmian, odcinek serwera rozpoznawany jako bieżący.
        #expect(coordinator.player.book?.tracks.first?.source == .remote(URL(string: "https://wydawca.invalid/ep1.mp3")!))
        #expect(coordinator.isLoaded(itemID: "li", episodeID: "se1"))
        #expect(coordinator.nowPlayingKeys == ["li/feed:g:ep1", "li/se1"])
        // Nikt nie otworzył sesji odtwarzania na podcaście.
        #expect(!serverCalls.contains { $0.contains("/play") })
        coordinator.player.stop()
    }

    @Test func mapsPositionToShorterServerFile() async throws {
        StubServer.on("PATCH api/me/progress/li/se1", .json("{}"))
        let store = ProgressJournal(fileURL: nil)
        let coordinator = makeCoordinator(store)
        await coordinator.play(external: episode)
        coordinator.player.seek(to: 300)
        // Serwer pobrał wersję z innymi reklamami: 540 s zamiast 600.
        await coordinator.serverEpisodeAvailable(itemID: "li", feedKey: "g:ep1", episodeID: "se1", serverDuration: 540)
        let patch = try #require(StubServer.requests.last { $0.request.url!.path().hasSuffix("api/me/progress/li/se1") }?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: patch) as? [String: Any])
        #expect(json["currentTime"] as? Double == 270)
        #expect(json["duration"] as? Double == 540)
        coordinator.player.stop()
    }

    @Test func finishingLocallyMarksRecordFinished() async throws {
        let store = ProgressJournal(fileURL: nil)
        let coordinator = makeCoordinator(store)
        await coordinator.play(external: episode)
        await coordinator.markFinished()
        let record = try #require(store.record(itemID: "li", feedKey: "g:ep1"))
        #expect(record.isFinished)
        #expect(serverCalls.isEmpty)
    }

    @Test func streamErrorsReadable() {
        let ats = URLError(.appTransportSecurityRequiresSecureConnection)
        #expect(PlaybackCoordinator.StreamError.insecureOnly.errorDescription?.contains("HTTP") == true)
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: ats as NSError])
        #expect(PlaybackCoordinator.streamError(wrapped) == .insecureOnly)
        let ranges = NSError(domain: "AVFoundationErrorDomain", code: -11850)
        #expect(PlaybackCoordinator.streamError(ranges) == .noRangeSupport)
        #expect(PlaybackCoordinator.streamError(URLError(.fileDoesNotExist)) == .notFound)
    }
}
}

/// Segmenty sponsorowane (etap 13a): znaczniki wczytywane dla odcinków, plan z ustawień podcastu.
extension Stubbed.ExternalEpisodeTests {
    @Test func skipMarkersForExternalEpisode() async throws {
        let coordinator = makeCoordinator(ProgressJournal(fileURL: nil))
        var summaries: [String?] = []
        let map = SkipMap(episode: .init(itemID: "li"), audio: SkipAudioFingerprint(duration: 600),
                          segments: [SkipSegment(id: "a", start: 100, end: 160, kind: .sponsor, source: .description, confidence: 0.85)])
        coordinator.skipLoader = { book, external in
            summaries.append(external?.summary)
            return .init(podcastID: book.itemID, map: map, actual: SkipAudioFingerprint(duration: 600.4), origin: .feed, savesToServer: false)
        }
        var described = episode
        described.summary = "1:40 Sponsor\n2:40 Dalej"
        await coordinator.play(external: described)
        for _ in 0..<100 where coordinator.skipContext == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(summaries == ["1:40 Sponsor\n2:40 Dalej"])
        #expect(coordinator.player.skipPlan.entries.map(\.id) == ["a"])

        coordinator.skipSettings = { _ in SkipSettings(enabled: false) }
        coordinator.refreshSkipPlan()
        #expect(coordinator.player.skipPlan.isEmpty)

        // Poprawka: usunięty segment znika z planu od razu.
        coordinator.skipSettings = { _ in .standard }
        var edited = map
        edited.remove(map.segments[0])
        try await coordinator.saveSkips(edited)
        #expect(coordinator.player.skipPlan.isEmpty)
        #expect(coordinator.skipContext?.map?.corrections.removed.count == 1)
        await coordinator.stop()
        #expect(coordinator.skipContext == nil)
    }
}
