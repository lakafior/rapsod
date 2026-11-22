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

@MainActor private final class ConnectionErrors {
    var count = 0
}
