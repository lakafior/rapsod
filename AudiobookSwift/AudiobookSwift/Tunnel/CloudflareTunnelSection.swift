import SwiftUI

/// Wiersze trybu „Cloudflare Tunnel” na stronie „Dostęp zdalny”: instalacja `cloudflared`, stan,
/// opublikowany adres i token (pole w wierszu przy pierwszym ustawieniu, potem „Zmień…” w arkuszu).
/// Log tunelu jest osobno, pod „Zaawansowane” (`CloudflareTunnelLogRows`).
struct CloudflareTunnelSection: View {
    let tunnel: CloudflareTunnel

    @State private var tokenText = ""
    @State private var changingToken = false

    var body: some View {
        if tunnel.cloudflared == nil {
            installHint
        } else {
            statusRows
            tokenRows
        }
    }

    // MARK: Brak cloudflared

    @ViewBuilder
    private var installHint: some View {
        Text("Do tunelu potrzebny jest program cloudflared. Zainstaluj go oficjalnym instalatorem `cloudflared-arm64.pkg` ze strony github.com/cloudflare/cloudflared/releases albo poleceniem `brew install cloudflared` i wybierz „Sprawdź ponownie”. Bez niego reszta aplikacji działa normalnie.")
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button("Sprawdź ponownie") { Task { await tunnel.retry() } }
        }
    }

    // MARK: Token

    @ViewBuilder
    private var tokenRows: some View {
        if tunnel.tunnelID != nil {
            LabeledContent("Token tunelu") {
                HStack {
                    Text("zapisany w pęku kluczy").foregroundStyle(.secondary)
                    Button("Zmień…") { changingToken = true }
                }
            }
            .sheet(isPresented: $changingToken) {
                TunnelTokenSheet(tunnel: tunnel)
            }
        } else {
            LabeledContent("Token tunelu") {
                HStack {
                    SecureField("Token tunelu", text: $tokenText, prompt: Text("wklej token lub polecenie z panelu Cloudflare"))
                        .labelsHidden()
                        .onSubmit(saveToken)
                    Button("Zapisz", action: saveToken)
                        .disabled(tokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text(TunnelTokenSheet.instruction)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = tunnel.tokenError {
                Text(error)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func saveToken() {
        let text = tokenText
        Task {
            if await tunnel.saveToken(text) {
                tokenText = ""
            }
        }
    }

    // MARK: Stan

    @ViewBuilder
    private var statusRows: some View {
        LabeledContent("Stan") {
            Label(tunnel.state.title, systemImage: tunnel.state.symbolName)
                .foregroundStyle(tunnel.state.tint)
        }
        if let detail = tunnel.state.detail {
            Text(detail)
                .foregroundStyle(tunnel.state.tint)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        if let problem = tunnel.configurationProblem {
            Text(problem)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        if case .failed = tunnel.state {
            HStack {
                Spacer()
                Button("Spróbuj ponownie") { Task { await tunnel.retry() } }
            }
        }
        if let url = tunnel.publicURL {
            CopyableRow(title: "Adres", value: url.absoluteString)
        }
    }
}

/// Zmiana albo usunięcie zapisanego tokenu tunelu (dawne „Nowy token” i „Usuń token”).
struct TunnelTokenSheet: View {
    let tunnel: CloudflareTunnel
    @Environment(\.dismiss) private var dismiss
    @State private var tokenText = ""
    @State private var confirmingRemoval = false

    static let instruction = "W panelu Cloudflare: Networking → Tunnels → Create tunnel (Cloudflared), skopiuj polecenie instalacji z tokenem i wklej je tutaj. Potem w zakładce Routes dodaj „Published application”: własna nazwa w Twojej domenie, usługa http://127.0.0.1:\(String(ServerEnvironment.port)). Token trafia tylko do pęku kluczy."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    if let tunnelID = tunnel.tunnelID {
                        LabeledContent("Obecny tunel") {
                            Text(tunnelID)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    SecureField("Nowy token", text: $tokenText, prompt: Text("wklej token lub polecenie z panelu Cloudflare"))
                    if let error = tunnel.tokenError {
                        Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Token tunelu Cloudflare")
                } footer: {
                    Text(Self.instruction)
                }
                Section {
                    Button("Usuń token…", role: .destructive) { confirmingRemoval = true }
                } footer: {
                    Text("Bez tokenu tunel się zatrzyma, a adres spoza domu przestanie działać.")
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Anuluj", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Zapisz") {
                    let text = tokenText
                    Task { if await tunnel.saveToken(text) { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(tokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 540, height: 380)
        .confirmationDialog("Usunąć token tunelu?", isPresented: $confirmingRemoval) {
            Button("Usuń token", role: .destructive) {
                Task {
                    await tunnel.removeToken()
                    dismiss()
                }
            }
        } message: {
            Text("Tunel się zatrzyma. Telefony i inne urządzenia spoza domu stracą połączenie, dopóki nie zapiszesz nowego tokenu.")
        }
        .onDisappear { tokenText = "" }
    }
}

/// Log tunelu (rozwijany, składany dopiero po rozwinięciu) — pod „Zaawansowane” na „Dostępie zdalnym”.
struct CloudflareTunnelLogRows: View {
    let tunnel: CloudflareTunnel
    @State private var showsLog = false

    var body: some View {
        if tunnel.recentLog.isEmpty {
            LabeledContent("Log tunelu", value: "pusty")
        } else {
            DisclosureGroup("Log tunelu (\(tunnel.recentLog.count) wpisów)", isExpanded: $showsLog) {
                if showsLog {
                    VStack(alignment: .trailing) {
                        ScrollView([.vertical, .horizontal]) {
                            Text(tunnel.recentLog.suffix(120).joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .fixedSize()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 160)
                        Button("Kopiuj log tunelu") {
                            NSPasteboard.copy(tunnel.recentLog.joined(separator: "\n"))
                        }
                    }
                }
            }
        }
    }
}

extension CloudflareTunnel.State {
    var title: String {
        switch self {
        case .off: "Wyłączony"
        case .unavailable: "Brak cloudflared"
        case .needsToken: "Brak tokenu"
        case .waitingForServer: "Czeka na serwer"
        case .connecting: "Łączenie…"
        case .connected: "Połączony"
        case .failed: "Błąd"
        }
    }

    var detail: String? {
        switch self {
        case .connecting(let reason): reason
        case .failed(let message): message
        case .waitingForServer: "Tunel ruszy, gdy serwer będzie działał i miał konto root."
        default: nil
        }
    }

    var symbolName: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .connecting, .waitingForServer: "arrow.triangle.2.circlepath"
        case .failed, .unavailable: "exclamationmark.triangle.fill"
        case .off, .needsToken: "circle"
        }
    }

    var tint: Color {
        switch self {
        case .connected: .green
        case .connecting, .waitingForServer: .orange
        case .failed, .unavailable: .red
        case .off, .needsToken: .secondary
        }
    }
}
