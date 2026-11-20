import SwiftUI

/// Wiersze sekcji „Połącz telefon” w oknie statusu: wszystko, co trzeba przepisać
/// do dowolnego klienta audiobookshelf (adres, nazwa użytkownika, hasło).
struct ConnectPhoneSection: View {
    let sharing: SharingController
    let supervisor: ServerSupervisor
    let account: ServerAccount

    @State private var externalURL = ""
    @State private var showsPassword = false

    private var canEnable: Bool {
        guard account.state == .ready, case .ready = account.userState else { return false }
        return true
    }

    /// Serwer faktycznie słucha w sieci lokalnej (a nie tylko ma to w ustawieniach).
    private var isReachable: Bool {
        supervisor.state == .running && supervisor.environment?.listensOnLAN == true
    }

    var body: some View {
        Toggle("Udostępniaj serwer w sieci lokalnej", isOn: Binding(
            get: { sharing.isEnabled },
            set: { enabled in Task { await sharing.setEnabled(enabled) } }
        ))
        .disabled(sharing.isBusy || (!sharing.isEnabled && !canEnable))

        Text(explanation)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if isReachable {
            ForEach(Array(sharing.localURLs.enumerated()), id: \.element) { index, url in
                CopyableRow(title: index == 0 ? "Adres w sieci lokalnej" : "", value: url.absoluteString)
            }
            if sharing.localURLs.isEmpty {
                LabeledContent("Adres w sieci lokalnej", value: "brak połączenia z siecią")
            }
        }
        if let external = sharing.externalURL {
            CopyableRow(title: "Adres zewnętrzny", value: external.absoluteString)
        }
        if let credentials = account.phoneCredentials {
            CopyableRow(title: "Nazwa użytkownika", value: credentials.username)
            CopyableRow(
                title: "Hasło",
                value: credentials.password,
                shown: showsPassword ? credentials.password : String(repeating: "•", count: 12)
            ) {
                Button(showsPassword ? "Ukryj" : "Pokaż") { showsPassword.toggle() }
            }
        }

        LabeledContent("Własny adres zewnętrzny") {
            HStack {
                TextField("Własny adres zewnętrzny", text: $externalURL, prompt: Text("opcjonalnie, np. https://ksiazki.example.com/audiobookshelf"))
                    .labelsHidden()
                    .onSubmit { sharing.setExternalURL(externalURL) }
                Button("Zapisz") { sharing.setExternalURL(externalURL) }
                    .disabled(externalURL.trimmingCharacters(in: .whitespaces) == sharing.settings.externalURL)
            }
        }
        .onAppear { externalURL = sharing.settings.externalURL }
        Text("Dostęp spoza domu jest opcjonalny i aplikacja go nie zestawia. Jeśli masz własny tunel lub VPN (np. Tailscale, Cloudflare Tunnel), wpisz tu jego adres, żeby mieć go pod ręką razem z danymi logowania.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if let error = sharing.lastError {
            Text(error)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var explanation: String {
        if sharing.isEnabled {
            "W aplikacji audiobookshelf na telefonie (np. oficjalnej, Plappa, ShelfPlayer) podaj adres serwera oraz nazwę i hasło poniżej. Ruch w sieci lokalnej idzie zwykłym HTTP: hasło i treść są widoczne dla innych urządzeń w tej samej sieci. Wyłączenie przywraca nasłuch tylko na tym Macu."
        } else if canEnable {
            "Teraz serwer jest dostępny tylko z tego Maca. Po włączeniu zacznie słuchać w sieci lokalnej po zwykłym HTTP (wymaga restartu serwera), a telefon połączy się dowolnym klientem audiobookshelf."
        } else {
            "Udostępnianie wymaga działającego serwera i konta użytkownika."
        }
    }
}

/// Wiersz z wartością do przepisania i przyciskiem kopiowania.
private struct CopyableRow<Accessory: View>: View {
    let title: String
    let value: String
    var shown: String?
    @ViewBuilder var accessory: Accessory

    init(title: String, value: String, shown: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.value = value
        self.shown = shown
        self.accessory = accessory()
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(shown ?? value)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                accessory
                Button("Kopiuj") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
            }
        }
    }
}
