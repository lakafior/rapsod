import SwiftUI

@main
struct AudiobookSwiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ServerMenu(supervisor: appDelegate.supervisor, account: appDelegate.account, loginItem: appDelegate.loginItem, webMode: appDelegate.webMode, settings: appDelegate.settingsNavigation, player: appDelegate.listening.player)
        } label: {
            MenuBarLabel(supervisor: appDelegate.supervisor, account: appDelegate.account, settings: appDelegate.settingsNavigation)
        }
        .commands {
            AppCommands(account: appDelegate.account, webMode: appDelegate.webMode, settings: appDelegate.settingsNavigation)
            PlaybackCommands(player: appDelegate.listening.player)
        }

        Window(LibraryWindow.title, id: LibraryWindow.windowID) {
            ReleasedWhenClosed {
                LibraryWindow(listening: appDelegate.listening, supervisor: appDelegate.supervisor, account: appDelegate.account, settings: appDelegate.settingsNavigation)
                    // Adresy serwera dla kanału RSS i powrót do ustawień z arkuszy pozycji.
                    .environment(appDelegate.sharing)
                    .environment(appDelegate.settingsNavigation)
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

        Window("Witaj w AudiobookSwift", id: WelcomeWindow.windowID) {
            WelcomeWindow(supervisor: appDelegate.supervisor, account: appDelegate.account)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        // Ekran powitalny otwiera się sam; w menu Okno byłby zbędny.
        .commandsRemoved()

        Window("O programie AudiobookSwift", id: AboutWindow.windowID) {
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
/// i ustawienia, gdy serwer nie wstanie.
private struct MenuBarLabel: View {
    let supervisor: ServerSupervisor
    let account: ServerAccount
    let settings: SettingsNavigation
    @Environment(\.openWindow) private var openWindow
    @State private var welcomeShown = false

    private var needsLibrary: Bool {
        account.state == .ready && account.libraries.isEmpty
    }

    var body: some View {
        Image(systemName: supervisor.state.symbolName)
            .accessibilityLabel("AudiobookSwift")
            .onChange(of: needsLibrary, initial: true) {
                // Raz na uruchomienie aplikacji — zamknięte okno nie wraca samo.
                guard needsLibrary, !welcomeShown else { return }
                welcomeShown = true
                openWindow.bringToFront(id: WelcomeWindow.windowID)
            }
            .onChange(of: supervisor.state) {
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
    private(set) lazy var sharing = SharingController(supervisor: supervisor, account: account)
    private(set) lazy var metadataSources = MetadataSourcesController(account: account)
    private(set) lazy var listening = ListeningController(supervisor: supervisor, account: account)
    private(set) lazy var libraryTasks = LibraryTasks(account: account)
    private(set) lazy var models = AppModels(
        supervisor: supervisor,
        account: account,
        loginItem: loginItem,
        sharing: sharing,
        metadataSources: metadataSources,
        libraryTasks: libraryTasks
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        supervisor.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        DockIcon.reopen(hasVisibleWindows: hasVisibleWindows)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // ⌘Q i „Zakończ” w Docku tylko zamykają okna — serwer działa dalej.
        guard AppQuit.shouldTerminate else {
            DockIcon.closeAllWindows()
            return .terminateCancel
        }
        guard supervisor.hasProcess || sharing.hasRunningExternalAccess || metadataSources.hasProcess else { return .terminateNow }
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
