// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 10i). Kształt danych wejściowych odpowiada odpowiedzi
// `GET /api/me/items-in-progress` serwera audiobookshelf v2.38.0 (jedna pozycja na każdy
// zaczęty odcinek — ten sam `id` podcastu powtarza się dla kilku odcinków).

import Foundation

/// Jedna półka „Słuchaj dalej”: książki, odcinki z serwera i odcinki słuchane ze strumienia
/// wydawcy (postęp tylko na telefonie) — razem, bez powtórzeń, od ostatnio słuchanych.
public enum ContinueListening {
    public typealias Client = AudiobookshelfClient

    public struct Entry: Sendable, Identifiable {
        public enum Kind: Sendable {
            case book(Client.LibraryItem)
            /// Odcinek na serwerze. `weakLocal` — lokalny wpis, który „słabo” pasuje do tego
            /// odcinka (ten sam plik po zdjęciu przekierowań albo tytuł z datą): pokazany raz,
            /// razem z odcinkiem serwera; jego postęp przechodzi dopiero po jawnym odtworzeniu.
            case serverEpisode(item: Client.LibraryItem, episode: Client.PodcastEpisode, weakLocal: LocalEpisodeRecord?)
            /// Odcinek słuchany ze strumienia, którego serwer (jeszcze) nie ma.
            case localEpisode(LocalEpisodeRecord)
        }

        /// Klucz postępu: `itemID` albo `itemID/episodeID` (`ProgressJournal.key`), a dla
        /// odcinka ze strumienia — `LocalEpisodeRecord.id`. Niepowtarzalny na półce.
        public let id: String
        public let kind: Kind
        /// Ostatnie słuchanie (milisekundy od 1970).
        public let lastUpdate: Double

        public var itemID: String {
            switch kind {
            case .book(let item): item.id
            case .serverEpisode(let item, _, _): item.id
            case .localEpisode(let record): record.itemID
            }
        }
    }

    public struct Result: Sendable {
        public var entries: [Entry] = []
        /// Lokalne wpisy, które na pewno są odcinkami serwera (guid albo dokładny adres) —
        /// ukryte na półce, do przekazania na serwer (`EpisodeHandover`).
        public var handover: [LocalEpisodeRecord] = []
    }

    /// Łączy źródła „Słuchaj dalej”.
    /// - `books`: półka książek z serwera (już bez ukrytych).
    /// - `serverEpisodes`: pozycje podcastów z `items-in-progress` (każda z `recentEpisode`).
    /// - `local`: odcinki w trakcie słuchane ze strumienia.
    /// - `lastUpdate`: ostatnie słuchanie według `/api/me` (ms), klucz jak `ProgressJournal.key`.
    public static func merge(
        books: [Client.LibraryItem],
        serverEpisodes: [Client.LibraryItem],
        local: [LocalEpisodeRecord],
        lastUpdate: [String: Double] = [:],
        limit: Int = 20
    ) -> Result {
        var result = Result()
        var seen = Set<String>()
        var entries: [Entry] = []

        for item in books where !item.isPodcast {
            guard seen.insert(item.id).inserted else { continue }
            entries.append(Entry(id: item.id, kind: .book(item), lastUpdate: lastUpdate[item.id] ?? item.progressLastUpdate ?? 0))
        }

        // Odcinki serwera: jeden wpis na odcinek (nie na podcast — `id` pozycji się powtarza).
        var episodes: [(item: Client.LibraryItem, episode: Client.PodcastEpisode, key: String)] = []
        for item in serverEpisodes {
            guard let episode = item.recentEpisode else { continue }
            let key = ProgressJournal.key(item.id, episode.id)
            guard seen.insert(key).inserted else { continue }
            episodes.append((item, episode, key))
        }

        // Lokalne wpisy dopasowane do odcinków tej samej pozycji (para do pary).
        var weak: [String: LocalEpisodeRecord] = [:]
        var pending = local
        for (itemID, records) in Dictionary(grouping: local, by: \.itemID) {
            let candidates = episodes.filter { $0.item.id == itemID }
            guard !candidates.isEmpty else { continue }
            let matches = EpisodeMatching.match(records.map(\.identity), candidates.map { EpisodeIdentity($0.episode) })
            for (index, match) in matches {
                let record = records[index]
                pending.removeAll { $0.id == record.id }
                if match.strength.isCertain {
                    result.handover.append(record)
                } else {
                    weak[candidates[match.other].key] = record
                }
            }
        }

        for (item, episode, key) in episodes {
            let server = lastUpdate[key] ?? item.progressLastUpdate ?? 0
            let local = weak[key]
            // Słabe dopasowanie: na półce liczy się nowszy z dwóch zapisów.
            let latest = max(server, (local?.updatedAt.timeIntervalSince1970 ?? 0) * 1000)
            entries.append(Entry(id: key, kind: .serverEpisode(item: item, episode: episode, weakLocal: local), lastUpdate: latest))
        }
        for record in pending where !record.isFinished && seen.insert(record.id).inserted {
            entries.append(Entry(id: record.id, kind: .localEpisode(record), lastUpdate: record.updatedAt.timeIntervalSince1970 * 1000))
        }

        result.entries = Array(entries.enumerated().sorted { a, b in
            a.element.lastUpdate != b.element.lastUpdate ? a.element.lastUpdate > b.element.lastUpdate : a.offset < b.offset
        }.map(\.element).prefix(limit))
        return result
    }
}

extension ContinueListening {
    /// Kilka ostatnich pozycji do wznowienia jednym kliknięciem (menu na pasku menu, etap 14d):
    /// odpowiedź `items-in-progress` (książki i odcinki razem) bez pozycji ukończonych albo
    /// ukrytych w „Słuchaj dalej” według postępu z `/api/me` (klucz `ProgressJournal.key`).
    /// Odcinki słuchane tylko ze strumienia (telefon) się tu nie pojawiają.
    public static func recent(
        inProgress: [Client.LibraryItem],
        progress: [String: Client.MediaProgress],
        limit: Int = 5
    ) -> [Entry] {
        let lastUpdate = progress.mapValues(\.lastUpdate)
        let merged = merge(
            books: inProgress.filter { !$0.isPodcast },
            serverEpisodes: inProgress.filter(\.isPodcast),
            local: [],
            lastUpdate: lastUpdate,
            limit: .max
        )
        return Array(merged.entries.filter { entry in
            guard let known = progress[entry.id] else { return true }
            return !known.isFinished && known.hideFromContinueListening != true
        }.prefix(limit))
    }
}

extension EpisodeHandover {
    /// Co zrobić z lokalnym wpisem, który tylko „słabo” pasuje do odcinka serwera (bez pewności,
    /// że to ten sam odcinek). Bez jawnego działania postęp nie przechodzi na serwer; wpis znika
    /// sam, gdy serwer ma nowszy zapis (np. odcinek dosłuchany na Macu) — nic się wtedy nie traci.
    /// `serverLastUpdate` w milisekundach.
    public static func weakMatchIsStale(_ record: LocalEpisodeRecord, serverLastUpdate: Double?) -> Bool {
        guard let serverLastUpdate else { return false }
        return serverLastUpdate / 1000 >= record.updatedAt.timeIntervalSince1970
    }

    /// Miejsce startu odcinka serwera, gdy użytkownik odtwarza go, a telefon ma nowszy, słabo
    /// dopasowany zapis ze strumienia: pozycja z telefonu przeliczona na plik serwera (albo `nil`
    /// — zapis serwera jest nowszy albo nie ma czego przejmować). Wpis lokalny trzeba potem usunąć.
    public static func adoptedStart(_ record: LocalEpisodeRecord, serverLastUpdate: Double?, serverDuration: Double?) -> Double? {
        if weakMatchIsStale(record, serverLastUpdate: serverLastUpdate) { return nil }
        guard case .send(let time, let duration, let finished) = decide(record, serverLastUpdate: serverLastUpdate, serverDuration: serverDuration) else { return nil }
        return finished ? 0 : min(time, max(0, duration - 1))
    }
}
