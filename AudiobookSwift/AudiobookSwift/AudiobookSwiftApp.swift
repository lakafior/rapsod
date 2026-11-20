import SwiftUI

@main
struct AudiobookSwiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ServerMenu(supervisor: appDelegate.supervisor)
        } label: {
            Image(systemName: appDelegate.supervisor.state.symbolName)
                .accessibilityLabel("AudiobookSwift")
        }

        Window("Audiobookshelf", id: WebUIWindow.windowID) {
            WebUIWindow(supervisor: appDelegate.supervisor)
        }
        .defaultSize(width: 1200, height: 800)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let supervisor = ServerSupervisor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        supervisor.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard supervisor.hasProcess else { return .terminateNow }
        Task {
            await supervisor.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
