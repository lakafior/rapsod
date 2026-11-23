import SwiftUI

/// Wiersze strony „Dostęp zdalny”: sieć domowa (przełącznik i adresy) i dostęp spoza domu
/// (własny adres albo Cloudflare Tunnel). Nazwa i hasło do innych aplikacji są od etapu 2
/// w profilu osoby („Dane logowania…”).
struct ConnectPhoneSection: View {
    let sharing: SharingController
    let supervisor: ServerSupervisor
    let account: ServerAccount

    @State private var externalURL = ""

    private var canEnable: Bool {
        guard account.state == .ready, case .ready = account.userState else { return false }
        return true
    }

    /// Serwer faktycznie słucha w sieci lokalnej (a nie tylko ma to w ustawieniach).
    private var isReachable: Bool {
        supervisor.state == .running && supervisor.environment?.listensOnLAN == true
    }

    var body: some View {
        Toggle("Udostępniaj serwer w sieci domowej", isOn: Binding(
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
                CopyableRow(title: index == 0 ? "Adres w sieci domowej" : "", value: url.absoluteString)
            }
            if sharing.localURLs.isEmpty {
                LabeledContent("Adres w sieci domowej", value: "brak połączenia z siecią")
            }
        }
        if let external = sharing.externalURL {
            CopyableRow(title: "Adres spoza domu", value: external.absoluteString)
        }

        Picker("Dostęp spoza domu", selection: Binding(
            get: { sharing.externalAccess },
            set: { sharing.setExternalAccess($0) }
        )) {
            Text("Brak").tag(ExternalAccessMode.none)
            Text("Własny adres").tag(ExternalAccessMode.custom)
            Text("Cloudflare Tunnel").tag(ExternalAccessMode.cloudflareTunnel)
        }

        switch sharing.externalAccess {
        case .none:
            Text("Serwer jest dostępny tylko z tego Maca\(sharing.isEnabled ? " i z sieci domowej" : ""). Dostęp spoza domu jest opcjonalny: własny adres (np. Tailscale, własny tunel lub VPN) albo Cloudflare Tunnel zestawiany przez aplikację.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .custom:
            LabeledContent("Własny adres") {
                HStack {
                    TextField("Własny adres", text: $externalURL, prompt: Text("np. https://ksiazki.example.com"))
                        .labelsHidden()
                        .onSubmit { sharing.setExternalURL(externalURL) }
                    Button("Zapisz") { sharing.setExternalURL(externalURL) }
                        .disabled(externalURL.trimmingCharacters(in: .whitespaces) == sharing.settings.externalURL)
                }
            }
            .onAppear { externalURL = sharing.settings.externalURL }
            Text("Aplikacja niczego pod tym adresem nie zestawia — to adres Twojego tunelu albo VPN (np. Tailscale). Trafia do kodów telefonów i do danych logowania w profilach osób.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .cloudflareTunnel:
            CloudflareTunnelSection(tunnel: sharing.tunnel, phonePassword: account.phoneCredentials?.password)
        }

        if let error = sharing.lastError {
            Text(error)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var explanation: String {
        if sharing.isEnabled {
            "Aplikację AudiobookSwift na telefonie podłączysz kodem QR w profilu osoby (Ustawienia → Użytkownicy); tam są też dane logowania (adres, nazwa, hasło) do innych aplikacji audiobookshelf (np. oficjalnej, Plappa, ShelfPlayer). Ruch w sieci domowej idzie zwykłym HTTP: hasło i treść są widoczne dla innych urządzeń w tej samej sieci. Wyłączenie przywraca nasłuch tylko na tym Macu."
        } else if canEnable {
            "Teraz serwer jest dostępny tylko z tego Maca. Po włączeniu zacznie słuchać w sieci domowej po zwykłym HTTP (wymaga restartu serwera), a telefon połączy się aplikacją AudiobookSwift albo dowolnym klientem audiobookshelf."
        } else {
            "Sieć domowa wymaga działającego serwera i konta tego Maca (Ustawienia → Użytkownicy)."
        }
    }
}

/// Wiersz z wartością do przepisania i przyciskiem kopiowania.
struct CopyableRow<Accessory: View>: View {
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
                Button("Kopiuj") { NSPasteboard.copy(value) }
            }
        }
    }
}
