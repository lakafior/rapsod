// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
import AudiobookshelfKit
import AudiobookshelfPlayback

/// Książka z trzech plików: 0–40, 40–100, 100–130 s.
private let tracks = [
    PlaybackTrack(startOffset: 0, duration: 40, title: "01", source: .sessionTrack(index: 1)),
    PlaybackTrack(startOffset: 40, duration: 60, title: "02", source: .sessionTrack(index: 2)),
    PlaybackTrack(startOffset: 100, duration: 30, title: "03", source: .sessionTrack(index: 3)),
]

/// Rozdziały niezależne od plików: 0–25, 25–70, 70–130 s.
private let chapters = [
    PlaybackChapter(id: 0, start: 0, end: 25, title: "Jeden"),
    PlaybackChapter(id: 1, start: 25, end: 70, title: "Dwa"),
    PlaybackChapter(id: 2, start: 70, end: 130, title: "Trzy"),
]

@Suite struct PlaybackTimelineTests {
    @Test func trackIndexAtBoundaries() {
        #expect(PlaybackTimeline.trackIndex(in: tracks, at: 0) == 0)
        #expect(PlaybackTimeline.trackIndex(in: tracks, at: 39.9) == 0)
        #expect(PlaybackTimeline.trackIndex(in: tracks, at: 40) == 1)
        #expect(PlaybackTimeline.trackIndex(in: tracks, at: 99.9995) == 2, "ułamek milisekundy przed granicą to już następny plik")
        #expect(PlaybackTimeline.trackIndex(in: tracks, at: 129) == 2)
        #expect(PlaybackTimeline.trackIndex(in: [], at: 10) == 0)
    }

    @Test func localTimeIsClampedToTrack() {
        #expect(PlaybackTimeline.localTime(55, in: tracks[1]) == 15)
        #expect(PlaybackTimeline.localTime(10, in: tracks[1]) == 0)
        #expect(PlaybackTimeline.localTime(500, in: tracks[1]) == 59.75)
        #expect(PlaybackTimeline.bookTime(local: 15, in: tracks[1]) == 55)
        #expect(PlaybackTimeline.bookTime(local: .nan, in: tracks[1]) == 40)
        #expect(PlaybackTimeline.bookTime(local: 90, in: tracks[1]) == 100)
    }

    @Test func transitionsBetweenTracks() {
        #expect(PlaybackTimeline.afterTrack(0, in: tracks) == .next(index: 1, startsAt: 40))
        #expect(PlaybackTimeline.afterTrack(1, in: tracks) == .next(index: 2, startsAt: 100))
        #expect(PlaybackTimeline.afterTrack(2, in: tracks) == .finished)
        // Przeskok +30 s z końca pierwszego pliku trafia w drugi plik.
        let target = PlaybackTimeline.clamp(35 + 30, duration: 130)
        #expect(PlaybackTimeline.trackIndex(in: tracks, at: target) == 1)
        #expect(PlaybackTimeline.localTime(target, in: tracks[1]) == 25)
        // Przewinięcie za koniec zatrzymuje się tuż przed końcem, a cofnięcie przed początek — na zerze.
        #expect(PlaybackTimeline.clamp(500, duration: 130) == 129.5)
        #expect(PlaybackTimeline.clamp(-15, duration: 130) == 0)
    }

    @Test func chapterAtTime() {
        #expect(PlaybackTimeline.chapter(in: chapters, at: 0)?.id == 0)
        #expect(PlaybackTimeline.chapter(in: chapters, at: 24.7)?.id == 1, "pół sekundy zapasu przed początkiem rozdziału")
        #expect(PlaybackTimeline.chapter(in: chapters, at: 69)?.id == 1)
        #expect(PlaybackTimeline.chapter(in: chapters, at: 129)?.id == 2)
        #expect(PlaybackTimeline.chapter(in: [], at: 5) == nil)
    }

    @Test func nextAndPreviousChapter() {
        #expect(PlaybackTimeline.nextChapter(in: chapters, at: 10)?.id == 1)
        #expect(PlaybackTimeline.nextChapter(in: chapters, at: 100) == nil)
        // Dalej niż 3 s od początku: na początek bieżącego.
        #expect(PlaybackTimeline.previousChapterTarget(in: chapters, at: 40)?.id == 1)
        // Tuż po początku: poprzedni.
        #expect(PlaybackTimeline.previousChapterTarget(in: chapters, at: 26)?.id == 0)
        // Pierwszy rozdział: zawsze jego początek.
        #expect(PlaybackTimeline.previousChapterTarget(in: chapters, at: 1)?.id == 0)
    }

    @Test func sliderWithinChapter() {
        let position = PlaybackTimeline.chapterPosition(in: chapters, at: 40, duration: 130)
        #expect(position.chapter?.id == 1)
        #expect(position.start == 25)
        #expect(position.length == 45)
        #expect(position.elapsed == 15)
        #expect(position.remaining == 30)
        #expect(position.bookTime(forElapsed: 45) == 70)
        #expect(position.bookTime(forElapsed: 100) == 70, "suwak nie wychodzi poza rozdział")
        // Bez rozdziałów suwak obejmuje całą książkę.
        let whole = PlaybackTimeline.chapterPosition(in: [], at: 40, duration: 130)
        #expect(whole.chapter == nil && whole.length == 130 && whole.elapsed == 40)
    }

    @Test func sleepTimerAtEndOfChapter() {
        // Rozdział „Jeden” (do 25 s) kończy się w pierwszym pliku (do 40 s), a „Trzy” razem z ostatnim plikiem.
        #expect(PlaybackTimeline.chapterEndsWithTrack(chapters[0], tracks[0]))
        #expect(!PlaybackTimeline.chapterEndsWithTrack(chapters[1], tracks[0]))
        #expect(PlaybackTimeline.chapterEndsWithTrack(chapters[2], tracks[2]))
    }

    @Test func chapterTitlesFromFileNames() {
        #expect(PlaybackTimeline.displayTitles(["01 Książka", "02 Książka", "03 książka"]) == ["Rozdział 1", "Rozdział 2", "Rozdział 3"])
        #expect(PlaybackTimeline.displayTitles(["Wstęp", "Burza"]) == ["Wstęp", "Burza"])
        #expect(PlaybackTimeline.displayTitles(["Jedyny"]) == ["Jedyny"])
    }

    @Test func rewindOnResume() {
        #expect(PlaybackTimeline.rewoundStart(0) == 0)
        #expect(PlaybackTimeline.rewoundStart(8) == 8)
        #expect(PlaybackTimeline.rewoundStart(100) == 97)
    }

    @Test func sessionMapping() throws {
        let json = """
        {"id":"ses","libraryItemId":"li","episodeId":null,"mediaType":"book","displayTitle":"Książka","displayAuthor":"Autor",
         "coverPath":null,"duration":100,"currentTime":12,"playMethod":0,
         "audioTracks":[
           {"index":1,"startOffset":0,"duration":40,"title":"01.m4a","contentUrl":"/api/items/li/file/1","mimeType":"audio/mp4","metadata":{"path":"/x/01.m4a"}},
           {"index":2,"startOffset":40,"duration":60,"title":"02.m4a","contentUrl":"/api/items/li/file/2","mimeType":"audio/mp4","metadata":{"path":"/x/02.m4a"}}],
         "chapters":[]}
        """
        let session = try JSONDecoder().decode(AudiobookshelfClient.PlaybackSession.self, from: Data(json.utf8))
        let mapped = PlaybackTimeline.tracks(from: session)
        #expect(mapped.map(\.source) == [.sessionTrack(index: 1), .sessionTrack(index: 2)], "indeks z serwera, nie pozycja w tablicy")
        let chapters = PlaybackTimeline.chapters(from: session, tracks: mapped)
        #expect(chapters.map(\.start) == [0, 40])
        #expect(chapters.map(\.end) == [40, 100])
        #expect(!PlaybackTimeline.needsTranscoding(session))
    }

    @Test func unplayableFormatNeedsTranscoding() throws {
        let json = """
        {"id":"ses","libraryItemId":"li","mediaType":"book","duration":10,"currentTime":0,"playMethod":0,
         "audioTracks":[{"index":1,"startOffset":0,"duration":10,"contentUrl":"/api/items/li/file/1","metadata":{"path":"/x/a.WMA"}}],
         "chapters":[]}
        """
        let session = try JSONDecoder().decode(AudiobookshelfClient.PlaybackSession.self, from: Data(json.utf8))
        #expect(PlaybackTimeline.needsTranscoding(session))
    }
}

@Suite struct AddressSelectionTests {
    private func address(_ text: String, _ kind: PairingPayload.Address.Kind) -> PairingPayload.Address {
        .init(url: URL(string: text)!, kind: kind)
    }

    @Test func localFirstThenRemote() {
        let attempts = AddressSelection.attempts(for: [
            address("https://abs.example.com", .remote),
            address("http://mac.local:13378", .local),
            address("abs+new://x", .other("future")),
            address("http://192.168.1.5:13378", .local),
            address("http://mac.local:13378", .local),
        ])
        #expect(attempts.map(\.url.absoluteString) == [
            "http://mac.local:13378", "http://192.168.1.5:13378", "https://abs.example.com", "abs+new://x",
        ])
        #expect(attempts[0].timeout == AddressSelection.localTimeout)
        #expect(attempts[2].timeout == AddressSelection.remoteTimeout)
        #expect(AddressSelection.localTimeout < AddressSelection.remoteTimeout)
    }

    @Test func withoutWiFiOnlyRemoteAddressesAreTried() {
        let attempts = AddressSelection.attempts(for: [address("http://mac.local", .local), address("https://t.example.com", .remote)])
        #expect(AddressSelection.usable(attempts, hasLocalNetwork: true).count == 2)
        #expect(AddressSelection.usable(attempts, hasLocalNetwork: false).map(\.url.host) == ["t.example.com"])
        // Bez adresu spoza domu nie ma czego pomijać.
        let localOnly = AddressSelection.attempts(for: [address("http://mac.local", .local)])
        #expect(AddressSelection.usable(localOnly, hasLocalNetwork: false).count == 1)
    }

    @Test func localWinsWhenItAnswersWithinGrace() async throws {
        let attempts = AddressSelection.attempts(for: [address("http://mac.local", .local), address("https://t.example.com", .remote)])
        // Tunel odpowiada od razu, Mac po 100 ms — w domu ma wygrać adres lokalny.
        let home = try await AddressSelection.preferringLocal(attempts, grace: .seconds(2)) { attempt -> AddressSelection.Outcome<String> in
            if attempt.isLocal { try? await Task.sleep(for: .milliseconds(100)) }
            return .reached(attempt.isLocal ? "lokalny" : "tunel")
        }
        #expect(home.value == "lokalny")
    }

    @Test func remoteIsUsedAfterGraceWithoutWaitingForLocalTimeout() async throws {
        let attempts = AddressSelection.attempts(for: [address("http://mac.local", .local), address("https://t.example.com", .remote)])
        let clock = ContinuousClock()
        let started = clock.now
        // Obca sieć Wi-Fi: adres lokalny wisi do limitu czasu, tunel odpowiada od razu.
        let away = try await AddressSelection.preferringLocal(attempts, grace: .milliseconds(200)) { attempt -> AddressSelection.Outcome<String> in
            if attempt.isLocal {
                try? await Task.sleep(for: .seconds(5))
                return .unreachable("limit czasu")
            }
            return .reached("tunel")
        }
        #expect(away.value == "tunel")
        #expect(clock.now - started < .seconds(2))
    }

    @Test func refusalFromOneAddressDoesNotBlockAnother() async throws {
        struct Rejected: Error {}
        let attempts = AddressSelection.attempts(for: [address("http://192.168.1.11", .local), address("https://t.example.com", .remote)])
        // W obcej sieci pod domowym adresem stoi inne urządzenie i odmawia — tunel ma zadziałać.
        let result = try await AddressSelection.preferringLocal(attempts, grace: .milliseconds(100)) { attempt -> AddressSelection.Outcome<String> in
            attempt.isLocal ? .stop(Rejected()) : .reached("tunel")
        }
        #expect(result.value == "tunel")
        // Odmowa wszędzie: błąd odmowy, nie „nieosiągalny”.
        await #expect(throws: Rejected.self) {
            _ = try await AddressSelection.preferringLocal(attempts, grace: .milliseconds(100)) { _ -> AddressSelection.Outcome<String> in .stop(Rejected()) }
        }
    }

    @Test func firstReachableWinsInOrder() async throws {
        let attempts = AddressSelection.attempts(for: [address("https://t.example.com", .remote), address("http://mac.local", .local)])
        // Oba działają: wygrywa lokalny, tunel nie jest nawet pytany.
        let asked = Recorder()
        let both = try await AddressSelection.firstReachable(attempts) { attempt in
            await asked.add(attempt.url)
            return .reached(attempt.url.host() ?? "")
        }
        #expect(both.url.absoluteString == "http://mac.local")
        #expect(await asked.urls.count == 1)

        // Poza domem: lokalny nie odpowiada, tunel tak.
        let away = try await AddressSelection.firstReachable(attempts) { attempt in
            attempt.url.scheme == "http" ? .unreachable("przekroczony czas") : .reached(1)
        }
        #expect(away.url.absoluteString == "https://t.example.com")
    }

    @Test func stopAndUnreachable() async {
        struct Rejected: Error {}
        let attempts = AddressSelection.attempts(for: [address("http://mac.local", .local), address("https://t.example.com", .remote)])
        await #expect(throws: Rejected.self) {
            _ = try await AddressSelection.firstReachable(attempts) { _ -> AddressSelection.Outcome<Int> in .stop(Rejected()) }
        }
        do {
            _ = try await AddressSelection.firstReachable(attempts) { _ -> AddressSelection.Outcome<Int> in .unreachable("brak") }
            Issue.record("powinien rzucić")
        } catch let error as AddressSelection.Unreachable {
            #expect(error.details.count == 2)
        } catch {
            Issue.record("nieoczekiwany błąd \(error)")
        }
    }

    @Test func connectionErrors() {
        #expect(AddressSelection.isConnectionError(URLError(.timedOut)))
        #expect(AddressSelection.isConnectionError(URLError(.notConnectedToInternet)))
        #expect(!AddressSelection.isConnectionError(URLError(.cancelled)))
        #expect(AddressSelection.isConnectionError(AudiobookshelfClient.APIError.http(status: 530, message: "")))
        #expect(!AddressSelection.isConnectionError(AudiobookshelfClient.APIError.http(status: 404, message: "")))
        #expect(!AddressSelection.isConnectionError(AudiobookshelfClient.APIError.unauthorized))
    }
}

private actor Recorder {
    var urls: [URL] = []
    func add(_ url: URL) { urls.append(url) }
}
