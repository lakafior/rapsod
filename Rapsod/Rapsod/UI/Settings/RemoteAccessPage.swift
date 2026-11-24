import AudiobookshelfKit
import SwiftUI

/// Strona „Dostęp zdalny” (etap 3 planu): odpowiedź na pytanie „skąd można słuchać”, baner
/// o adresach na telefonach, sieć domowa, dostęp spoza domu i — pod „Zaawansowane” — logowanie
/// (SSO), klucze API, publiczne kanały RSS i log tunelu (dawne strony „Dostęp” i część „Aktywności”).
struct RemoteAccessPage: View {
    let models: AppModels
    @Environment(SettingsNavigation.self) private var navigation
    @State private var addressesCode: AddressesCode?
    @State private var externalURL = ""
    @State private var showsAdvanced = false
    // Modele „Zaawansowane” powstają dopiero po rozwinięciu (nie ładujemy kluczy, SSO i kanałów na zapas).
    @State private var apiKeysModel: ApiKeysModel?
    @State private var authModel: AuthSettingsModel?
    @State private var feedsModel: FeedsModel?

    private var sharing: SharingController { models.sharing }
    private var pairing: PhonePairing { models.pairing }
    private var account: ServerAccount { models.account }
    private var tunnel: CloudflareTunnel { sharing.tunnel }

    /// Serwer faktycznie słucha w sieci domowej (a nie tylko ma to w ustawieniach).
    private var listensAtHome: Bool {
        models.supervisor.state == .running && models.supervisor.environment?.listensOnLAN == true
    }

    private var canEnableHome: Bool {
        guard account.state == .ready, case .ready = account.userState else { return false }
        return true
    }

    var body: some View {
        SettingsForm {
            reachability
            if pairing.devices.count > 0, sharing.phonesMayLackRemoteAddress {
                Section {
                    ActionBanner(
                        text: "Adres spoza domu zmienił się od ostatniego kodu — telefony (\(pairing.devices.count)) mogą go jeszcze nie znać.",
                        systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                        actionTitle: "Pokaż kod z adresami…"
                    ) { showAddressesCode() }
                }
            }
            // Błąd sieci domowej albo adresu spoza domu — jedno miejsce nad oboma sekcjami.
            if let error = sharing.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            homeNetwork
            outsideHome
            phones
            advanced
        }
        .sheet(item: $addressesCode) { AddressesCodeSheet(url: $0.url) }
        .task(id: account.state) {
            guard account.state == .ready else { return }
            await pairing.refresh()
            if !pairing.devices.isEmpty { sharing.establishPhoneAddressBaseline() }
        }
        .onChange(of: sharing.currentRemoteAddresses) {
            if !pairing.devices.isEmpty { sharing.establishPhoneAddressBaseline() }
        }
        .task(id: AdvancedLoad(expanded: showsAdvanced, state: account.state)) {
            guard showsAdvanced, account.state == .ready else { return }
            let keys = apiKeysModel ?? ApiKeysModel(account: account)
            let auth = authModel ?? AuthSettingsModel(account: account)
            let feeds = feedsModel ?? FeedsModel(account: account)
            apiKeysModel = keys
            authModel = auth
            feedsModel = feeds
            await auth.load()
            await keys.load()
            await feeds.load()
        }
        .onAppear(perform: consumePendingAdvanced)
        .onChange(of: navigation.pendingAdvanced) { consumePendingAdvanced() }
    }

    private struct AdvancedLoad: Equatable {
        let expanded: Bool
        let state: ServerAccount.State
    }

    private func consumePendingAdvanced() {
        guard navigation.pendingAdvanced == .sharing else { return }
        navigation.pendingAdvanced = nil
        showsAdvanced = true
    }

    private func showAddressesCode() {
        addressesCode = pairing.addressesCode().map(AddressesCode.init)
    }

    // MARK: Skąd można słuchać

    private var reachability: some View {
        Section("Skąd można słuchać") {
            ReachRow(symbol: "laptopcomputer", title: "Ten Mac", detail: "zawsze", isOn: models.supervisor.state == .running)
            ReachRow(
                symbol: "wifi",
                title: "Sieć domowa",
                detail: homeDetail,
                isOn: sharing.isEnabled && listensAtHome
            )
            ReachRow(symbol: "globe", title: "Spoza domu", detail: outsideDetail, isOn: sharing.externalURL != nil && outsideWorks)
        }
    }

    private var homeDetail: String {
        guard sharing.isEnabled else { return "wyłączona" }
        guard listensAtHome else { return "włączona — czeka na serwer" }
        guard let first = sharing.localURLs.first?.host() else { return "brak połączenia z siecią" }
        return "\(first) · telefony znajdą Maca same (Bonjour)"
    }

    private var outsideWorks: Bool {
        switch sharing.externalAccess {
        case .none: false
        case .custom: true
        case .cloudflareTunnel: tunnel.state == .connected
        }
    }

    private var outsideDetail: String {
        switch sharing.externalAccess {
        case .none: return "wyłączony"
        case .custom: return sharing.externalURL.flatMap { $0.host() }.map { "własny adres · \($0)" } ?? "własny adres — brak adresu"
        case .cloudflareTunnel:
            if let host = tunnel.publicURL?.host() { return "Cloudflare Tunnel · \(host) · \(tunnel.state.title.lowercased())" }
            return "Cloudflare Tunnel · \(tunnel.state.title.lowercased())"
        }
    }

    // MARK: Sieć domowa

    private var homeNetwork: some View {
        Section {
            Toggle("Udostępniaj w sieci domowej", isOn: Binding(
                get: { sharing.isEnabled },
                set: { enabled in Task { await sharing.setEnabled(enabled) } }
            ))
            .disabled(sharing.isBusy || (!sharing.isEnabled && !canEnableHome))
            if sharing.isEnabled, listensAtHome {
                ForEach(Array(sharing.localURLs.enumerated()), id: \.element) { index, url in
                    CopyableRow(title: index == 0 ? "Adres" : "", value: url.absoluteString)
                }
                if sharing.localURLs.isEmpty {
                    LabeledContent("Adres", value: "brak połączenia z siecią")
                }
            }
            if sharing.isBusy {
                ProgressView("Ponowne uruchamianie serwera…").controlSize(.small)
            }
        } header: {
            Text("Sieć domowa")
        } footer: {
            Text(homeFooter)
        }
    }

    private var homeFooter: String {
        if sharing.isEnabled {
            "W sieci domowej ruch idzie zwykłym HTTP: hasła i treść są widoczne dla innych urządzeń w tej samej sieci. Wyłączenie zostawia serwer tylko dla tego Maca (wymaga restartu serwera)."
        } else if canEnableHome {
            "Teraz serwer jest dostępny tylko z tego Maca. Po włączeniu zacznie słuchać w sieci domowej po zwykłym HTTP (wymaga restartu serwera)."
        } else {
            "Sieć domowa wymaga działającego serwera i konta tego Maca (Ustawienia → Użytkownicy)."
        }
    }

    // MARK: Spoza domu

    private var outsideHome: some View {
        Section {
            Picker("Sposób", selection: Binding(
                get: { sharing.externalAccess },
                set: { sharing.setExternalAccess($0) }
            )) {
                Text("Wyłączony").tag(ExternalAccessMode.none)
                Text("Własny adres").tag(ExternalAccessMode.custom)
                Text("Cloudflare Tunnel").tag(ExternalAccessMode.cloudflareTunnel)
            }
            .pickerStyle(.segmented)
            switch sharing.externalAccess {
            case .none:
                EmptyView()
            case .custom:
                // Jedno pole: „Zapisz” przy zmianie, „Kopiuj” zapisanego adresu (bez drugiego wiersza z tym samym adresem).
                LabeledContent("Adres") {
                    HStack {
                        TextField("Własny adres", text: $externalURL, prompt: Text("np. https://ksiazki.example.com"))
                            .labelsHidden()
                            .onSubmit { sharing.setExternalURL(externalURL) }
                        if externalChanged {
                            Button("Zapisz") { sharing.setExternalURL(externalURL) }
                        } else if let url = sharing.externalURL {
                            Button("Kopiuj") { NSPasteboard.copy(url.absoluteString) }
                                .help("Kopiuj adres \(url.absoluteString)")
                        }
                    }
                }
                .onAppear { externalURL = sharing.settings.externalURL }
            case .cloudflareTunnel:
                CloudflareTunnelSection(tunnel: tunnel)
            }
        } header: {
            Text("Spoza domu")
        } footer: {
            Text(outsideFooter)
        }
    }

    private var externalChanged: Bool {
        externalURL.trimmingCharacters(in: .whitespaces) != sharing.settings.externalURL
    }

    private var outsideFooter: String {
        switch sharing.externalAccess {
        case .none:
            "Opcjonalnie: własny adres (np. Tailscale, własny tunel lub VPN) albo Cloudflare Tunnel zestawiany przez aplikację."
        case .custom:
            "Aplikacja niczego pod tym adresem nie zestawia — to adres Twojego tunelu albo VPN. Trafia do kodów telefonów i do danych logowania w profilach osób."
        case .cloudflareTunnel:
            "Tunel zestawia aplikacja; inne tunele i VPN-y na tym Macu zostają nietknięte. Przez tunel serwer jest dostępny z całego internetu — konta powinny mieć długie hasła. Darmowy plan Cloudflare zastrzega, że „nieproporcjonalnie dużo” plików audio wymaga płatnych usług, więc Cloudflare może ograniczyć ten adres (szczegóły w README)."
                + (weakMacPassword ? " Hasło konta tego Maca jest krótkie — zmień je na dłuższe w jego profilu." : "")
        }
    }

    private var weakMacPassword: Bool {
        (account.listenerPassword?.count ?? 16) < 16
    }

    // MARK: Telefony

    private var phones: some View {
        Section {
            LabeledContent("Adresy na telefonach") {
                Button("Kod z adresami…", action: showAddressesCode)
                    .disabled(pairing.devices.isEmpty || pairing.addresses.isEmpty)
            }
            LabeledContent("Podłączone telefony", value: pairing.devices.isEmpty ? "brak" : PhoneCount.text(pairing.devices.count))
            LabeledContent("Podłączanie telefonów") {
                Button("Użytkownicy…") { navigation.page = .users }
            }
        } header: {
            Text("Aplikacja Rapsod na telefonie")
        } footer: {
            Text("Telefon podłączasz kodem QR w profilu osoby. „Kod z adresami” (ten sam co w profilach) aktualizuje adresy na telefonach wszystkich osób bez ponownego podłączania. Zmieniony adres w sieci domowej telefon znajduje też sam (Bonjour).")
        }
    }

    // MARK: Zaawansowane

    @ViewBuilder
    private var advanced: some View {
        AdvancedHeader(summary: "Logowanie SSO, klucze API, publiczne kanały RSS, log tunelu", isExpanded: $showsAdvanced)
        if showsAdvanced {
            if account.state != .ready {
                Section { AdminUnavailableRow(account: account) }
            } else {
                if let authModel { LoginSummaryRows(model: authModel) }
                if let apiKeysModel { ApiKeysContent(model: apiKeysModel, pairing: pairing) }
                if let feedsModel { FeedsContent(model: feedsModel) }
            }
            Section("Tunel Cloudflare") {
                CloudflareTunnelLogRows(tunnel: tunnel)
            }
        }
    }
}

/// Wiersz podsumowania „Skąd można słuchać”.
private struct ReachRow: View {
    let symbol: String
    let title: String
    let detail: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: isOn ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(isOn ? .green : .secondary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOn ? "działa" : "nie działa")
    }
}
