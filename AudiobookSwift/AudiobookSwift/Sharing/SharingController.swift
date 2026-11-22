import Foundation
import Network
import Observation

/// Udostępnianie serwera: przełącznik nasłuchu w sieci lokalnej, adresy do wpisania
/// w kliencie audiobookshelf na telefonie i opcjonalny dostęp spoza domu.
///
/// Dostęp spoza domu to jeden „adres zewnętrzny” (`externalURL`): wpisany ręcznie
/// (Tailscale, własny tunel) albo pochodzący z tunelu Cloudflare (`Tunnel/`), który
/// ten kontroler tylko włącza i wyłącza. Tunel jest niezależny od sieci lokalnej.
///
/// Telefon łączy się dowolnym istniejącym klientem audiobookshelf, podając adres
/// oraz nazwę i hasło konta użytkownika — aplikacja niczego nie ogłasza ani nie wysyła.
@MainActor
@Observable
final class SharingController {
    private(set) var settings = SharingSettings()
    /// Adresy serwera w sieci lokalnej (nazwa `.local`, potem adresy IPv4).
    private(set) var localURLs: [URL] = []
    /// Trwa restart serwera po zmianie przełącznika.
    private(set) var isBusy = false
    private(set) var lastError: String?

    var isEnabled: Bool { settings.isEnabled }
    var externalAccess: ExternalAccessMode { settings.externalAccess }
    /// Opcjonalny tunel Cloudflare (działa tylko w trybie `.cloudflareTunnel`).
    let tunnel = CloudflareTunnel()

    /// Jedyne źródło adresu spoza domu dla sekcji „Połącz telefon”.
    var externalURL: URL? {
        switch settings.externalAccess {
        case .none: nil
        case .custom: settings.externalURL.isEmpty ? nil : URL(string: settings.externalURL)
        case .cloudflareTunnel: tunnel.publicURL
        }
    }

    /// Serwer działa i ma konto root — dopiero wtedy wolno go wystawić poza ten Mac
    /// (niezainicjalizowany serwer pozwala każdemu założyć roota).
    private var serverIsReady: Bool { supervisor.state == .running && account.state == .ready }

    @ObservationIgnored private let supervisor: ServerSupervisor
    @ObservationIgnored private let account: ServerAccount
    @ObservationIgnored private var settingsURL: URL?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var networkDebounce: Task<Void, Never>?
    @ObservationIgnored private var tunnelObservation: Task<Void, Never>?

    init(supervisor: ServerSupervisor, account: ServerAccount) {
        self.supervisor = supervisor
        self.account = account
        if let dataRoot = try? ServerEnvironment.resolveDataRoot() {
            let url = ServerEnvironment.sharingSettingsURL(dataRoot: dataRoot)
            settingsURL = url
            settings = SharingSettings.load(from: url)
            tunnel.load(dataRoot: dataRoot)
        }
    }

    /// Wywoływane raz przy starcie aplikacji: śledzi zmiany sieci, żeby adresy były aktualne.
    func activate() {
        refreshAddresses()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.networkDidChange() }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor

        // Tunel startuje i zatrzymuje się razem z wyborem w ustawieniach i ze stanem serwera.
        tunnelObservation = Task { [weak self] in
            let inputs = Observations { [weak self] in
                self.map { TunnelInputs(selected: $0.settings.externalAccess == .cloudflareTunnel, serverReady: $0.serverIsReady) }
            }
            for await input in inputs {
                guard let self, let input else { return }
                await tunnel.update(selected: input.selected, serverReady: input.serverReady)
            }
        }
    }

    /// Działa proces dostępu spoza domu, który trzeba zatrzymać przed wyjściem.
    var hasRunningExternalAccess: Bool { tunnel.isRunning }

    /// Zatrzymuje tunel przed zakończeniem aplikacji.
    func shutdown() async {
        tunnelObservation?.cancel()
        await tunnel.stop()
    }

    func setExternalAccess(_ mode: ExternalAccessMode) {
        guard mode != settings.externalAccess else { return }
        if mode == .cloudflareTunnel {
            guard account.state == .ready, case .ready = account.userState else {
                lastError = "Dostęp spoza domu wymaga działającego serwera i konta użytkownika."
                return
            }
        }
        lastError = nil
        settings.externalAccess = mode
        saveSettings()
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != settings.isEnabled, !isBusy else { return }
        if enabled {
            // Niezainicjalizowany serwer pozwala każdemu w sieci założyć konto root.
            guard account.state == .ready, case .ready = account.userState else {
                lastError = "Udostępnianie wymaga działającego serwera i konta użytkownika."
                return
            }
        }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        settings.isEnabled = enabled
        saveSettings()
        refreshAddresses()
        // `HOST` serwer czyta przy starcie, więc zmiana nasłuchu wymaga restartu.
        await supervisor.restart()
    }

    /// Zapisuje adres zewnętrzny (pusty tekst go usuwa). Zwraca `false`, gdy adres jest nieprawidłowy.
    @discardableResult
    func setExternalURL(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host() != nil else {
                lastError = "Adres zewnętrzny musi być pełnym adresem http(s), np. https://ksiazki.example.com/audiobookshelf."
                return false
            }
        }
        lastError = nil
        settings.externalURL = text
        saveSettings()
        return true
    }

    /// Identyfikator serwera do kodów parowania; przy pierwszym użyciu nadaje go i zapisuje.
    func ensureServerID() -> String {
        if let id = settings.serverID { return id }
        let id = UUID().uuidString.lowercased()
        settings.serverID = id
        saveSettings()
        return id
    }

    private func networkDidChange() {
        networkDebounce?.cancel()
        networkDebounce = Task { [weak self] in
            // Zmiana sieci przychodzi serią zdarzeń; adresy ustalają się po chwili.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.refreshAddresses()
        }
    }

    private func refreshAddresses() {
        let hosts = (LocalNetwork.localHostName.map { [$0] } ?? []) + LocalNetwork.ipv4Addresses()
        // Bez ścieżki bazowej: upstream sam dopisuje `ROUTER_BASE_PATH` do żądań, które jej
        // nie mają (`server/Server.js`), więc krótszy adres działa w każdym kliencie —
        // także takim, który obcina ścieżkę z adresu serwera.
        localURLs = hosts.compactMap { URL(string: "http://\($0):\(ServerEnvironment.port)") }
    }

    private func saveSettings() {
        guard let settingsURL else { return }
        do {
            try settings.save(to: settingsURL)
        } catch {
            lastError = "Nie udało się zapisać ustawień udostępniania: \(error.localizedDescription)"
        }
    }
}

private struct TunnelInputs: Sendable, Equatable {
    let selected: Bool
    let serverReady: Bool
}
