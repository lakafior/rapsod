import SwiftUI

/// Ogólne (etap 5 planu): stan i sterowanie serwerem z błędem startu, adres, dziennik serwera (podstrona),
/// start przy logowaniu, wykrywanie fragmentów sponsorowanych, a pod „Zaawansowane” wersja audiobookshelf,
/// folder danych, poziom logu i język serwera. Przy błędzie startu aplikacja otwiera tę stronę sama.
struct GeneralSettingsPage: View {
    let models: AppModels

    private var supervisor: ServerSupervisor { models.supervisor }
    private var loginItem: LoginItem { models.loginItem }

    var body: some View {
        SettingsForm {
            serverSection
            loginItemSection
            SponsorDetectionSection(dataRoot: supervisor.dataRoot)
            AdvancedSection(summary: "Wersja audiobookshelf, folder danych, poziom logu i język serwera") {
                advancedRows
            }
        }
    }

    // MARK: Serwer

    private var serverSection: some View {
        Section("Serwer") {
            LabeledContent("Stan") {
                Label(supervisor.state.shortTitle, systemImage: supervisor.state.symbolName)
                    .foregroundStyle(supervisor.state.tint)
            }
            if case .failed(let message) = supervisor.state {
                FailureView(message: message, log: supervisor.recentLog)
            }
            LabeledContent("Adres na tym Macu") {
                if let url = supervisor.webURL {
                    Link(url.absoluteString, destination: url)
                } else {
                    Text("—")
                }
            }
            NavigationLink(value: SettingsDestination.serverLog) {
                Text("Dziennik serwera")
                Text(supervisor.state.isFailed ? "Pełny log — tam widać, dlaczego serwer nie wstał" : "Log na żywo z kopiowaniem")
            }
            HStack {
                Spacer()
                Button("Uruchom") { supervisor.start() }
                    .disabled(!supervisor.state.canStart)
                Button("Zatrzymaj") { Task { await supervisor.stop() } }
                    .disabled(!supervisor.state.canStop)
                Button("Uruchom ponownie") { Task { await supervisor.restart() } }
                    .disabled(!supervisor.state.canStop)
            }
        }
    }

    // MARK: Zaawansowane

    @ViewBuilder
    private var advancedRows: some View {
        LabeledContent("Wersja audiobookshelf", value: supervisor.environment?.serverVersion ?? "—")
        LabeledContent("Folder danych") {
            HStack {
                Text(supervisor.dataRoot?.path ?? "—")
                    .textSelection(.enabled)
                    .truncationMode(.middle)
                    .lineLimit(1)
                if let dataRoot = supervisor.dataRoot {
                    Button("Pokaż w Finderze") {
                        NSWorkspace.shared.activateFileViewerSelecting([dataRoot])
                    }
                }
            }
        }
        ServerLogAndLanguageRows(account: models.account)
    }

    // MARK: Start przy logowaniu

    private var loginItemSection: some View {
        Section("Aplikacja") {
            Toggle("Uruchamiaj przy logowaniu", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            if loginItem.requiresApproval {
                HStack {
                    Text("Start przy logowaniu wymaga zgody w Ustawieniach systemowych.")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Otwórz Ustawienia") { loginItem.openSystemSettings() }
                }
            }
            if let error = loginItem.lastError {
                Text(error).foregroundStyle(.red)
            }
        }
    }
}

extension ServerSupervisor {
    /// Folder danych serwera — także wtedy, gdy serwer jeszcze nie wystartował.
    var dataRoot: URL? {
        environment?.dataRoot ?? (try? ServerEnvironment.resolveDataRoot())
    }
}

/// Czytelny błąd startu: komunikat i ostatnie linie logu, z których wynika.
private struct FailureView: View {
    let message: String
    let log: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.body.weight(.medium))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            let tail = log.suffix(8).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !tail.isEmpty {
                Text(tail.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

extension ServerState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var shortTitle: String {
        switch self {
        case .stopped: "Zatrzymany"
        case .starting: "Uruchamianie…"
        case .running: "Działa"
        case .stopping: "Zatrzymywanie…"
        case .failed: "Błąd"
        }
    }

    var tint: Color {
        switch self {
        case .running: .green
        case .failed: .red
        case .starting, .stopping: .orange
        case .stopped: .secondary
        }
    }
}
