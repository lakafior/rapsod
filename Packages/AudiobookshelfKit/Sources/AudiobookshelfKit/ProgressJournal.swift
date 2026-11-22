// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 10f). Łączy magazyn lokalnego postępu odcinków z etapu
// 10e (`LocalEpisodeStore`) z kolejką niewysłanych pozycji, która w etapie 10c była tylko
// w pamięci. Kształt sesji lokalnych — z kodu serwera audiobookshelf
// (`PlaybackSessionManager.syncLocalSession`), bez przenoszenia jego kodu.

import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "net.smigi.abswift", category: "ProgressJournal")

/// Ostatnia znana pozycja w pozycji (albo odcinku) serwera — zapisana na tym urządzeniu.
public struct PositionRecord: Codable, Sendable, Equatable {
    public var itemID: String
    public var episodeID: String?
    public var currentTime: Double
    public var duration: Double
    public var isFinished: Bool
    /// Chwila zmiany: dla zmian z tego urządzenia — chwila słuchania (zegar urządzenia),
    /// dla przejętych z serwera — jego `lastUpdate`.
    public var updatedAt: Date
    /// Zmiana z tego urządzenia, której serwer jeszcze nie potwierdził.
    public var isUnsent: Bool

    public var key: String { ProgressJournal.key(itemID, episodeID) }
    public var fraction: Double { isFinished ? 1 : (duration > 0 ? min(1, max(0, currentTime / duration)) : 0) }

    public init(itemID: String, episodeID: String?, currentTime: Double, duration: Double, isFinished: Bool, updatedAt: Date, isUnsent: Bool) {
        self.itemID = itemID
        self.episodeID = episodeID
        self.currentTime = currentTime
        self.duration = duration
        self.isFinished = isFinished
        self.updatedAt = updatedAt
        self.isUnsent = isUnsent
    }
}

/// Słuchanie bez sesji serwera (plik pobrany na urządzenie) — wysyłane jako „sesja lokalna”
/// (`POST /api/session/local-all`). Serwer zapisuje ją w statystykach słuchania i sam rozstrzyga,
/// czy jej pozycja jest nowsza niż postęp, który ma (porównuje `updatedAt`).
///
/// Identyfikator to zwykły UUID: ponowne wysłanie tej samej sesji aktualizuje ją na serwerze
/// zamiast dopisywać nową, a `timeListening` jest sumą od początku sesji — wysyłkę można więc
/// bezpiecznie powtarzać.
public struct LocalListeningSession: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var itemID: String
    public var episodeID: String?
    public var libraryID: String?
    /// `book` albo `podcast`.
    public var mediaType: String
    public var displayTitle: String
    public var displayAuthor: String?
    public var duration: Double
    public var startTime: Double
    public var currentTime: Double
    /// Sekundy faktycznie przesłuchane od początku sesji.
    public var timeListening: Double
    public var startedAt: Date
    public var updatedAt: Date
    /// Sesja trwa (książka załadowana w odtwarzaczu). Zamknięta znika po udanej wysyłce.
    public var isOpen: Bool
    /// `updatedAt` stanu, który serwer już przyjął.
    public var uploadedUpTo: Date?

    public var key: String { ProgressJournal.key(itemID, episodeID) }
    public var needsUpload: Bool { uploadedUpTo.map { $0 < updatedAt } ?? true }

    public init(id: String = UUID().uuidString.lowercased(), itemID: String, episodeID: String?, libraryID: String?, mediaType: String, displayTitle: String, displayAuthor: String?, duration: Double, startTime: Double, startedAt: Date = .now) {
        self.id = id
        self.itemID = itemID
        self.episodeID = episodeID
        self.libraryID = libraryID
        self.mediaType = mediaType
        self.displayTitle = displayTitle
        self.displayAuthor = displayAuthor
        self.duration = duration
        self.startTime = startTime
        self.currentTime = startTime
        self.timeListening = 0
        self.startedAt = startedAt
        self.updatedAt = startedAt
        self.isOpen = true
        self.uploadedUpTo = nil
    }
}

/// Postęp serwera w chwili decyzji: osiągalny i znany, osiągalny i pusty, nieosiągalny.
public enum ServerProgressLookup: Sendable, Equatable {
    case unreachable
    case none
    case some(AudiobookshelfClient.MediaProgress)
}

/// Reguły scalania pozycji z urządzenia i z serwera: wygrywa nowszy zapis. Pozycja przejęta
/// z serwera nigdy nie wraca na serwer — tylko zmiany z tego urządzenia.
public enum ProgressMerge {
    public struct StartPoint: Equatable, Sendable {
        public var time: Double
        public var isFinished: Bool
        /// Pozycja z tego urządzenia, nowsza niż serwer — trzeba ją wysłać.
        public var fromDevice: Bool

        public init(time: Double, isFinished: Bool, fromDevice: Bool) {
            self.time = time
            self.isFinished = isFinished
            self.fromDevice = fromDevice
        }
    }

    /// Skąd zacząć słuchać. `nil` — od początku.
    public static func start(local: PositionRecord?, server: ServerProgressLookup) -> StartPoint? {
        switch server {
        case .some(let remote):
            if let local, local.isUnsent, isNewer(local, thanServer: remote.lastUpdate) {
                return StartPoint(time: local.currentTime, isFinished: local.isFinished, fromDevice: true)
            }
            return StartPoint(time: remote.currentTime ?? 0, isFinished: remote.isFinished, fromDevice: false)
        case .none:
            // Serwer nie zna postępu (nigdy nie słuchano albo ktoś go wyzerował): liczy się tylko
            // niewysłana zmiana z tego urządzenia, nie zapamiętana kopia z serwera.
            guard let local, local.isUnsent else { return nil }
            return StartPoint(time: local.currentTime, isFinished: local.isFinished, fromDevice: true)
        case .unreachable:
            guard let local else { return nil }
            return StartPoint(time: local.currentTime, isFinished: local.isFinished, fromDevice: local.isUnsent)
        }
    }

    public enum UploadDecision: Equatable, Sendable {
        case send
        /// Serwer ma nowszy zapis (np. z Maca) — lokalną zmianę porzucić.
        case serverIsNewer
    }

    /// Czy wysłać niewysłaną pozycję (`PATCH /api/me/progress`) — gdy serwer nie ma nowszej.
    /// `serverLastUpdate` w milisekundach, `nil` = serwer nie zna postępu tej pozycji.
    public static func upload(_ local: PositionRecord, serverLastUpdate: Double?) -> UploadDecision {
        guard let serverLastUpdate else { return .send }
        return isNewer(local, thanServer: serverLastUpdate) ? .send : .serverIsNewer
    }

    /// Ta sama zasada, którą stosuje serwer dla sesji lokalnych: zapis serwera nowszy albo równy wygrywa.
    public static func isNewer(_ local: PositionRecord, thanServer serverLastUpdate: Double) -> Bool {
        serverLastUpdate / 1000 < local.updatedAt.timeIntervalSince1970
    }
}

/// Trwały zapis postępu na urządzeniu (jeden plik JSON na serwer):
/// - **pozycje** pozycji serwera — ostatnia znana (do startu bez sieci) i niewysłane zmiany
///   z tego urządzenia (kolejka, która przeżywa zamknięcie aplikacji),
/// - **sesje lokalne** — słuchanie plików pobranych na urządzenie, do wysłania na serwer,
/// - **odcinki z kanału** (`LocalEpisodeRecord`) — słuchane prosto od wydawcy, zanim serwer je pobrał.
///
/// Zapis po każdej zmianie — zmiany przychodzą najwyżej co kilkanaście sekund (synchronizacja
/// odtwarzacza). Obserwacja jest wąska: zmiana jednej pozycji powiadamia tylko widoki jej
/// `Entry`/`PositionEntry`; listy obserwują `membershipRevision`. Typ nie zależy od iOS —
/// aplikacja na Maca może go użyć tak samo.
@MainActor
@Observable
public final class ProgressJournal {
    /// Odcinek z kanału do obserwacji w widoku.
    @MainActor
    @Observable
    public final class Entry {
        public fileprivate(set) var value: LocalEpisodeRecord?
        init(_ value: LocalEpisodeRecord?) { self.value = value }
    }

    /// Pozycja serwera do obserwacji w widoku (np. postęp pobranej książki bez sieci).
    @MainActor
    @Observable
    public final class PositionEntry {
        public fileprivate(set) var value: PositionRecord?
        init(_ value: PositionRecord?) { self.value = value }
    }

    public nonisolated static func key(_ itemID: String, _ episodeID: String?) -> String {
        episodeID.map { "\(itemID)/\($0)" } ?? itemID
    }

    /// Odcinki z kanału według `LocalEpisodeRecord.id`.
    @ObservationIgnored public private(set) var records: [String: LocalEpisodeRecord] = [:]
    @ObservationIgnored public private(set) var positions: [String: PositionRecord] = [:]
    @ObservationIgnored public private(set) var sessions: [String: LocalListeningSession] = [:]
    /// Rośnie, gdy odcinek z kanału dochodzi albo znika (nie przy zmianie pozycji).
    public private(set) var membershipRevision = 0
    /// Liczba zmian czekających na wysłanie (pozycje i sesje) — do znaczka „niewysłane”.
    public private(set) var unsentCount = 0
    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private var positionEntries: [String: PositionEntry] = [:]
    @ObservationIgnored private let fileURL: URL?

    private struct Snapshot: Codable {
        var version = 1
        var episodes: [LocalEpisodeRecord]
        var positions: [PositionRecord]
        var sessions: [LocalListeningSession]
    }

    /// - Parameters:
    ///   - fileURL: plik dziennika; `nil` — tylko w pamięci (testy).
    ///   - legacyEpisodesURL: plik `LocalEpisodeStore` z etapu 10e (tablica `LocalEpisodeRecord`),
    ///     przenoszony do dziennika przy pierwszym uruchomieniu i potem usuwany.
    public init(fileURL: URL?, legacyEpisodesURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            do {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                records = Dictionary(snapshot.episodes.map { ($0.id, $0) }, uniquingKeysWith: Self.newer)
                positions = Dictionary(snapshot.positions.map { ($0.key, $0) }, uniquingKeysWith: { $0.updatedAt > $1.updatedAt ? $0 : $1 })
                sessions = Dictionary(snapshot.sessions.map { ($0.id, $0) }, uniquingKeysWith: { $0.updatedAt > $1.updatedAt ? $0 : $1 })
            } catch {
                logger.error("Dziennik postępu nieczytelny: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let legacyEpisodesURL, let data = try? Data(contentsOf: legacyEpisodesURL) {
            if let list = try? JSONDecoder().decode([LocalEpisodeRecord].self, from: data) {
                for record in list { records[record.id] = records[record.id].map { Self.newer($0, record) } ?? record }
                logger.notice("Przeniesiono \(list.count) odcinków z lokalnego postępu etapu 10e")
            }
            persist()
            if fileURL != nil { try? FileManager.default.removeItem(at: legacyEpisodesURL) }
        }
        recount()
    }

    private static func newer(_ a: LocalEpisodeRecord, _ b: LocalEpisodeRecord) -> LocalEpisodeRecord {
        a.updatedAt > b.updatedAt ? a : b
    }

    // MARK: - Odcinki z kanału

    public func record(itemID: String, feedKey: String) -> LocalEpisodeRecord? {
        records[LocalEpisodeRecord.id(itemID: itemID, feedKey: feedKey)]
    }

    /// Obiekt wpisu do obserwacji w widoku (tworzony przy pierwszym pytaniu).
    public func entry(itemID: String, feedKey: String) -> Entry {
        let id = LocalEpisodeRecord.id(itemID: itemID, feedKey: feedKey)
        if let entry = entries[id] { return entry }
        let entry = Entry(records[id])
        entries[id] = entry
        return entry
    }

    public func records(itemID: String) -> [LocalEpisodeRecord] {
        records.values.filter { $0.itemID == itemID }
    }

    /// Odcinki z kanału zaczęte i nieukończone, od ostatnio słuchanego (obserwuje tylko dodanie i usunięcie).
    public var inProgress: [LocalEpisodeRecord] {
        _ = membershipRevision
        return records.values.filter { !$0.isFinished }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ record: LocalEpisodeRecord) {
        guard records[record.id] != record else { return }
        let isNew = records[record.id] == nil
        records[record.id] = record
        if let entry = entries[record.id] { entry.value = record }
        if isNew { membershipRevision += 1 }
        persist()
    }

    public func remove(itemID: String, feedKey: String) {
        let id = LocalEpisodeRecord.id(itemID: itemID, feedKey: feedKey)
        guard records.removeValue(forKey: id) != nil else { return }
        entries[id]?.value = nil
        membershipRevision += 1
        persist()
    }

    // MARK: - Pozycje

    public func position(itemID: String, episodeID: String?) -> PositionRecord? {
        positions[Self.key(itemID, episodeID)]
    }

    public func positionEntry(itemID: String, episodeID: String?) -> PositionEntry {
        let key = Self.key(itemID, episodeID)
        if let entry = positionEntries[key] { return entry }
        let entry = PositionEntry(positions[key])
        positionEntries[key] = entry
        return entry
    }

    /// Zmiana pozycji na tym urządzeniu — czeka na wysłanie, dopóki serwer jej nie potwierdzi.
    public func recordLocal(itemID: String, episodeID: String?, currentTime: Double, duration: Double, isFinished: Bool = false, at date: Date = .now) {
        let time = isFinished ? duration : currentTime
        setPosition(PositionRecord(itemID: itemID, episodeID: episodeID, currentTime: time, duration: duration, isFinished: isFinished, updatedAt: date, isUnsent: true))
    }

    /// Postęp z serwera (do startu bez sieci). Niewysłana, nowsza zmiana z urządzenia zostaje.
    public func recordServer(_ progress: AudiobookshelfClient.MediaProgress) {
        guard let itemID = progress.libraryItemId else { return }
        let key = Self.key(itemID, progress.episodeId)
        if let local = positions[key], local.isUnsent, ProgressMerge.isNewer(local, thanServer: progress.lastUpdate) { return }
        setPosition(PositionRecord(
            itemID: itemID, episodeID: progress.episodeId, currentTime: progress.currentTime ?? 0,
            duration: progress.duration ?? positions[key]?.duration ?? 0, isFinished: progress.isFinished,
            updatedAt: Date(timeIntervalSince1970: progress.lastUpdate / 1000), isUnsent: false
        ))
    }

    /// Serwer przyjął zmianę z chwili `upTo` (albo nowszą). Późniejsza zmiana zostaje niewysłana.
    public func markSent(itemID: String, episodeID: String?, upTo date: Date) {
        let key = Self.key(itemID, episodeID)
        guard var record = positions[key], record.isUnsent, record.updatedAt <= date else { return }
        record.isUnsent = false
        setPosition(record)
    }

    /// Serwer ma nowszy zapis — niewysłana zmiana z urządzenia przepada (wpis znika, dopóki
    /// nie przyjdzie stan z serwera).
    public func discardUnsent(itemID: String, episodeID: String?) {
        let key = Self.key(itemID, episodeID)
        guard positions[key]?.isUnsent == true else { return }
        positions[key] = nil
        positionEntries[key]?.value = nil
        persist()
    }

    public func removePosition(itemID: String, episodeID: String?) {
        let key = Self.key(itemID, episodeID)
        guard positions.removeValue(forKey: key) != nil else { return }
        positionEntries[key]?.value = nil
        persist()
    }

    /// Niewysłane zmiany pozycji, od najstarszej.
    public var unsentPositions: [PositionRecord] {
        positions.values.filter(\.isUnsent).sorted { $0.updatedAt < $1.updatedAt }
    }

    private func setPosition(_ record: PositionRecord) {
        guard positions[record.key] != record else { return }
        positions[record.key] = record
        if let entry = positionEntries[record.key], entry.value != record { entry.value = record }
        persist()
    }

    // MARK: - Sesje lokalne

    public func openSession(_ session: LocalListeningSession) {
        sessions[session.id] = session
        persist()
    }

    public func session(id: String) -> LocalListeningSession? { sessions[id] }

    /// Słuchanie w trakcie sesji: nowa pozycja i przesłuchane sekundy (dodawane do sumy).
    public func updateSession(id: String, currentTime: Double, listened: Double, at date: Date = .now) {
        guard var session = sessions[id] else { return }
        session.currentTime = currentTime
        session.timeListening += max(0, listened)
        session.updatedAt = date
        sessions[id] = session
        persist()
    }

    /// Koniec sesji (inna książka, zatrzymanie). Znika po udanej wysyłce.
    public func closeSession(id: String) {
        guard var session = sessions[id], session.isOpen else { return }
        session.isOpen = false
        if !session.needsUpload {
            sessions[id] = nil
        } else {
            sessions[id] = session
        }
        persist()
    }

    /// Serwer przyjął stan sesji z chwili `upTo`.
    public func markUploaded(id: String, upTo date: Date) {
        guard var session = sessions[id] else { return }
        session.uploadedUpTo = max(session.uploadedUpTo ?? .distantPast, date)
        if !session.isOpen, !session.needsUpload {
            sessions[id] = nil
        } else {
            sessions[id] = session
        }
        persist()
    }

    public func removeSession(id: String) {
        guard sessions.removeValue(forKey: id) != nil else { return }
        persist()
    }

    /// Sesje ze zmianami, których serwer jeszcze nie ma, od najstarszej.
    public var sessionsToUpload: [LocalListeningSession] {
        sessions.values.filter(\.needsUpload).sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: - Całość

    /// Usuwa wszystko (np. rozłączenie z serwerem).
    public func removeAll() {
        records = [:]
        positions = [:]
        sessions = [:]
        for entry in entries.values { entry.value = nil }
        for entry in positionEntries.values { entry.value = nil }
        membershipRevision += 1
        persist()
    }

    private func recount() {
        let count = positions.values.count(where: \.isUnsent) + sessions.values.count(where: \.needsUpload)
        if unsentCount != count { unsentCount = count }
    }

    private func persist() {
        recount()
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let snapshot = Snapshot(
                episodes: records.values.sorted { $0.id < $1.id },
                positions: positions.values.sorted { $0.key < $1.key },
                sessions: sessions.values.sorted { $0.id < $1.id }
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            logger.error("Zapis dziennika postępu: \(error.localizedDescription, privacy: .public)")
        }
    }
}
