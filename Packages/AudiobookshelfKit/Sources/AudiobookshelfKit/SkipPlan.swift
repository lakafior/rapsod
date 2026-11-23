// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 13a).

import Foundation

/// Co robić z segmentami danej kategorii (jak w SponsorBlock).
public enum SkipAction: String, Codable, Sendable, CaseIterable, Hashable {
    /// Pomijaj automatycznie (z „Cofnij”).
    case skip
    /// Tylko znacznik na pasku i przycisk „Pomiń”.
    case show
    /// Ignoruj (bez znacznika).
    case ignore

    public var title: String {
        switch self {
        case .skip: "Pomijaj"
        case .show: "Tylko pokazuj"
        case .ignore: "Ignoruj"
        }
    }
}

/// Ustawienie pomijania dla jednego podcastu (na tym urządzeniu). Domyślnie — zgodnie z ustaleniem
/// użytkownika — obie kategorie pomijane automatycznie.
public struct SkipSettings: Codable, Sendable, Equatable {
    /// Wyłącznik całości dla podcastu: bez znaczników i bez pomijania.
    public var enabled: Bool
    public var sponsor: SkipAction
    public var selfPromo: SkipAction

    public init(enabled: Bool = true, sponsor: SkipAction = .skip, selfPromo: SkipAction = .skip) {
        self.enabled = enabled
        self.sponsor = sponsor
        self.selfPromo = selfPromo
    }

    public static let standard = SkipSettings()

    public func action(for kind: SkipKind) -> SkipAction {
        guard enabled else { return .ignore }
        switch kind {
        case .selfPromo: return selfPromo
        case .sponsor: return sponsor
        // Kategoria z nowszej wersji (np. 13b) — bez pomijania, tylko znacznik.
        default: return sponsor == .ignore ? .ignore : .show
        }
    }
}

/// Ustawienie jednego podcastu względem domyślnych (etap 13b): `nil` w kategorii = jak w ustawieniach
/// aplikacji. Zapis z 13a (`SkipSettings` z obiema kategoriami) czyta się jako jawny wybór obu.
public struct SkipPreference: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var sponsor: SkipAction?
    public var selfPromo: SkipAction?

    public init(enabled: Bool = true, sponsor: SkipAction? = nil, selfPromo: SkipAction? = nil) {
        self.enabled = enabled
        self.sponsor = sponsor
        self.selfPromo = selfPromo
    }

    public static let inherit = SkipPreference()
    public var isInherited: Bool { self == .inherit }

    public func resolved(defaults: SkipSettings) -> SkipSettings {
        SkipSettings(enabled: enabled && defaults.enabled, sponsor: sponsor ?? defaults.sponsor, selfPromo: selfPromo ?? defaults.selfPromo)
    }
}

/// Ustawienia pomijania w `UserDefaults`: domyślne dla kategorii (ustawienia aplikacji, 13b) i wyjątki
/// per podcast (klucz: id podcastu na serwerze). Podcast bez wyjątku idzie za domyślnymi.
public struct SkipSettingsStore: Sendable {
    public static let prefix = "skipSettings."
    static let defaultsKey = prefix + "default"
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    /// Domyślne działanie dla kategorii (bez zapisu: obie pomijane, jak w ustaleniu użytkownika).
    public var categoryDefaults: SkipSettings {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let value = try? JSONDecoder().decode(SkipSettings.self, from: data) else { return .standard }
        return value
    }

    public func setCategoryDefaults(_ settings: SkipSettings) {
        if settings == .standard {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    public func preference(podcastID: String) -> SkipPreference {
        guard let data = defaults.data(forKey: Self.prefix + podcastID),
              let value = try? JSONDecoder().decode(SkipPreference.self, from: data) else { return .inherit }
        return value
    }

    public func setPreference(_ preference: SkipPreference, podcastID: String) {
        if preference.isInherited {
            defaults.removeObject(forKey: Self.prefix + podcastID)
        } else if let data = try? JSONEncoder().encode(preference) {
            defaults.set(data, forKey: Self.prefix + podcastID)
        }
    }

    /// Ustawienie obowiązujące dla podcastu: wyjątek albo domyślne.
    public func settings(podcastID: String) -> SkipSettings {
        preference(podcastID: podcastID).resolved(defaults: categoryDefaults)
    }

    /// Zapis pełnego ustawienia (iOS, 13a): równe domyślnym — bez wyjątku; inne — jawny wybór obu kategorii.
    public func set(_ settings: SkipSettings, podcastID: String) {
        if settings == categoryDefaults {
            setPreference(.inherit, podcastID: podcastID)
        } else {
            setPreference(SkipPreference(enabled: settings.enabled, sponsor: settings.sponsor, selfPromo: settings.selfPromo), podcastID: podcastID)
        }
    }
}

/// Segmenty bieżącego odcinka gotowe dla odtwarzacza: po poprawkach, ustawieniach i sprawdzeniu pliku.
/// Decyzja o pominięciu jest czystą funkcją (`decide`), bez AVFoundation.
public struct SkipPlan: Sendable, Equatable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: String
        public var start: Double
        public var end: Double
        public var kind: SkipKind
        public var source: SkipSource
        /// `.skip` albo `.show` (ignorowane nie trafiają do planu).
        public var action: SkipAction
        public var label: String?

        public init(id: String, start: Double, end: Double, kind: SkipKind, source: SkipSource, action: SkipAction, label: String? = nil) {
            self.id = id
            self.start = start
            self.end = end
            self.kind = kind
            self.source = source
            self.action = action
            self.label = label
        }

        public var duration: Double { end - start }
        public func contains(_ time: Double) -> Bool { time >= start && time < end }
    }

    public struct Decision: Sendable, Equatable {
        /// Pierwszy pomijany segment (do „Cofnij”).
        public var entry: Entry
        /// Dokąd przewinąć (koniec segmentu albo łańcucha sąsiednich segmentów).
        public var target: Double
        /// Wszystkie pominięte segmenty łańcucha.
        public var skippedIDs: [String]
    }

    public var entries: [Entry]
    /// Długość pliku, do którego plan się odnosi.
    public var duration: Double
    /// Znaczniki są, ale nie pasują do odtwarzanego pliku (powód do pokazania) — plan jest wtedy pusty.
    public var mismatch: String?

    public static let empty = SkipPlan(entries: [], duration: 0)

    /// Ile przed początkiem segmentu może być poprzednia pozycja, żeby uznać, że odtwarzanie przez
    /// niego przeszło (zegar co 0,5 s, przy 3× to 1,5 s nagrania).
    static let enterTolerance = 0.5
    /// Końcówka segmentu, w której już nie pomijamy (przewinięcie o ułamek sekundy nic nie daje).
    static let tailMargin = 0.75

    public init(entries: [Entry], duration: Double, mismatch: String? = nil) {
        self.entries = entries.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        self.duration = duration
        self.mismatch = mismatch
    }

    /// Plan z pliku znaczników: poprawki użytkownika, ustawienia podcastu i zgodność pliku.
    /// Przy niezgodnym pliku plan jest pusty (czasy wskazywałyby złe miejsca) — tylko powód.
    public init(map: SkipMap?, actual: SkipAudioFingerprint?, settings: SkipSettings) {
        guard let map else {
            self.init(entries: [], duration: actual?.duration ?? 0)
            return
        }
        let duration = actual?.duration ?? map.audio.duration
        if let actual, case .mismatch(let reason) = map.audio.match(actual) {
            self.init(entries: [], duration: duration, mismatch: reason)
            return
        }
        let entries: [Entry] = map.effectiveSegments.compactMap { segment in
            let action = settings.action(for: segment.kind)
            guard action != .ignore, segment.start < duration else { return nil }
            let effective: SkipAction = action == .skip && segment.autoSkip ? .skip : .show
            return Entry(id: segment.id, start: segment.start, end: min(segment.end, duration), kind: segment.kind,
                         source: segment.source, action: effective, label: segment.label)
        }
        self.init(entries: entries, duration: duration)
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Segment pod daną pozycją (pierwszy, gdy nachodzą na siebie).
    public func entry(at time: Double) -> Entry? {
        entries.first { $0.contains(time) }
    }

    /// Czy odtwarzanie od `previous` do `current` weszło w segment do pomijania.
    ///
    /// Pomijamy tylko wtedy, gdy odtwarzanie dotarło do początku segmentu: poprzednia pozycja była
    /// przed nim (albo na samym początku — start odtwarzania, przewinięcie na początek rozdziału).
    /// Przewinięcie w środek segmentu to wybór słuchacza: bez pomijania, z przyciskiem „Pomiń”.
    /// `suppressed` — segmenty po „Cofnij”, grane do końca.
    public func decide(from previous: Double, to current: Double, suppressed: Set<String>) -> Decision? {
        guard current >= previous - 0.01 else { return nil }
        guard let first = entries.first(where: { entry in
            entry.action == .skip && !suppressed.contains(entry.id)
                && previous <= entry.start + Self.enterTolerance
                && current >= entry.start - Self.enterTolerance
                && current < entry.end - Self.tailMargin
        }) else { return nil }
        // Sąsiednie albo nachodzące segmenty — jeden skok na koniec łańcucha.
        var target = first.end
        var skipped = [first.id]
        var changed = true
        while changed {
            changed = false
            for entry in entries where entry.action == .skip && !suppressed.contains(entry.id) && !skipped.contains(entry.id)
                && entry.start <= target + Self.enterTolerance && entry.end > target {
                target = entry.end
                skipped.append(entry.id)
                changed = true
            }
        }
        if duration > 0 { target = min(target, duration) }
        return Decision(entry: first, target: target, skippedIDs: skipped)
    }

    /// Segmenty po „Cofnij” wracają do pomijania, gdy pozycja wyszła poza nie.
    public func stillSuppressed(_ suppressed: Set<String>, at time: Double) -> Set<String> {
        suppressed.filter { id in
            guard let entry = entries.first(where: { $0.id == id }) else { return false }
            return time >= entry.start - 1.5 && time < entry.end
        }
    }
}
