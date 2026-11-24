// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
import AudiobookshelfKit
import AudiobookshelfPlayback

private func server(_ time: Double, lastUpdate: Double, finished: Bool = false, duration: Double = 100) -> AudiobookshelfClient.MediaProgress {
    .init(libraryItemId: "li", episodeId: nil, duration: duration, progress: time / duration, currentTime: time, isFinished: finished, hideFromContinueListening: nil, lastUpdate: lastUpdate)
}

private func local(_ time: Double, at seconds: Double, finished: Bool = false, unsent: Bool = true) -> PositionRecord {
    PositionRecord(itemID: "li", episodeID: nil, currentTime: finished ? 100 : time, duration: 100, isFinished: finished,
                   updatedAt: Date(timeIntervalSince1970: seconds), isUnsent: unsent)
}

/// Scalanie pozycji z telefonu i z serwera: nowszy zapis wygrywa, przejęte z serwera nie wraca na serwer.
@Suite struct ProgressMergeTests {
    @Test func newerLocalWinsAtStart() {
        let point = ProgressMerge.start(local: local(50, at: 1_000), server: .some(server(20, lastUpdate: 999_000)))
        #expect(point == .init(time: 50, isFinished: false, fromDevice: true))
    }

    @Test func newerServerWinsAtStart() {
        let point = ProgressMerge.start(local: local(50, at: 1_000), server: .some(server(80, lastUpdate: 1_001_000)))
        #expect(point == .init(time: 80, isFinished: false, fromDevice: false))
        // Równy czas — serwer (ta sama zasada co serwer dla sesji lokalnych).
        #expect(ProgressMerge.start(local: local(50, at: 1_000), server: .some(server(80, lastUpdate: 1_000_000)))?.fromDevice == false)
    }

    @Test func cachedServerCopyNeverCompetes() {
        // Zapamiętana kopia z serwera (wysłana) nie wygrywa z serwerem, nawet z późniejszą datą.
        let cached = local(50, at: 5_000, unsent: false)
        #expect(ProgressMerge.start(local: cached, server: .some(server(10, lastUpdate: 1_000)))?.time == 10)
        #expect(ProgressMerge.start(local: cached, server: .none) == nil, "postęp wyzerowany na serwerze")
        #expect(ProgressMerge.start(local: cached, server: .unreachable) == .init(time: 50, isFinished: false, fromDevice: false), "bez sieci — z dziennika")
    }

    @Test func offlineStartUsesUnsent() {
        #expect(ProgressMerge.start(local: local(42, at: 1_000), server: .unreachable) == .init(time: 42, isFinished: false, fromDevice: true))
        #expect(ProgressMerge.start(local: nil, server: .unreachable) == nil)
        #expect(ProgressMerge.start(local: local(42, at: 1_000), server: .none)?.fromDevice == true)
    }

    @Test func finishedAgainstPosition() {
        // Ukończone na telefonie później niż pozycja na serwerze → ukończone.
        let finishedHere = ProgressMerge.start(local: local(0, at: 2_000, finished: true), server: .some(server(30, lastUpdate: 1_000_000)))
        #expect(finishedHere == .init(time: 100, isFinished: true, fromDevice: true))
        // Ukończone na Macu później niż pozycja z telefonu → ukończone z serwera.
        let finishedThere = ProgressMerge.start(local: local(30, at: 1_000), server: .some(server(100, lastUpdate: 2_000_000, finished: true)))
        #expect(finishedThere == .init(time: 100, isFinished: true, fromDevice: false))
        // Słuchanie od nowa na telefonie po ukończeniu na serwerze → pozycja z telefonu.
        let relistened = ProgressMerge.start(local: local(15, at: 3_000), server: .some(server(100, lastUpdate: 2_000_000, finished: true)))
        #expect(relistened == .init(time: 15, isFinished: false, fromDevice: true))
    }

    @Test func uploadOnlyWhenNewer() {
        #expect(ProgressMerge.upload(local(50, at: 1_000), serverLastUpdate: nil) == .send)
        #expect(ProgressMerge.upload(local(50, at: 1_000), serverLastUpdate: 999_000) == .send)
        #expect(ProgressMerge.upload(local(50, at: 1_000), serverLastUpdate: 1_001_000) == .serverIsNewer, "Mac zapisał później — wygrywa serwer")
    }
}

@Suite @MainActor struct ProgressJournalTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "dziennik-\(UUID().uuidString).json")
    }

    @Test func positionsAndSessionsSurviveRestart() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let journal = ProgressJournal(fileURL: file)
        journal.recordLocal(itemID: "li", episodeID: nil, currentTime: 33, duration: 100)
        var session = LocalListeningSession(itemID: "li", episodeID: nil, libraryID: nil, mediaType: "book", displayTitle: "K", displayAuthor: nil, duration: 100, startTime: 10)
        journal.openSession(session)
        journal.updateSession(id: session.id, currentTime: 33, listened: 23)
        journal.updateSession(id: session.id, currentTime: 40, listened: 7)

        let reopened = ProgressJournal(fileURL: file)
        #expect(reopened.position(itemID: "li", episodeID: nil)?.currentTime == 33)
        #expect(reopened.position(itemID: "li", episodeID: nil)?.isUnsent == true)
        session = try #require(reopened.session(id: session.id))
        #expect(session.timeListening == 30, "suma sekund od początku sesji")
        #expect(session.currentTime == 40)
        #expect(reopened.unsentCount == 2)
        #expect(session.isOpen == false, "sesja z poprzedniego uruchomienia jest zamknięta")

        // Wysłana sesja, która została „otwarta” przy zamknięciu aplikacji, znika przy starcie.
        reopened.markUploaded(id: session.id, upTo: session.updatedAt)
        #expect(ProgressJournal(fileURL: file).sessions.isEmpty)
    }

    @Test func serverCopyDoesNotOverwriteNewerUnsent() {
        let journal = ProgressJournal(fileURL: nil)
        journal.recordLocal(itemID: "li", episodeID: nil, currentTime: 50, duration: 100, at: Date(timeIntervalSince1970: 1_000))
        journal.recordServer(server(20, lastUpdate: 999_000))
        #expect(journal.position(itemID: "li", episodeID: nil)?.currentTime == 50)
        journal.recordServer(server(80, lastUpdate: 1_001_000))
        #expect(journal.position(itemID: "li", episodeID: nil) == local(80, at: 1_001, unsent: false))
    }

    @Test func markSentKeepsLaterChange() {
        let journal = ProgressJournal(fileURL: nil)
        journal.recordLocal(itemID: "li", episodeID: nil, currentTime: 50, duration: 100, at: Date(timeIntervalSince1970: 2_000))
        // Serwer potwierdził stan z chwili 1000 — zmiana z 2000 dalej czeka.
        journal.markSent(itemID: "li", episodeID: nil, upTo: Date(timeIntervalSince1970: 1_000))
        #expect(journal.position(itemID: "li", episodeID: nil)?.isUnsent == true)
        journal.markSent(itemID: "li", episodeID: nil, upTo: Date(timeIntervalSince1970: 2_000))
        #expect(journal.position(itemID: "li", episodeID: nil)?.isUnsent == false)
        #expect(journal.unsentCount == 0)
    }

    @Test func closedUploadedSessionDisappears() {
        let journal = ProgressJournal(fileURL: nil)
        let session = LocalListeningSession(itemID: "li", episodeID: nil, libraryID: nil, mediaType: "book", displayTitle: "K", displayAuthor: nil, duration: 100, startTime: 0)
        journal.openSession(session)
        journal.updateSession(id: session.id, currentTime: 5, listened: 5, at: Date(timeIntervalSince1970: 1_000))
        journal.markUploaded(id: session.id, upTo: Date(timeIntervalSince1970: 1_000))
        #expect(journal.sessionsToUpload.isEmpty)
        #expect(journal.session(id: session.id) != nil, "otwarta zostaje")
        journal.closeSession(id: session.id)
        #expect(journal.session(id: session.id) == nil)
    }

    @Test func unreadableJournalIsSetAside() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("{uszkodzony".utf8).write(to: file)
        let journal = ProgressJournal(fileURL: file)
        journal.recordLocal(itemID: "li", episodeID: nil, currentTime: 5, duration: 100)
        let folder = file.deletingLastPathComponent()
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(file.lastPathComponent + ".nieczytelny-") }
        #expect(aside.count == 1, "stary plik nie został nadpisany")
        for name in aside { try? FileManager.default.removeItem(at: folder.appending(path: name)) }
    }

    @Test func migratesEpisodesFromStage10e() throws {
        let legacy = tempFile()
        let file = tempFile()
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: file)
        }
        let record = LocalEpisodeRecord(itemID: "li", feedKey: "g:ep", title: "Odcinek", podcastTitle: "P", guid: "ep", enclosureURL: "https://cdn/ep.mp3",
                                        published: nil, duration: 600, currentTime: 120, isFinished: false, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try JSONEncoder().encode([record]).write(to: legacy)
        let journal = ProgressJournal(fileURL: file, legacyEpisodesURL: legacy)
        #expect(journal.record(itemID: "li", feedKey: "g:ep") == record)
        #expect(!FileManager.default.fileExists(atPath: legacy.path), "stary plik usunięty po przeniesieniu")
        #expect(ProgressJournal(fileURL: file).record(itemID: "li", feedKey: "g:ep") == record)
    }
}

/// Pozycja pobrana na telefon: gra z plików przez sesję lokalną, bez sieci — z dziennika.
extension Stubbed {
@Suite @MainActor struct DownloadedPlaybackTests {
    init() { StubServer.reset() }

    private final class Reachability { var value = false }

    private func makeCoordinator(reachable: Reachability, journal: ProgressJournal) -> PlaybackCoordinator {
        let auth = ListeningAuth(client: StubServer.client(), secret: .apiKey("KLUCZ"))
        let device = AudiobookshelfClient.DeviceInfo(deviceId: "telefon-test", clientName: "Rapsod", clientVersion: "1", manufacturer: "Apple", model: "iPhone")
        let coordinator = PlaybackCoordinator(device: device) { auth }
        coordinator.journal = journal
        coordinator.isReachable = { reachable.value }
        let file = FileManager.default.temporaryDirectory.appending(path: "brak.m4a")
        coordinator.offlineBook = { itemID, episodeID in
            guard itemID == "li", episodeID == nil else { return nil }
            return PlaybackBook(itemID: "li", episodeID: nil, title: "Książka", author: "Autor", duration: 100,
                                tracks: [PlaybackTrack(startOffset: 0, duration: 100, title: "01", source: .file(file))],
                                chapters: [PlaybackChapter(id: 0, start: 0, end: 100, title: "Rozdział 1")])
        }
        return coordinator
    }

    private var calls: [String] { StubServer.requests.map { "\($0.request.httpMethod ?? "") \($0.request.url!.path())" } }

    private func lastBody(_ suffix: String) -> [String: Any]? {
        StubServer.requests.last { $0.request.url!.path().hasSuffix(suffix) }
            .flatMap(\.body).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    @Test func offlineStartAndListeningWithoutServer() async throws {
        let reachable = Reachability()
        let journal = ProgressJournal(fileURL: nil)
        journal.recordServer(server(42, lastUpdate: 1_000_000))
        let coordinator = makeCoordinator(reachable: reachable, journal: journal)
        await coordinator.play(itemID: "li")
        #expect(coordinator.player.book?.key == "li")
        #expect(coordinator.player.currentTime == 39, "pozycja z dziennika, 3 s wcześniej")
        coordinator.player.seek(to: 60)
        await coordinator.sync()
        #expect(calls.isEmpty, "bez sieci żadnych zapytań: \(calls)")
        #expect(journal.position(itemID: "li", episodeID: nil)?.currentTime == 60)
        #expect(journal.position(itemID: "li", episodeID: nil)?.isUnsent == true)
        #expect(journal.sessionsToUpload.count == 1)
        coordinator.player.stop()
    }

    @Test func notDownloadedOfflineGivesMessage() async {
        let coordinator = makeCoordinator(reachable: Reachability(), journal: ProgressJournal(fileURL: nil))
        await coordinator.play(itemID: "inna")
        #expect(coordinator.loadError == PlaybackCoordinator.offlineMessage)
        #expect(coordinator.player.book == nil)
        #expect(calls.isEmpty)
    }

    @Test func uploadsLocalSessionWhenBack() async throws {
        let reachable = Reachability()
        let journal = ProgressJournal(fileURL: nil)
        let coordinator = makeCoordinator(reachable: reachable, journal: journal)
        await coordinator.play(itemID: "li")
        coordinator.player.seek(to: 70)
        await coordinator.sync()
        let session = try #require(journal.sessionsToUpload.first)

        reachable.value = true
        StubServer.handle("POST api/session/local-all") { _ in
            .json(#"{"results":[{"id":"\#(session.id)","success":true,"progressSynced":true}]}"#)
        }
        await coordinator.uploadJournal()
        let body = try #require(lastBody("api/session/local-all"))
        let sent = try #require((body["sessions"] as? [[String: Any]])?.first)
        #expect(sent["id"] as? String == session.id)
        #expect(sent["currentTime"] as? Double == 70)
        #expect(sent["playMethod"] as? Int == 3)
        #expect((sent["updatedAt"] as? Double ?? 0) > 1_000_000_000_000, "milisekundy")
        #expect((body["deviceInfo"] as? [String: Any])?["deviceId"] as? String == "telefon-test")
        #expect(journal.unsentCount == 0)
        #expect(journal.position(itemID: "li", episodeID: nil)?.currentTime == 70)
        #expect(!calls.contains { $0.contains("/play") }, "pobrana pozycja nie otwiera sesji serwera")
        coordinator.player.stop()
    }

    @Test func newerServerPositionIsNotOverwritten() async throws {
        let reachable = Reachability()
        let journal = ProgressJournal(fileURL: nil)
        let coordinator = makeCoordinator(reachable: reachable, journal: journal)
        await coordinator.play(itemID: "li")
        coordinator.player.seek(to: 30)
        await coordinator.sync()
        let session = try #require(journal.sessionsToUpload.first)

        // W międzyczasie Mac zapisał 85 s: serwer odrzuca starszą pozycję z sesji.
        reachable.value = true
        let later = (Date.now.timeIntervalSince1970 + 60) * 1000
        StubServer.handle("POST api/session/local-all") { _ in
            .json(#"{"results":[{"id":"\#(session.id)","success":true,"progressSynced":false}]}"#)
        }
        StubServer.on("GET api/me/progress/li", .json(#"{"libraryItemId":"li","episodeId":null,"duration":100,"progress":0.85,"currentTime":85,"isFinished":false,"lastUpdate":\#(later)}"#))
        await coordinator.uploadJournal()
        #expect(journal.unsentCount == 0)
        #expect(journal.position(itemID: "li", episodeID: nil)?.currentTime == 85, "kopia z serwera")
        #expect(!calls.contains { $0.hasPrefix("PATCH") }, "nie nadpisujemy nowszej pozycji z Maca")
        coordinator.player.stop()
    }

    @Test func finishedOfflineIsMarkedOnServer() async throws {
        let reachable = Reachability()
        let journal = ProgressJournal(fileURL: nil)
        let coordinator = makeCoordinator(reachable: reachable, journal: journal)
        await coordinator.play(itemID: "li")
        await coordinator.markFinished()
        #expect(journal.position(itemID: "li", episodeID: nil)?.isFinished == true)
        let session = try #require(journal.sessionsToUpload.first)
        #expect(session.currentTime == 100)

        reachable.value = true
        StubServer.handle("POST api/session/local-all") { _ in
            .json(#"{"results":[{"id":"\#(session.id)","success":true,"progressSynced":true}]}"#)
        }
        StubServer.on("PATCH api/me/progress/li", .json("{}"))
        await coordinator.uploadJournal()
        let patch = try #require(lastBody("api/me/progress/li"))
        #expect(patch["isFinished"] as? Bool == true, "sesja lokalna nie niesie „ukończone”")
        #expect(journal.unsentCount == 0)
        #expect(journal.sessions.isEmpty, "zamknięta i wysłana sesja znika")
    }
}
}
