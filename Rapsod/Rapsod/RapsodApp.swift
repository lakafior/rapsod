import AudiobookshelfPlayback
import SwiftUI

@main
struct RapsodApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(supervisor: appDelegate.supervisor, account: appDelegate.account, loginItem: appDelegate.loginItem, webMode: appDelegate.webMode,
                         settings: appDelegate.settingsNavigation, listening: appDelegate.listening, updates: appDelegate.updates,
                         libraryTasks: appDelegate.libraryTasks, menuBar: appDelegate.menuBar)
        } label: {
            MenuBarLabel(supervisor: appDelegate.supervisor, account: appDelegate.account, settings: appDelegate.settingsNavigation, updates: appDelegate.updates,
                         player: appDelegate.listening.player, menuBar: appDelegate.menuBar, drop: appDelegate.statusItemDrop)
        }
        // Panel jak moduły Centrum sterowania: okładka, suwak i postęp zadań (etap 14d, uzasadnienie w README).
        .menuBarExtraStyle(.window)
        .commands {
            AppCommands(account: appDelegate.account, webMode: appDelegate.webMode, settings: appDelegate.settingsNavigation, updates: appDelegate.updates)
            PlaybackCommands(player: appDelegate.listening.player)
            LibraryViewCommands()
        }

        Window(LibraryWindow.title, id: LibraryWindow.windowID) {
            ReleasedWhenClosed {
                LibraryWindow(listening: appDelegate.listening, supervisor: appDelegate.supervisor, account: appDelegate.account, settings: appDelegate.settingsNavigation)
                    // Adresy serwera dla kanału RSS i powrót do ustawień z arkuszy pozycji.
                    .environment(appDelegate.sharing)
                    .environment(appDelegate.settingsNavigation)
                    // Prośby z menu na pasku menu (wgraj, dodaj podcast) i stan wgrywania dla panelu.
                    .environment(appDelegate.menuBar)
            }
        }
        .defaultSize(width: 1100, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // Czytnik e-booków (etap 9g) — osobne okno na każdy e-book; treść znika po zamknięciu.
        WindowGroup("Czytnik", id: ReaderWindow.windowID, for: ReaderTarget.self) { $target in
            if let target {
                ReaderWindow(listening: appDelegate.listening, target: target)
            }
        }
        .defaultSize(width: 900, height: 760)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        // Tekst książki zsynchronizowany z nagraniem (etap 11b) — większe okno do czytania przy słuchaniu.
        Window("Tekst książki", id: BookTextWindow.windowID) {
            BookTextWindow(listening: appDelegate.listening)
        }
        .defaultSize(width: 760, height: 820)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window(WebUIWindow.title, id: WebUIWindow.windowID) {
            WebUIWindow(supervisor: appDelegate.supervisor, account: appDelegate.account, mode: appDelegate.webMode, settings: appDelegate.settingsNavigation)
        }
        .defaultSize(width: 1200, height: 800)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window(SettingsWindow.title, id: SettingsWindow.windowID) {
            ReleasedWhenClosed {
                SettingsWindow(models: appDelegate.models, navigation: appDelegate.settingsNavigation)
            }
        }
        .defaultSize(width: 860, height: 700)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Źródła metadanych", id: MetadataSourcesWindow.windowID) {
            ReleasedWhenClosed {
                MetadataSourcesWindow(sources: appDelegate.metadataSources)
            }
        }
        .defaultSize(width: 1000, height: 800)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Witaj w Rapsodzie", id: WelcomeWindow.windowID) {
            WelcomeWindow(supervisor: appDelegate.supervisor, account: appDelegate.account)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        // Ekran powitalny otwiera się sam; w menu Okno byłby zbędny.
        .commandsRemoved()

        // Pliki upuszczone na ikonę na pasku menu (etap 14d): wgrać czy dodać folder do biblioteki.
        Window(DropWindow.title, id: DropWindow.windowID) {
            DropWindow(account: appDelegate.account, menuBar: appDelegate.menuBar)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        // Aktualizacje aplikacji (etap 14b): wynik sprawdzenia i opis zmian nowej wersji.
        Window("Aktualizacja Rapsodu", id: UpdateWindow.windowID) {
            UpdateWindow(updates: appDelegate.updates)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window("O programie Rapsod", id: AboutWindow.windowID) {
            AboutWindow(supervisor: appDelegate.supervisor)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        // Otwierane z menu aplikacji („O programie”).
        .commandsRemoved()
    }
}

/// Ikona na pasku menu. Jest jedynym widokiem, który żyje przez cały czas działania
/// aplikacji, więc to ona otwiera ekran powitalny, gdy serwer nie ma żadnej biblioteki,
/// ustawienia, gdy serwer nie wstanie, i okno wyboru po upuszczeniu plików na ikonę.
private struct MenuBarLabel: View {
    let supervisor: ServerSupervisor
    let account: ServerAccount
    let settings: SettingsNavigation
    let updates: UpdateController
    let player: AudiobookPlayer
    let menuBar: MenuBarModel
    let drop: StatusItemDrop
    @Environment(\.openWindow) private var openWindow
    @State private var welcomeShown = false

    private var needsLibrary: Bool {
        account.state == .ready && account.libraries.isEmpty
    }

    /// Ten sam znak co ikona aplikacji (książka ze słuchawkami): pełny, gdy serwer działa,
    /// obrysowy, gdy nie działa; przy błędzie trójkąt ostrzegawczy. Przy przeciąganiu plików nad
    /// ikoną — strzałka „do środka” (podświetlenie celu, jak przy upuszczaniu na Dock).
    /// Odtwarzanie nie zmienia znaku: HIG zaleca stały, rozpoznawalny obrazek, a o odtwarzaniu
    /// mówi już Centrum sterowania („Teraz odtwarzane”).
    private var icon: Image {
        if menuBar.isDropTargeted { return Image(systemName: "tray.and.arrow.down.fill") }
        switch supervisor.state {
        case .running: return Image("MenuBarIcon")
        case .failed: return Image(systemName: "exclamationmark.triangle")
        case .stopped, .starting, .stopping: return Image("MenuBarIconOutline")
        }
    }

    /// VoiceOver czyta nazwę razem ze stanem serwera i odtwarzania.
    private var accessibilityLabel: String {
        var parts = ["Rapsod", supervisor.state.shortStatus.lowercased()]
        if let book = player.book, player.isPlaying { parts.append("odtwarzanie: \(book.title)") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        icon
            .accessibilityLabel(accessibilityLabel)
            .onChange(of: needsLibrary, initial: true) {
                // Raz na uruchomienie aplikacji — zamknięte okno nie wraca samo.
                guard needsLibrary, !welcomeShown else { return }
                welcomeShown = true
                openWindow.bringToFront(id: WelcomeWindow.windowID)
            }
            .task {
                // Okno ikony istnieje dopiero po pierwszym narysowaniu.
                drop.attachSoon()
                // Tryb sprawdzający okno ustawień (tylko testowa kopia, argument `-ABSSettingsTour YES`).
                if SettingsTour.isRequested { openWindow.openSettings(navigation: settings) }
                // Tryb sprawdzający listę w Bibliotece (etap 14c, argument `-ABSLibraryTour <folder>`).
                if LibraryTour.isRequested { openWindow.bringToFront(id: LibraryWindow.windowID) }
            }
            .onChange(of: updates.windowRequest) {
                // Automatyczne sprawdzenie znalazło nową wersję do pokazania.
                openWindow.bringToFront(id: UpdateWindow.windowID)
            }
            .onChange(of: menuBar.dropRequest) {
                openWindow.bringToFront(id: DropWindow.windowID)
            }
            .onChange(of: menuBar.windowRequest) {
                // Kliknięte powiadomienie albo Skrót (etap 14e).
                switch menuBar.windowRequest?.target {
                case .library: openWindow.bringToFront(id: LibraryWindow.windowID)
                case .settings(let destination?): openWindow.openSettings(destination, navigation: settings)
                case .settings(nil): openWindow.openSettings(navigation: settings)
                case .update: openWindow.bringToFront(id: UpdateWindow.windowID)
                case nil: break
                }
            }
            .onChange(of: supervisor.state) {
                drop.attachSoon()
                // Błąd startu ma być widoczny, a nie tylko zmienić ikonę na pasku menu.
                if case .failed = supervisor.state {
                    openWindow.openSettings(.general, navigation: settings)
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let supervisor = ServerSupervisor()
    let account = ServerAccount()
    let loginItem = LoginItem()
    let webMode = WebUIMode()
    let settingsNavigation = SettingsNavigation()
    let updates = UpdateController()
    private(set) lazy var menuBar = MenuBarModel(listening: listening)
    private(set) lazy var statusItemDrop = StatusItemDrop(model: menuBar)
    private(set) lazy var sharing = SharingController(supervisor: supervisor, account: account)
    private(set) lazy var pairing = PhonePairing(account: account, sharing: sharing, supervisor: supervisor)
    private(set) lazy var metadataSources = MetadataSourcesController(account: account)
    private(set) lazy var listening = ListeningController(supervisor: supervisor, account: account)
    private(set) lazy var libraryTasks = LibraryTasks(account: account)
    private(set) lazy var users = UsersModel(account: account)
    let rootReset = RootPasswordReset()
    let avatars = AvatarStore()
    /// Powiadomienia systemowe (etap 14e) i stałe zdarzenia serwera dla nich.
    let notifications = SystemNotifications(center: AppDelegate.notificationCenter())
    private(set) lazy var activityMonitor = ServerActivityMonitor(account: account)
    private(set) lazy var models = AppModels(
        supervisor: supervisor,
        account: account,
        loginItem: loginItem,
        sharing: sharing,
        pairing: pairing,
        metadataSources: metadataSources,
        libraryTasks: libraryTasks,
        users: users,
        avatars: avatars,
        rootReset: rootReset,
        webMode: webMode,
        updates: updates,
        notifications: notifications
    )

    override init() {
        super.init()
        // Akcje Skrótów (etap 14e) działają w tym procesie i potrzebują modeli aplikacji.
        IntentBridge.app = self
        IntentBridge.launchDate = .now
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Najpierw: kliknięcie powiadomienia, które uruchomiło aplikację, przychodzi zaraz po starcie.
        configureNotifications()
        supervisor.onStateChange = { [weak self] state in
            guard let self else { return }
            if state == .running, let environment = supervisor.environment {
                Task { await self.account.connect(environment: environment) }
            } else if state != .running {
                account.disconnect()
            }
        }
        DockIcon.shared.activate()
        sharing.activate()
        metadataSources.activate()
        listening.activate()
        updates.activate()
        #if DEBUG
        // Tryb sprawdzający panel na pasku menu (etap 14d, argument `-ABSMenuBarTour YES`).
        if MenuBarTour.isRequested {
            Task { await MenuBarTour.run(account: account, listening: listening, libraryTasks: libraryTasks, menuBar: menuBar) }
        }
        #endif
        Task.detached(priority: .utility) {
            let removed = KeychainOrphans.prune()
            if removed > 0 { NSLog("Pęk kluczy: usunięto %d wpisów po nieistniejących folderach danych", removed) }
        }
        Task {
            // Reset hasła roota przerwany zamknięciem aplikacji: dokończ albo cofnij, zanim ruszy serwer.
            if let problem = await RootPasswordReset.recoverIfNeeded() {
                supervisor.blockStart(problem)
            } else {
                supervisor.start()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Po zatrzymaniu serwera i reszty: podmiana pakietu, jeśli czeka zweryfikowana nowa wersja.
        updates.launchSwapIfPending()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        DockIcon.reopen(hasVisibleWindows: hasVisibleWindows)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // ⌘Q i „Zakończ” w Docku kończą aplikację razem z serwerem (po jednym pytaniu);
        // samo zamknięcie okien zostawia serwer w tle.
        let serverIsUp = supervisor.hasProcess || sharing.hasRunningExternalAccess || metadataSources.hasProcess
        guard AppQuit.shouldTerminate(serverIsUp: serverIsUp) else { return .terminateCancel }
        guard serverIsUp else { return .terminateNow }
        Task {
            // Najpierw pozycja słuchania — potrzebuje działającego serwera.
            await listening.shutdown()
            // Potem tunel, żeby nie przekazywał ruchu do zamykanego serwera.
            await sharing.shutdown()
            await metadataSources.shutdown()
            await supervisor.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
