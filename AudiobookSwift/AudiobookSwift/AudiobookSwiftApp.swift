import SwiftUI

@main
struct AudiobookSwiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ServerMenu(supervisor: appDelegate.supervisor, account: appDelegate.account, loginItem: appDelegate.loginItem, webMode: appDelegate.webMode)
        } label: {
            MenuBarLabel(supervisor: appDelegate.supervisor, account: appDelegate.account)
        }

        Window("Audiobookshelf", id: WebUIWindow.windowID) {
            WebUIWindow(supervisor: appDelegate.supervisor, account: appDelegate.account, mode: appDelegate.webMode)
        }
        .defaultSize(width: 1200, height: 800)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("AudiobookSwift — status", id: StatusWindow.windowID) {
            StatusWindow(supervisor: appDelegate.supervisor, account: appDelegate.account, loginItem: appDelegate.loginItem, sharing: appDelegate.sharing)
        }
        .defaultSize(width: 720, height: 900)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Witaj w AudiobookSwift", id: WelcomeWindow.windowID) {
            WelcomeWindow(supervisor: appDelegate.supervisor, account: appDelegate.account)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("O programie AudiobookSwift", id: AboutWindow.windowID) {
            AboutWindow(supervisor: appDelegate.supervisor)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

/// Ikona na pasku menu. Jest jedynym widokiem, który żyje przez cały czas działania
/// aplikacji, więc to ona otwiera ekran powitalny, gdy serwer nie ma żadnej biblioteki,
/// i okno statusu, gdy serwer nie wstanie.
private struct MenuBarLabel: View {
    let supervisor: ServerSupervisor
    let account: ServerAccount
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
                    openWindow.bringToFront(id: StatusWindow.windowID)
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
    private(set) lazy var sharing = SharingController(supervisor: supervisor, account: account)

    func applicationDidFinishLaunching(_ notification: Notification) {
        supervisor.onStateChange = { [weak self] state in
            guard let self else { return }
            if state == .running, let environment = supervisor.environment {
                Task { await self.account.connect(environment: environment) }
            } else if state != .running {
                account.disconnect()
            }
        }
        sharing.activate()
        supervisor.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard supervisor.hasProcess || sharing.hasRunningExternalAccess else { return .terminateNow }
        Task {
            // Najpierw tunel, żeby nie przekazywał ruchu do zamykanego serwera.
            await sharing.shutdown()
            await supervisor.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
