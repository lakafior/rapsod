import SwiftUI

/// Wiersze trybu „Cloudflare Tunnel” na stronie „Dostęp zdalny”: instalacja `cloudflared`,
/// token z panelu, stan połączenia, opublikowany adres i log tunelu.
struct CloudflareTunnelSection: View {
    let tunnel: CloudflareTunnel
    /// Hasło konta użytkownika — tylko do ostrzeżenia o słabym haśle.
    let phonePassword: String?

    @State private var tokenText = ""
    @State private var showsLog = false

    var body: some View {
        if tunnel.cloudflared == nil {
            installHint
        } else {
            tokenRows
            statusRows
        }

        if let password = phonePassword, password.count < 16 {
            Text("Przez tunel serwer jest dostępny z całego internetu. Hasło konta użytkownika jest krótkie — ustaw dłuższe (najlepiej losowe: puste pole przy zakładaniu konta).")
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text("Darmowy plan Cloudflare zastrzega, że wideo i „nieproporcjonalnie dużo” plików audio i innych dużych plików wymaga płatnych usług; to dotyczy też tuneli. Przy słuchaniu audiobooków Cloudflare może ograniczyć ten adres. Szczegóły w README.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
        if let tunnelID = tunnel.tunnelID {
            LabeledContent("Tunel") {
                HStack {
                    Text(tunnelID)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Button("Usuń token") { Task { await tunnel.removeToken() } }
                }
            }
        }
        LabeledContent(tunnel.tunnelID == nil ? "Token tunelu" : "Nowy token") {
            HStack {
                SecureField("Token tunelu", text: $tokenText, prompt: Text("wklej token lub polecenie z panelu Cloudflare"))
                    .labelsHidden()
                    .onSubmit(saveToken)
                Button("Zapisz", action: saveToken)
                    .disabled(tokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        if tunnel.tunnelID == nil {
            Text("W panelu Cloudflare: Networking → Tunnels → Create tunnel (Cloudflared), skopiuj polecenie instalacji z tokenem i wklej je tutaj. Potem w zakładce Routes dodaj „Published application”: własna nazwa w Twojej domenie, usługa http://127.0.0.1:\(String(ServerEnvironment.port)). Token trafia tylko do pęku kluczy.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = tunnel.tokenError {
            Text(error)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
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
        LabeledContent("Stan tunelu") {
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
        if !tunnel.recentLog.isEmpty {
            DisclosureGroup("Log tunelu", isExpanded: $showsLog) {
                // Tekst logu składany tylko po rozwinięciu — zwinięta grupa nie przelicza go przy każdym wpisie.
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
