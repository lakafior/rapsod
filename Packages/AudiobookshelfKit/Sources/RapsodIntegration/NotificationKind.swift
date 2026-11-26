// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 14e).

import Foundation

/// Rodzaj powiadomienia systemowego aplikacji na Maca. Każdy ma osobny przełącznik na stronie
/// „Powiadomienia” w Ustawieniach i osobną kategorię (akcje w powiadomieniu).
public enum NotificationKind: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Koniec skanu biblioteki (z liczbą dodanych, zmienionych i brakujących pozycji).
    case libraryScan
    /// Serwer pobrał nowe odcinki podcastu.
    case newEpisodes
    /// Koniec wgrywania książek i scalania do M4B (także błąd).
    case uploads
    /// Nowa wersja aplikacji.
    case appUpdate
    /// Wykryte segmenty sponsorowane w nowym odcinku.
    case sponsorSegments

    public var id: String { rawValue }

    /// Wykrywanie segmentów działa w tle przy każdym nowym odcinku — powiadomienie o tym byłoby
    /// zbyt częste, więc domyślnie wyłączone (decyzja z zadania etapu 14e).
    public var enabledByDefault: Bool { self != .sponsorSegments }

    /// Identyfikator kategorii `UNNotificationCategory`.
    public var categoryIdentifier: String { "rapsod.\(rawValue)" }

    public init?(categoryIdentifier: String) {
        guard categoryIdentifier.hasPrefix("rapsod.") else { return nil }
        self.init(rawValue: String(categoryIdentifier.dropFirst("rapsod.".count)))
    }
}

/// Przycisk w powiadomieniu. Kliknięcie samego powiadomienia (akcja domyślna) otwiera właściwe
/// miejsce w aplikacji, więc przyciski są tylko dla czynności innych niż „otwórz” (HIG: Notifications).
public enum NotificationAction: String, Sendable, CaseIterable {
    /// Odtwarza pozycję w tle, bez otwierania okna.
    case play = "rapsod.action.play"
    /// Pobiera i instaluje nową wersję (otwiera okno aktualizacji z postępem).
    case install = "rapsod.action.install"

    /// Przyciski kategorii danego rodzaju.
    public static func actions(for kind: NotificationKind) -> [NotificationAction] {
        switch kind {
        case .newEpisodes, .sponsorSegments: [.play]
        case .appUpdate: [.install]
        case .libraryScan, .uploads: []
        }
    }
}

/// Zapamiętany wybór użytkownika: główny przełącznik i przełącznik każdego rodzaju.
///
/// Główny przełącznik jest domyślnie wyłączony — zgody systemu aplikacja prosi dopiero przy jego
/// pierwszym włączeniu. Rodzaje mają własne wartości domyślne (`enabledByDefault`), widoczne od razu
/// pod głównym przełącznikiem.
public struct NotificationPreferences: Equatable, Sendable {
    public var isEnabled: Bool
    private var kinds: [NotificationKind: Bool]

    public init(isEnabled: Bool = false, kinds: [NotificationKind: Bool] = [:]) {
        self.isEnabled = isEnabled
        self.kinds = kinds
    }

    public func isOn(_ kind: NotificationKind) -> Bool {
        kinds[kind] ?? kind.enabledByDefault
    }

    public mutating func set(_ kind: NotificationKind, _ on: Bool) {
        kinds[kind] = on
    }

    /// Czy powiadomienie tego rodzaju ma powstać (główny przełącznik i przełącznik rodzaju).
    public func wants(_ kind: NotificationKind) -> Bool {
        isEnabled && isOn(kind)
    }

    /// Czy potrzebne jest stałe połączenie zdarzeń serwera (skan, odcinki, scalanie do M4B).
    public var needsServerEvents: Bool {
        wants(.libraryScan) || wants(.newEpisodes) || wants(.uploads)
    }

    // MARK: Zapis

    public static let enabledKey = "notifications.enabled"
    public static func key(_ kind: NotificationKind) -> String { "notifications.kind.\(kind.rawValue)" }

    /// Klucze w `UserDefaults` (tryb sprawdzający przywraca je na koniec).
    public static var allKeys: [String] { [enabledKey] + NotificationKind.allCases.map(key) }

    public init(read value: (String) -> Any?) {
        isEnabled = value(Self.enabledKey) as? Bool ?? false
        kinds = [:]
        for kind in NotificationKind.allCases {
            if let on = value(Self.key(kind)) as? Bool { kinds[kind] = on }
        }
    }

    /// Wartości do zapisania (tylko jawnie ustawione rodzaje).
    public var stored: [String: Bool] {
        var result = [Self.enabledKey: isEnabled]
        for (kind, on) in kinds { result[Self.key(kind)] = on }
        return result
    }
}
