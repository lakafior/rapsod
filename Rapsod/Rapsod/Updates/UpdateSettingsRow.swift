import SwiftUI

/// Wiersz w Ogólne › Aplikacja: przełącznik automatycznego sprawdzania i „Sprawdź teraz”.
struct UpdateSettingsRow: View {
    @Bindable var updates: UpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        LabeledContent {
            HStack {
                Toggle(isOn: $updates.automaticChecks) { Text("Sprawdzaj automatycznie") }
                    .labelsHidden()
                Button("Sprawdź teraz") {
                    updates.checkFromMenu()
                    openWindow.bringToFront(id: UpdateWindow.windowID)
                }
                .disabled(updates.isBusy)
            }
        } label: {
            Text("Sprawdzaj aktualizacje automatycznie")
            Text(summary)
        }
    }

    private var summary: String {
        var text = String(localized: "Przy starcie i raz na dobę pyta GitHuba o nowe wydanie. Wersja \(updates.currentVersion.string)")
        if let pending = updates.pending {
            text += String(localized: " — dostępna \(pending.version.string).")
        } else if let lastCheck = updates.lastCheck {
            text += String(localized: ", ostatnio sprawdzono \(lastCheck.formatted(.relative(presentation: .named))).")
        } else {
            text += "."
        }
        return text
    }
}
