import AppKit

/// Pliki i foldery upuszczone na ikonę Rapsodu na pasku menu (etap 14d).
///
/// `MenuBarExtra` nie ma przeciągania, ale jego ikona to zwykłe okno systemu (`NSStatusBarWindow`,
/// bez delegata). Okno zarejestrowane na typ `.fileURL` przekazuje komunikaty przeciągania swojemu
/// delegatowi — tym delegatem zostaje ten obiekt. Okno nie jest nasze, więc gdy ma już innego
/// delegata (np. w przyszłej wersji systemu), zostawiamy je w spokoju: upuszczanie wtedy po prostu
/// nie działa, a menu tak.
///
/// Okna ikony powstają od nowa przy zmianie ekranów, dlatego `attach()` wołane jest przy
/// starcie, przy zmianie wyglądu ikony i przy zmianie układu ekranów — jest idempotentne.
@MainActor
final class StatusItemDrop: NSObject, NSWindowDelegate, NSDraggingDestination {
    private let model: MenuBarModel
    private var observer: NSObjectProtocol?

    /// Upuszczenie przyjmowane jest zawsze — gdy serwer nie działa, okno wyboru mówi to wprost.
    init(model: MenuBarModel) {
        self.model = model
        super.init()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachSoon() }
        }
    }

    /// Okna ikony system składa chwilę po zmianie (start, ekrany, nowy obrazek).
    func attachSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.attach() }
        }
    }

    func attach() {
        for window in NSApp.windows where window.className == "NSStatusBarWindow" && window.delegate == nil {
            window.registerForDraggedTypes([.fileURL])
            window.delegate = self
        }
    }

    private static func urls(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // MARK: NSDraggingDestination

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !Self.urls(sender).isEmpty else { return [] }
        #if DEBUG
        NSLog("MENUBAR drag entered")
        #endif
        model.isDropTargeted = true
        return .copy
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        model.isDropTargeted ? .copy : []
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        #if DEBUG
        NSLog("MENUBAR drag exited")
        #endif
        model.isDropTargeted = false
    }

    func draggingEnded(_ sender: any NSDraggingInfo) {
        model.isDropTargeted = false
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        model.isDropTargeted = false
        let urls = Self.urls(sender)
        guard !urls.isEmpty else { return false }
        // Okno wyboru otwiera się po zakończeniu przeciągania, nie w jego trakcie.
        DispatchQueue.main.async { [model] in
            MainActor.assumeIsolated { model.drop(urls) }
        }
        return true
    }
}
