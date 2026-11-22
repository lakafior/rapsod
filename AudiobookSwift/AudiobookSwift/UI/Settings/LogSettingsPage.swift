import SwiftUI

/// Log serwera na żywo na całą wysokość okna.
struct LogSettingsPage: View {
    let models: AppModels

    var body: some View {
        LogView(supervisor: models.supervisor, account: models.account)
    }
}

/// Podgląd `ServerSupervisor.recentLog` z kopiowaniem.
private struct LogView: View {
    let supervisor: ServerSupervisor
    let account: ServerAccount
    @State private var followTail = true
    /// Tekst pokazany w oknie. Odświeżany najwyżej 4 razy na sekundę: przy skanie serwer dopisuje
    /// dziesiątki wierszy na sekundę, a każda zmiana to nowy układ całego tekstu.
    @State private var text = ""
    @State private var refreshScheduled = false

    private var dataRoot: URL? { supervisor.dataRoot }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ServerLogLevelPicker(account: account)
                Spacer()
                Toggle("Przewijaj automatycznie", isOn: $followTail)
                    .toggleStyle(.checkbox)
                Button("Kopiuj log") {
                    NSPasteboard.copy(supervisor.recentLog.joined(separator: "\n"))
                }
                .disabled(text.isEmpty)
                if let dataRoot {
                    Button("Otwórz folder danych") {
                        NSWorkspace.shared.open(dataRoot)
                    }
                }
            }
            .padding(8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(text.isEmpty ? "Brak wpisów." : text)
                            .font(.caption.monospaced())
                            .foregroundStyle(text.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .fixedSize()
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: supervisor.recentLog.last, initial: true) { scheduleRefresh() }
                .onChange(of: supervisor.recentLog.isEmpty) { scheduleRefresh() }
                .onChange(of: text) {
                    if followTail {
                        proxy.scrollTo(Self.bottomID, anchor: .bottomLeading)
                    }
                }
            }
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task {
            if !text.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            refreshScheduled = false
            text = supervisor.recentLog.joined(separator: "\n")
        }
    }

    private static let bottomID = "bottom"
}
