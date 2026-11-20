import CloudKit
import Foundation
import Network
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Pairing")

/// Strona Maca w parowaniu z klientem iOS: przełącznik udostępniania w sieci lokalnej,
/// rekord w prywatnej bazie CloudKit i ogłaszanie przez Bonjour.
///
/// Włączenie parowania restartuje serwer z nasłuchem w sieci lokalnej; gdy konto jest
/// gotowe, kontroler wydaje klucz API, ogłasza usługę i zapisuje rekord. Rekord jest
/// zapisywany ponownie, gdy zmienią się adresy, token albo adres zewnętrzny, a przy
/// wyłączeniu parowania usuwany razem z kluczem API.
@MainActor
@Observable
final class PairingController {
    enum CloudState: Equatable {
        case checking
        case available
        case noAccount
        case restricted
        case temporarilyUnavailable
        case failed(String)
    }

    enum RecordState: Equatable {
        case notSaved
        case saving
        case saved(Date)
        case failed(String)
    }

    private(set) var settings = PairingSettings()
    private(set) var cloudState: CloudState = .checking
    private(set) var recordState: RecordState = .notSaved
    private(set) var bonjourStatus: BonjourAdvertiser.Status = .stopped
    /// Ostatnio zbudowany rekord (adresy, pod którymi serwer jest widoczny).
    private(set) var record: PairingRecord?
    /// Trwa włączanie, wyłączanie albo unieważnianie tokenu.
    private(set) var isBusy = false
    private(set) var lastError: String?

    var isEnabled: Bool { settings.isEnabled }

    @ObservationIgnored private let supervisor: ServerSupervisor
    @ObservationIgnored private let account: ServerAccount
    @ObservationIgnored private let cloud = PairingCloudStore()
    @ObservationIgnored private let bonjour = BonjourAdvertiser()
    @ObservationIgnored private var settingsURL: URL?
    @ObservationIgnored private var savedRecord: PairingRecord?
    @ObservationIgnored private var isPublishing = false
    @ObservationIgnored private var publishAgain = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var networkDebounce: Task<Void, Never>?
    @ObservationIgnored private var accountObserver: (any NSObjectProtocol)?

    init(supervisor: ServerSupervisor, account: ServerAccount) {
        self.supervisor = supervisor
        self.account = account
        if let dataRoot = try? ServerEnvironment.resolveDataRoot() {
            let url = ServerEnvironment.pairingSettingsURL(dataRoot: dataRoot)
            settingsURL = url
            settings = PairingSettings.load(from: url)
        }
        bonjour.onStatusChange = { [weak self] in self?.bonjourStatus = $0 }
    }

    /// Wywoływane raz przy starcie aplikacji.
    func activate() {
        // Identyfikator serwera ma być trwały od pierwszego uruchomienia.
        saveSettings()
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    await self.refreshCloudState()
                    self.schedulePublish()
                    await self.cleanUpIfNeeded()
                }
            }
        }
        Task { await refreshCloudState() }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.networkDidChange() }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    // MARK: - Zdarzenia serwera

    /// Serwer działa i konto aplikacji jest połączone.
    func serverDidConnect() {
        schedulePublish()
        Task { await cleanUpIfNeeded() }
    }

    func serverDidStop() {
        bonjour.stop()
        record = nil
    }

    // MARK: - Akcje użytkownika

    func setEnabled(_ enabled: Bool) async {
        guard enabled != settings.isEnabled, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil

        if enabled {
            guard account.state == .ready, case .ready = account.userState else {
                lastError = "Parowanie wymaga działającego serwera i konta użytkownika."
                return
            }
            settings.isEnabled = true
            saveSettings()
        } else {
            settings.isEnabled = false
            saveSettings()
            bonjour.stop()
            record = nil
            settings.needsCleanup = true
            await cleanUpIfNeeded()
            if settings.needsCleanup {
                lastError = "Nie udało się jeszcze usunąć tokenu albo rekordu z iCloud — aplikacja ponowi próbę po połączeniu z serwerem i iCloud."
            }
        }
        // `HOST` serwer czyta przy starcie, więc zmiana nasłuchu wymaga restartu.
        // Po starcie `serverDidConnect()` opublikuje rekord (gdy parowanie jest włączone).
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
        guard text != settings.externalURL else { return true }
        settings.externalURL = text
        saveSettings()
        schedulePublish()
        return true
    }

    /// Unieważnia token klienta iOS; przy włączonym parowaniu od razu wydaje nowy i zapisuje rekord.
    func revokeToken() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await account.revokePairingKey()
            lastError = nil
        } catch {
            lastError = "Nie udało się unieważnić tokenu: \(error.localizedDescription)"
            return
        }
        savedRecord = nil
        schedulePublish()
    }

    // MARK: - iCloud

    private func refreshCloudState() async {
        do {
            cloudState = switch try await cloud.accountStatus() {
            case .available: .available
            case .noAccount: .noAccount
            case .restricted: .restricted
            case .temporarilyUnavailable: .temporarilyUnavailable
            case .couldNotDetermine: .failed("Nie udało się ustalić stanu konta iCloud.")
            @unknown default: .failed("Nieznany stan konta iCloud.")
            }
        } catch {
            cloudState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Publikacja

    private func networkDidChange() {
        networkDebounce?.cancel()
        networkDebounce = Task { [weak self] in
            // Zmiana sieci przychodzi serią zdarzeń; adresy ustalają się po chwili.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.schedulePublish()
        }
    }

    /// Publikacje idą jedna po drugiej; prośba w trakcie oznacza jeszcze jeden przebieg.
    private func schedulePublish() {
        if isPublishing {
            publishAgain = true
            return
        }
        isPublishing = true
        Task {
            repeat {
                publishAgain = false
                await publish()
            } while publishAgain
            isPublishing = false
        }
    }

    private func publish() async {
        guard settings.isEnabled, supervisor.state == .running, account.state == .ready,
              let environment = supervisor.environment, environment.listensOnLAN,
              case .ready(let username) = account.userState else { return }

        let key: AudiobookshelfClient.APIKey
        do {
            key = try await account.pairingKey()
        } catch {
            logger.error("Klucz API: \(error.localizedDescription, privacy: .public)")
            recordState = .failed("Nie udało się wydać tokenu: \(error.localizedDescription)")
            return
        }

        let record = PairingRecord(
            serverID: settings.serverID,
            name: LocalNetwork.computerName,
            localHostName: LocalNetwork.localHostName ?? "",
            addresses: LocalNetwork.ipv4Addresses(),
            port: ServerEnvironment.port,
            basePath: ServerEnvironment.routerBasePath,
            serverVersion: environment.serverVersion ?? "",
            username: username,
            externalURL: settings.externalURL,
            token: key.token,
            updatedAt: .now
        )
        self.record = record
        bonjour.start(serverID: record.serverID, port: record.port, basePath: record.basePath)

        await refreshCloudState()
        guard cloudState == .available else {
            recordState = .notSaved
            savedRecord = nil
            return
        }
        if let savedRecord, savedRecord.hasSameContent(as: record), case .saved = recordState { return }

        recordState = .saving
        do {
            try await cloud.save(record)
            savedRecord = record
            recordState = .saved(record.updatedAt)
            logger.notice("Zapisano rekord parowania w iCloud")
        } catch {
            logger.error("Zapis rekordu parowania: \(error.localizedDescription, privacy: .public)")
            savedRecord = nil
            recordState = .failed(error.localizedDescription)
        }
    }

    /// Po wyłączeniu parowania usuwa klucz API i rekord; nieudane kroki zostają do ponowienia.
    private func cleanUpIfNeeded() async {
        guard !settings.isEnabled, settings.needsCleanup else { return }
        var done = true
        if account.state == .ready {
            do {
                try await account.revokePairingKey()
            } catch {
                logger.error("Unieważnianie klucza API: \(error.localizedDescription, privacy: .public)")
                done = false
            }
        } else {
            done = false
        }
        savedRecord = nil
        do {
            try await cloud.delete(serverID: settings.serverID)
            recordState = .notSaved
            logger.notice("Usunięto rekord parowania z iCloud")
        } catch {
            logger.error("Usuwanie rekordu parowania: \(error.localizedDescription, privacy: .public)")
            recordState = .failed("Nie udało się usunąć rekordu z iCloud: \(error.localizedDescription)")
            done = false
        }
        // Ustawienia mogły się zmienić w trakcie (ponowne włączenie parowania).
        if done, !settings.isEnabled {
            settings.needsCleanup = false
            saveSettings()
        }
    }

    private func saveSettings() {
        guard let settingsURL else { return }
        do {
            try settings.save(to: settingsURL)
        } catch {
            lastError = "Nie udało się zapisać ustawień parowania: \(error.localizedDescription)"
        }
    }
}
