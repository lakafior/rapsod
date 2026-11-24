import AppKit

/// Ikona w Docku jest widoczna, dopóki otwarte jest jakiekolwiek okno aplikacji
/// (także zminimalizowane), i znika po zamknięciu ostatniego.
///
/// Aplikacja ma `LSUIElement`, więc startuje bez ikony; tu tylko przełączamy politykę
/// aktywacji. Nie ma listy okien: liczy się każde zwykłe okno z paskiem tytułu, więc
/// przyszłe okna działają bez zmian. Pomijane są panele (np. wybór folderu), okno
/// ikony na pasku menu i menu.
@MainActor
final class DockIcon {
    static let shared = DockIcon()

    private var observers: [NSObjectProtocol] = []
    private var updateScheduled = false

    func activate() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
            NSApplication.didUnhideNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleUpdate() }
            }
        }
    }

    /// Okno zaraz się otworzy: ikona i menu główne od razu, żeby aktywacja aplikacji
    /// zaraz po tym wezwaniu się powiodła.
    func windowWillOpen() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    /// Zwykłe okna aplikacji, które użytkownik może zgubić: widoczne albo zminimalizowane.
    static var openWindows: [NSWindow] {
        NSApp.windows.filter { window in
            // Bez `canBecomeMain` — dla zminimalizowanego okna zwraca `false`.
            window.styleMask.contains(.titled)
                && !(window is NSPanel)
                && window.level == .normal
                && (window.isVisible || window.isMiniaturized)
        }
    }

    /// Zmiany przychodzą seriami, a przy `willClose` okno jest jeszcze widoczne —
    /// liczymy więc raz, w następnym obiegu pętli.
    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.updateScheduled = false
                self?.update()
            }
        }
    }

    private func update() {
        // Ukryta aplikacja (⌘H) nie ma widocznych okien, ale je ma — ikona zostaje,
        // bo to nią się do nich wraca.
        guard !NSApp.isHidden else { return }
        let hasWindows = !Self.openWindows.isEmpty
        let policy: NSApplication.ActivationPolicy = hasWindows ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        if hasWindows {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        } else {
            // Bez okien oddajemy fokus poprzedniej aplikacji, zanim ikona zniknie.
            NSApp.hide(nil)
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Kliknięcie ikony w Docku: przywraca zminimalizowane okna, gdy żadne nie jest widoczne.
    static func reopen(hasVisibleWindows: Bool) {
        if !hasVisibleWindows {
            openWindows.filter(\.isMiniaturized).forEach { $0.deminiaturize(nil) }
        }
        openWindows.forEach { $0.orderFront(nil) }
        NSApp.activate()
    }

    /// Zamyka wszystkie okna aplikacji; serwer i ikona na pasku menu działają dalej.
    static func closeAllWindows() {
        // `close()` (a nie tylko schowanie) — widoki dostają `onDisappear` i zwalniają treść.
        openWindows.forEach { $0.close() }
    }
}

/// Zakończenie aplikacji wyłącza serwer, więc pełne wyjście jest tylko świadome:
/// z menu ikony na pasku menu, z pozycji w menu aplikacji albo przy wylogowaniu,
/// restarcie i wyłączeniu Maca. ⌘Q i „Zakończ” w Docku tylko zamykają okna.
@MainActor
enum AppQuit {
    private static var isRequested = false

    /// Pełne zakończenie aplikacji razem z serwerem.
    static func quit() {
        isRequested = true
        NSApp.terminate(nil)
    }

    /// Czy `applicationShouldTerminate` ma naprawdę kończyć aplikację.
    static var shouldTerminate: Bool {
        if isRequested { return true }
        // Wylogowanie, restart i wyłączenie Maca przychodzą jako zdarzenie „quit”
        // z podanym powodem (AERegistry.h, kAEQuitReason). „Zakończ” z Docka i ⌘Q go nie mają.
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication) else { return false }
        let reason = AEKeyword(kAEQuitReason)
        return event.attributeDescriptor(forKeyword: reason) != nil
            || event.paramDescriptor(forKeyword: reason) != nil
    }
}
