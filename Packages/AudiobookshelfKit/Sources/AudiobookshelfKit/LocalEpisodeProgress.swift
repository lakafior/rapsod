// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 10e).

import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "net.smigi.abswift", category: "LocalEpisodes")

/// Postęp odcinka słuchanego wprost od wydawcy, zanim serwer go pobrał (na serwerze odcinka
/// jeszcze nie ma, więc nie ma też gdzie zapisać postępu). Zawiera wszystko, czego trzeba, by
/// pokazać odcinek i wznowić go bez kanału, i by później rozpoznać go na serwerze.
public struct LocalEpisodeRecord: Codable, Sendable, Hashable, Identifiable {
    /// Pozycja podcastu na serwerze.
    public var itemID: String
    /// `RSSEpisode.id`: guid albo adres pliku.
    public var feedKey: String
    public var title: String
    public var podcastTitle: String?
    public var guid: String?
    /// Adres pliku dokładnie jak w kanale.
    public var enclosureURL: String
    public var published: Date?
    public var duration: Double
    public var currentTime: Double
    public var isFinished: Bool
    /// Ostatni zapis na tym telefonie.
    public var updatedAt: Date

    public var id: String { Self.id(itemID: itemID, feedKey: feedKey) }
    public static func id(itemID: String, feedKey: String) -> String { itemID + "\u{1F}" + feedKey }

    public var identity: EpisodeIdentity { EpisodeIdentity(guid: guid, url: enclosureURL, title: title, published: published) }

    public var fraction: Double { isFinished ? 1 : (duration > 0 ? min(1, currentTime / duration) : 0) }

    public init(itemID: String, feedKey: String, title: String, podcastTitle: String?, guid: String?, enclosureURL: String, published: Date?, duration: Double, currentTime: Double, isFinished: Bool, updatedAt: Date) {
        self.itemID = itemID
        self.feedKey = feedKey
        self.title = title
        self.podcastTitle = podcastTitle
        self.guid = guid
        self.enclosureURL = enclosureURL
        self.published = published
        self.duration = duration
        self.currentTime = currentTime
        self.isFinished = isFinished
        self.updatedAt = updatedAt
    }
}

/// Trwały magazyn `LocalEpisodeRecord` (plik JSON) dla jednego serwera. Zapis po każdej zmianie —
/// zmiany przychodzą najwyżej co kilkanaście sekund (synchronizacja odtwarzacza).
///
/// Obserwacja jest wąska: zmiana pozycji jednego odcinka powiadamia tylko widoki jego `Entry`;
/// listy obserwują `membershipRevision` (dodanie albo usunięcie wpisu).
@MainActor
@Observable
public final class LocalEpisodeStore {
    @MainActor
    @Observable
    public final class Entry {
        public fileprivate(set) var value: LocalEpisodeRecord?
        init(_ value: LocalEpisodeRecord?) { self.value = value }
    }

    @ObservationIgnored public private(set) var records: [String: LocalEpisodeRecord] = [:]
    /// Rośnie, gdy wpis dochodzi albo znika (nie przy zmianie pozycji).
    public private(set) var membershipRevision = 0
    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private let fileURL: URL?

    /// `fileURL == nil` — tylko w pamięci (testy).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            do {
                let list = try JSONDecoder().decode([LocalEpisodeRecord].self, from: data)
                records = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updatedAt > b.updatedAt ? a : b })
            } catch {
                logger.error("Lokalny postęp odcinków nieczytelny: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

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

    /// Odcinki zaczęte i nieukończone, od ostatnio słuchanego (obserwuje tylko dodanie i usunięcie).
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

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(records.values.sorted { $0.id < $1.id })
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            logger.error("Zapis lokalnego postępu odcinków: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Co zrobić z lokalnym postępem odcinka, który pojawił się na serwerze.
public enum EpisodeHandover {
    public enum Decision: Equatable, Sendable {
        /// Wysłać na serwer (`PATCH /api/me/progress/:item/:episode`), potem usunąć lokalny wpis.
        case send(currentTime: Double, duration: Double, isFinished: Bool)
        /// Serwer ma nowszy postęp (np. z Maca) — lokalny wpis tylko usunąć.
        case discardLocal
    }

    /// Nowszy zapis wygrywa — ta sama zasada co przy niewysłanych pozycjach (`PendingPosition`).
    /// `serverLastUpdate` w milisekundach; `nil` = serwer nie zna postępu odcinka.
    public static func decide(_ record: LocalEpisodeRecord, serverLastUpdate: Double?, serverDuration: Double?) -> Decision {
        if let serverLastUpdate, serverLastUpdate / 1000 >= record.updatedAt.timeIntervalSince1970 {
            return .discardLocal
        }
        // Brak słuchania (np. tylko zlecone pobranie) — nie ma czego wysyłać.
        if !record.isFinished, record.currentTime < 1 { return .discardLocal }
        // Długość według serwera (plik po pobraniu) bywa inna niż ze strumienia.
        let duration = serverDuration.flatMap { $0 > 0 ? $0 : nil } ?? record.duration
        let time = record.isFinished ? duration : serverTime(record.currentTime, streamDuration: record.duration, serverDuration: duration)
        return .send(currentTime: time, duration: duration, isFinished: record.isFinished)
    }

    /// Miejsce w pliku na serwerze odpowiadające miejscu w strumieniu. Wydawcy wstawiają reklamy
    /// dynamicznie (przekierowania śledzące), więc plik pobrany przez serwer potrafi być o kilkanaście
    /// sekund krótszy albo dłuższy niż ten, który grał telefon. Gdy długości różnią się o ponad 1%,
    /// pozycja jest przeliczana proporcjonalnie — to tylko przybliżenie (dokładne miejsce reklam
    /// nie jest znane), ale nie przeskakuje końcówki i nie oznacza odcinka jako ukończonego za wcześnie.
    public static func serverTime(_ time: Double, streamDuration: Double, serverDuration: Double) -> Double {
        guard streamDuration > 0, serverDuration > 0 else { return time }
        let scaled = abs(streamDuration - serverDuration) / streamDuration > 0.01 ? time * serverDuration / streamDuration : time
        return min(max(0, scaled), serverDuration)
    }

    /// Odcinek serwera, który na pewno jest tym lokalnym (guid albo dokładny adres), albo `nil`.
    public static func serverEpisode(for record: LocalEpisodeRecord, in episodes: [AudiobookshelfClient.PodcastEpisode]) -> AudiobookshelfClient.PodcastEpisode? {
        let mine = record.identity
        let found = episodes.map { (EpisodeMatching.strength(mine, EpisodeIdentity($0)), $0) }
            .filter { $0.0?.isCertain == true }
            .max { ($0.0?.rawValue ?? 0) < ($1.0?.rawValue ?? 0) }
        return found?.1
    }
}
