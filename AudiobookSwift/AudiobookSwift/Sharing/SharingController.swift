import Foundation
import Network
import Observation

/// Udostępnianie serwera w sieci lokalnej: przełącznik nasłuchu, adresy do wpisania
/// w kliencie audiobookshelf na telefonie i opcjonalny adres zewnętrzny.
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
    var externalURL: URL? { settings.externalURL.isEmpty ? nil : URL(string: settings.externalURL) }

    @ObservationIgnored private let supervisor: ServerSupervisor
    @ObservationIgnored private let account: ServerAccount
    @ObservationIgnored private var settingsURL: URL?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var networkDebounce: Task<Void, Never>?

    init(supervisor: ServerSupervisor, account: ServerAccount) {
        self.supervisor = supervisor
        self.account = account
        if let dataRoot = try? ServerEnvironment.resolveDataRoot() {
            let url = ServerEnvironment.sharingSettingsURL(dataRoot: dataRoot)
            settingsURL = url
            settings = SharingSettings.load(from: url)
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
        localURLs = hosts.compactMap {
            URL(string: "http://\($0):\(ServerEnvironment.port)\(ServerEnvironment.routerBasePath)")
        }
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
