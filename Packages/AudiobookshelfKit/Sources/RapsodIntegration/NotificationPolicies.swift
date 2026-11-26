// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 14e).

import Foundation

// MARK: - Skan

public struct ScanCounts: Equatable, Sendable {
    public var added: Int
    public var updated: Int
    public var missing: Int

    public init(added: Int?, updated: Int?, missing: Int?) {
        self.added = max(0, added ?? 0)
        self.updated = max(0, updated ?? 0)
        self.missing = max(0, missing ?? 0)
    }

    public var hasChanges: Bool { added + updated + missing > 0 }
}

public enum ScanOutcome: Equatable, Sendable {
    /// `counts` — `nil`, gdy wynik nie dotarł (zadanie zniknęło z listy bez `task_finished`).
    case finished(ScanCounts?, canceled: Bool)
    case failed(String)
}

/// Kiedy koniec skanu jest wart powiadomienia. Skany bez zmian zleca też sam serwer (obserwator
/// plików, harmonogram, skan po wgraniu albo po zapisie znaczników), więc powiadomienie o każdym
/// byłoby szumem: bez zmian — tylko gdy skan zlecono z tej aplikacji.
public enum ScanNotificationPolicy {
    public static func shouldNotify(_ outcome: ScanOutcome, requestedHere: Bool) -> Bool {
        switch outcome {
        case .failed: true
        case .finished(_, canceled: true): false
        case .finished(let counts, canceled: false): counts?.hasChanges == true || requestedHere
        }
    }
}

// MARK: - Odcinki

/// Pobrany odcinek (z `episode_download_finished`).
public struct DownloadedEpisode: Equatable, Sendable {
    public var downloadID: String
    public var itemID: String
    public var libraryID: String?
    public var podcastTitle: String?
    public var title: String
    public var guid: String?

    public init(downloadID: String, itemID: String, libraryID: String?, podcastTitle: String?, title: String, guid: String?) {
        self.downloadID = downloadID
        self.itemID = itemID
        self.libraryID = libraryID
        self.podcastTitle = podcastTitle
        self.title = title
        self.guid = guid
    }
}

public struct EpisodeBatch: Equatable, Sendable {
    public var itemID: String
    public var libraryID: String?
    public var podcastTitle: String?
    /// W kolejności pobrania (najnowszy na końcu).
    public var episodes: [DownloadedEpisode]

    public init(itemID: String, libraryID: String?, podcastTitle: String?, episodes: [DownloadedEpisode]) {
        self.itemID = itemID
        self.libraryID = libraryID
        self.podcastTitle = podcastTitle
        self.episodes = episodes
    }
}

/// Odcinki pobrane jeden po drugim (serwer pobiera po jednym naraz) zbierane w jedno powiadomienie
/// na podcast: partia wychodzi, gdy przez `quiet` nie doszedł żaden nowy odcinek tego podcastu.
public struct EpisodeBatcher: Sendable {
    public var quiet: TimeInterval
    private var pending: [String: (batch: EpisodeBatch, last: Date)] = [:]
    /// Już zgłoszone pobrania — to samo zdarzenie z dwóch gniazd albo po ponownym połączeniu.
    private var seen: Set<String> = []

    public init(quiet: TimeInterval = 8) {
        self.quiet = quiet
    }

    public var isEmpty: Bool { pending.isEmpty }

    /// Dodaje pobrany odcinek. Zwraca `false`, gdy to powtórka.
    @discardableResult
    public mutating func add(_ episode: DownloadedEpisode, at date: Date) -> Bool {
        guard seen.insert(episode.downloadID).inserted else { return false }
        if var entry = pending[episode.itemID] {
            entry.batch.episodes.append(episode)
            entry.batch.podcastTitle = entry.batch.podcastTitle ?? episode.podcastTitle
            entry.last = date
            pending[episode.itemID] = entry
        } else {
            pending[episode.itemID] = (EpisodeBatch(itemID: episode.itemID, libraryID: episode.libraryID,
                                                    podcastTitle: episode.podcastTitle, episodes: [episode]), date)
        }
        return true
    }

    /// Partie gotowe do pokazania (cisza dłuższa niż `quiet`), od najstarszej.
    public mutating func drain(now: Date) -> [EpisodeBatch] {
        let ready = pending.filter { now.timeIntervalSince($0.value.last) >= quiet }
        for key in ready.keys { pending[key] = nil }
        return ready.values.sorted { $0.last < $1.last }.map(\.batch)
    }

    /// Najbliższa chwila, w której jakaś partia będzie gotowa.
    public var nextDeadline: Date? {
        pending.values.map { $0.last.addingTimeInterval(quiet) }.min()
    }
}

// MARK: - Segmenty sponsorowane

/// Wykrywanie segmentów idzie dwa razy (heurystyka, potem model) i bywa powtarzane ręcznie,
/// a powiadomienie ma być jedno na odcinek i tylko z wykrywania w tle.
public struct SponsorNotificationGate: Sendable {
    private var notified: Set<String> = []

    public init() {}

    public mutating func shouldNotify(key: String, segments: Int, automatic: Bool) -> Bool {
        guard automatic, segments > 0 else { return false }
        return notified.insert(key).inserted
    }
}

// MARK: - Okno na wierzchu

/// Bez powiadomień, gdy okno, którego dotyczą, jest na wierzchu (aktywna aplikacja, okno kluczowe):
/// użytkownik i tak widzi wynik.
public enum NotificationPresentation {
    /// - `relevantWindows`: identyfikatory okien (`Window(id:)`) związanych z rodzajem.
    public static func shouldShow(kind: NotificationKind, appIsActive: Bool, keyWindowID: String?,
                                  relevantWindows: [NotificationKind: Set<String>]) -> Bool {
        guard appIsActive, let keyWindowID else { return true }
        return !(relevantWindows[kind]?.contains(keyWindowID) ?? false)
    }
}
