import SwiftUI

/// Log serwera na żywo na całą wysokość okna.
struct LogSettingsPage: View {
    let models: AppModels

    var body: some View {
        LogView(lines: models.supervisor.recentLog, dataRoot: models.supervisor.dataRoot, account: models.account)
    }
}

/// Podgląd `ServerSupervisor.recentLog` z kopiowaniem.
private struct LogView: View {
    let lines: [String]
    let dataRoot: URL?
    let account: ServerAccount
    @State private var followTail = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ServerLogLevelPicker(account: account)
                Spacer()
                Toggle("Przewijaj automatycznie", isOn: $followTail)
                    .toggleStyle(.checkbox)
                Button("Kopiuj log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                .disabled(lines.isEmpty)
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
                        Text(lines.isEmpty ? "Brak wpisów." : lines.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .foregroundStyle(lines.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .fixedSize()
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: lines.last, initial: true) {
                    if followTail {
                        proxy.scrollTo(Self.bottomID, anchor: .bottomLeading)
                    }
                }
            }
        }
    }

    private static let bottomID = "bottom"
}
