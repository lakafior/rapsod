import AppKit
import Observation
import OSLog
import ServiceManagement

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "LoginItem")

/// Start aplikacji przy logowaniu przez `SMAppService.mainApp`.
///
/// Stan nie jest przechowywany po naszej stronie: użytkownik może go zmienić w Ustawieniach
/// systemowych (Ogólne → Rzeczy otwierane podczas logowania), więc odczytujemy go z systemu
/// przy każdym otwarciu menu i pokazaniu ustawień aplikacji.
@MainActor
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var lastError: String?

    /// Włączone z punktu widzenia użytkownika (zarejestrowane, nawet jeśli czeka na zgodę).
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    @ObservationIgnored private var menuObserver: (any NSObjectProtocol)?

    init() {
        // Menu paska menu to zwykłe NSMenu — odśwież stan za każdym razem, gdy się otwiera.
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let current = SMAppService.mainApp.status
        if current != status {
            status = current
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            logger.error("SMAppService: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

extension SMAppService.Status {
    var title: String {
        switch self {
        case .enabled: "włączony"
        case .requiresApproval: "wymaga zgody w Ustawieniach systemowych"
        case .notRegistered: "wyłączony"
        case .notFound: "wyłączony"
        @unknown default: "nieznany"
        }
    }
}
