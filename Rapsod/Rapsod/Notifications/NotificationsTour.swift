#if DEBUG
import AppKit
import AudiobookshelfKit
import RapsodIntegration
import UserNotifications

/// Tryb sprawdzający powiadomienia i Skróty (etap 14e, tylko testowa kopia w Debug, argument
/// `-ABSNotificationsTour YES`). Szczegóły przebiegu w `NotificationsTour+Run.swift`.
@MainActor
enum NotificationsTour {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "ABSNotificationsTour") }

    /// Centrum powiadomień trybu: zapisuje każde żądanie (do sprawdzenia w logu), a do systemu
    /// przekazuje je tylko wtedy, gdy ten pakiet ma już zgodę. O zgodę nie prosi — prośba wymaga
    /// kliknięcia człowieka, a zgoda dotyczy identyfikatora pakietu wspólnego z prawdziwą aplikacją.
    static let center = TourNotificationCenter()

    static func log(_ text: String) {
        print("NTOUR \(text)")
        fflush(stdout)
    }
}

final class TourNotificationCenter: NotificationCenterClient, @unchecked Sendable {
    private let system = SystemNotificationCenter()
    private let lock = NSLock()
    private var _recorded: [String] = []
    private var _forwarded: [String] = []

    /// Identyfikatory zapisanych żądań, po kolei.
    var recorded: [String] { lock.withLock { _recorded } }
    var forwarded: [String] { lock.withLock { _forwarded } }

    /// Tryb udaje zgodę, żeby przejść całą drogę do `add()`; na chwilę — odmowę (strona ustawień).
    var forced: SystemNotifications.Authorization {
        get { lock.withLock { _forced } }
        set { lock.withLock { _forced = newValue } }
    }
    private var _forced: SystemNotifications.Authorization = .authorized
    func authorization() async -> SystemNotifications.Authorization { forced }
    func requestAuthorization() async throws -> Bool { true }

    func add(_ request: sending UNNotificationRequest) async throws {
        let identifier = request.identifier
        lock.withLock { _recorded.append(identifier) }
        let content = request.content
        let line = "notify id=\(request.identifier) category=\(content.categoryIdentifier) thread=\(content.threadIdentifier) title=\(content.title) | \(content.subtitle) | \(content.body)"
        await MainActor.run { NotificationsTour.log(line) }
        let status = await system.authorization()
        if status == .authorized || status == .provisional {
            try await system.add(request)
            lock.withLock { _forwarded.append(identifier) }
        }
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) { system.setCategories(categories) }
    func setDelegate(_ delegate: NotificationDelegate) { system.setDelegate(delegate) }
    func removeDelivered(_ identifiers: [String]) { system.removeDelivered(identifiers) }
}
#endif
