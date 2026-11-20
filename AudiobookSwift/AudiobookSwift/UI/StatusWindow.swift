import SwiftUI

/// Stan serwera, biblioteki, start przy logowaniu i podgląd logu na żywo.
struct StatusWindow: View {
    static let windowID = "status"

    let supervisor: ServerSupervisor
    let account: ServerAccount
    let loginItem: LoginItem
    let sharing: SharingController
    let metadataSources: MetadataSourcesController

    var body: some View {
        VSplitView {
            Form {
                serverSection
                Section("Biblioteki") {
                    LibrarySection(supervisor: supervisor, account: account)
                }
                Section("Konto użytkownika") {
                    UserAccountSection(account: account)
                }
                Section("Połącz telefon") {
                    ConnectPhoneSection(sharing: sharing, supervisor: supervisor, account: account)
                }
                Section("Źródła metadanych") {
                    MetadataSourcesSection(sources: metadataSources)
                }
                loginItemSection
            }
            .formStyle(.grouped)
            .frame(minHeight: 260, idealHeight: 560)

            LogView(lines: supervisor.recentLog, dataRoot: dataRoot)
                .frame(minHeight: 180)
        }
        .frame(minWidth: 620, minHeight: 560)
        .onAppear { loginItem.refresh() }
    }

    private var dataRoot: URL? {
        supervisor.environment?.dataRoot ?? (try? ServerEnvironment.resolveDataRoot())
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
            LabeledContent("Wersja audiobookshelf", value: supervisor.environment?.serverVersion ?? "—")
            LabeledContent("Adres na tym Macu") {
                if let url = supervisor.webURL {
                    Link(url.absoluteString, destination: url)
                } else {
                    Text("—")
                }
            }
            LabeledContent("Folder danych") {
                HStack {
                    Text(dataRoot?.path ?? "—")
                        .textSelection(.enabled)
                        .truncationMode(.middle)
                        .lineLimit(1)
                    if let dataRoot {
                        Button("Pokaż w Finderze") {
                            NSWorkspace.shared.activateFileViewerSelecting([dataRoot])
                        }
                    }
                }
            }
            if account.state == .ready, let username = account.username {
                LabeledContent("Konto do zarządzania", value: "\(username) (hasło w pęku kluczy)")
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

    // MARK: Start przy logowaniu

    private var loginItemSection: some View {
        Section("Ogólne") {
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

/// Podgląd `ServerSupervisor.recentLog` z kopiowaniem.
private struct LogView: View {
    let lines: [String]
    let dataRoot: URL?
    @State private var followTail = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log serwera")
                    .font(.headline)
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

extension ServerState {
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
