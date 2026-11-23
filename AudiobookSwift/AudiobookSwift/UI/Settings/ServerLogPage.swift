import SwiftUI

/// Dziennik serwera (Ogólne › Dziennik serwera; etap 5 planu, dawna strona „Log serwera”): log na żywo
/// na całą wysokość okna. Poziom logu jest w Ogólne › Zaawansowane.
struct ServerLogPage: View {
    let models: AppModels

    var body: some View {
        LogView(supervisor: models.supervisor)
            .navigationSubtitle("Dziennik serwera")
    }
}

/// Podgląd `ServerSupervisor.recentLog` z kopiowaniem.
private struct LogView: View {
    let supervisor: ServerSupervisor
    @State private var followTail = true
    /// Tekst pokazany w oknie. Odświeżany najwyżej 4 razy na sekundę: przy skanie serwer dopisuje
    /// dziesiątki wierszy na sekundę, a każda zmiana to nowy układ całego tekstu.
    @State private var text = ""
    @State private var refreshScheduled = false

    /// Najnowszy dzienny plik logu serwera (`metadata/logs/daily/<data>.txt`), a bez niego folder logów.
    private var logFile: URL? {
        guard let dataRoot = supervisor.dataRoot else { return nil }
        let folder = dataRoot.appending(path: "metadata/logs/daily", directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        if let newest = files.filter({ $0.pathExtension == "txt" }).max(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            return newest
        }
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Toggle("Przewijaj automatycznie", isOn: $followTail)
                    .toggleStyle(.checkbox)
                Button("Kopiuj log") {
                    NSPasteboard.copy(supervisor.recentLog.joined(separator: "\n"))
                }
                .disabled(text.isEmpty)
                if let file = logFile {
                    Button("Pokaż plik logu w Finderze") {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                    .help("Dzienne pliki logu serwera w folderze danych (metadata/logs/daily)")
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
