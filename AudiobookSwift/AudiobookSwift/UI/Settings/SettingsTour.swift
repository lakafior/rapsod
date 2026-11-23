import AppKit
import Foundation

/// Tryb sprawdzający okno ustawień: z argumentem `-ABSSettingsTour YES` aplikacja otwiera okno
/// ustawień i po kolei pokazuje każdą stronę i każdą podstronę obiektu (osoby, root, biblioteki), a postęp
/// wypisuje na standardowe wyjście (`TOUR …`, na końcu `TOUR OK`). Awaria widoku kończy proces,
/// więc brak `TOUR OK` w wyjściu oznacza błąd. `-ABSSettingsTourDelay <sekundy>` wydłuża postój
/// na każdej stronie (np. do zrzutów ekranu robionych z zewnątrz). Tylko do testów na kopii testowej.
@MainActor
enum SettingsTour {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "ABSSettingsTour") }

    private static var delay: Duration {
        let seconds = UserDefaults.standard.double(forKey: "ABSSettingsTourDelay")
        return .milliseconds(Int((seconds > 0 ? seconds : 1) * 1000))
    }

    private static var started = false

    static func runIfRequested(models: AppModels, navigation: SettingsNavigation) async {
        guard isRequested, !started else { return }
        started = true
        // Ostatnia strona jest wspólna z prawdziwą kopią aplikacji (te same UserDefaults) — wraca na koniec.
        let stored = UserDefaults.standard.string(forKey: SettingsNavigation.lastPageKey)
        defer {
            if let stored {
                UserDefaults.standard.set(stored, forKey: SettingsNavigation.lastPageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: SettingsNavigation.lastPageKey)
            }
        }

        // Podstrony kont potrzebują działającego serwera i konta root.
        for _ in 0..<120 where models.account.state != .ready {
            try? await Task.sleep(for: .milliseconds(500))
        }
        log("start account=\(models.account.state == .ready ? "ready" : "not-ready")")

        for page in SettingsPage.allCases {
            navigation.page = page
            log("page \(page.rawValue)")
            try? await Task.sleep(for: delay)
        }
        // „Dostęp zdalny” jeszcze raz, z rozwiniętym „Zaawansowane” (klucze, logowanie, kanały, log tunelu).
        navigation.page = .general
        navigation.pendingAdvanced = .sharing
        navigation.page = .sharing
        log("page sharing-advanced")
        try? await Task.sleep(for: delay + .seconds(1))
        // „Biblioteki” z rozwiniętym „Zaawansowane” (wspólne ustawienia skanera i pamięci podręcznej).
        navigation.page = .general
        navigation.pendingAdvanced = .libraries
        navigation.page = .libraries
        log("page libraries-advanced")
        try? await Task.sleep(for: delay + .seconds(1))
        for destination in await subpages(models: models) {
            navigation.show(destination)
            log("subpage \(destination.tourName)")
            try? await Task.sleep(for: delay)
        }
        navigation.page = .general
        log("OK")
    }

    /// Podstrony do odwiedzenia: profil każdej osoby, strona roota i każda biblioteka.
    private static func subpages(models: AppModels) async -> [SettingsDestination] {
        if models.account.state == .ready, !models.users.hasLoaded { await models.users.load() }
        return models.users.people.map { .user(id: $0.id) } + [.root]
            + models.account.libraries.map { .library(id: $0.id) }
    }

    private static func log(_ text: String) {
        print("TOUR \(text)")
        fflush(stdout)
    }
}

extension SettingsDestination {
    /// Opis do wyjścia trybu sprawdzającego, bez nazw osób.
    var tourName: String {
        switch self {
        case .user: "user"
        case .root: "root"
        case .serverLog: "serverLog"
        case .library: "library"
        }
    }
}
