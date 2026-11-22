// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 10e). Magazyn tych wpisów jest od etapu 10f częścią
// `ProgressJournal` — jeden trwały zapis postępu na telefonie.

import Foundation

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

/// Co zrobić z lokalnym postępem odcinka, który pojawił się na serwerze.
public enum EpisodeHandover {
    public enum Decision: Equatable, Sendable {
        /// Wysłać na serwer (`PATCH /api/me/progress/:item/:episode`), potem usunąć lokalny wpis.
        case send(currentTime: Double, duration: Double, isFinished: Bool)
        /// Serwer ma nowszy postęp (np. z Maca) — lokalny wpis tylko usunąć.
        case discardLocal
    }

    /// Nowszy zapis wygrywa — ta sama zasada co przy niewysłanych pozycjach (`ProgressMerge`).
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
