import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Account")

/// Konto aplikacji na serwerze: zakłada roota na czystym serwerze, loguje się
/// i zarządza bibliotekami przez `AudiobookshelfClient`.
///
/// Root jest zakładany automatycznie z losowym hasłem w pęku kluczy (decyzja z etapu 2),
/// żeby wybór folderu działał bez formularzy, okno web UI logowało się samo, a etap 3
/// mógł wydać token klientowi iOS.
@MainActor
@Observable
final class ServerAccount {
    enum State: Equatable {
        case disconnected
        case connecting
        case ready
        /// Serwer ma roota, ale nie znamy (właściwego) hasła — trzeba je podać.
        case needsPassword(String)
        case failed(String)
    }

    enum ScanPhase: Equatable {
        case creating
        case scanning
        case finished(items: Int)
        case failed(String)
    }

    struct ScanProgress: Equatable {
        let folder: URL
        var phase: ScanPhase
    }

    private(set) var state: State = .disconnected
    private(set) var libraries: [AudiobookshelfClient.Library] = []
    private(set) var username: String?
    private(set) var scan: ScanProgress?

    var isScanning: Bool {
        switch scan?.phase {
        case .creating, .scanning: true
        default: false
        }
    }

    @ObservationIgnored private var client = AudiobookshelfClient(baseURL: ServerEnvironment.baseURL)
    @ObservationIgnored private var store: CredentialStore?
    @ObservationIgnored private var credentials: AudiobookshelfClient.Credentials?
    @ObservationIgnored private var accessToken: String?
    /// Rośnie przy każdym połączeniu/rozłączeniu, żeby spóźnione odpowiedzi nie nadpisały stanu.
    @ObservationIgnored private var generation = 0

    // MARK: - Połączenie

    /// Wywoływane, gdy serwer zaczął odpowiadać.
    func connect(environment: ServerEnvironment) async {
        generation += 1
        let generation = generation
        client = AudiobookshelfClient(baseURL: ServerEnvironment.baseURL)
        store = CredentialStore(service: ServerEnvironment.keychainService, account: environment.keychainAccount)
        accessToken = nil
        state = .connecting

        do {
            let credentials = try await ensureRootAccount()
            guard generation == self.generation else { return }
            let login = try await client.login(credentials)
            guard generation == self.generation else { return }
            self.credentials = credentials
            accessToken = login.accessToken
            username = login.username
            state = .ready
            try await refreshLibraries()
        } catch AudiobookshelfClient.APIError.unauthorized {
            guard generation == self.generation else { return }
            state = .needsPassword("Hasło konta root zapisane w pęku kluczy nie pasuje — podaj aktualne.")
        } catch let error as NeedsPassword {
            guard generation == self.generation else { return }
            state = .needsPassword(error.reason)
        } catch {
            guard generation == self.generation else { return }
            logger.error("Połączenie z serwerem: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Wywoływane, gdy serwer przestał działać.
    func disconnect() {
        generation += 1
        accessToken = nil
        credentials = nil
        state = .disconnected
    }

    /// Dane logowania podane ręcznie (gdy w pęku kluczy brakuje hasła albo jest nieaktualne).
    func submit(username: String, password: String) async throws {
        guard let store else { return }
        let credentials = AudiobookshelfClient.Credentials(username: username, password: password)
        let login = try await client.login(credentials)
        try store.save(credentials)
        self.credentials = credentials
        accessToken = login.accessToken
        self.username = login.username
        state = .ready
        try await refreshLibraries()
    }

    private struct NeedsPassword: Error {
        let reason: String
    }

    /// Zwraca dane roota; na czystym serwerze najpierw je tworzy.
    private func ensureRootAccount() async throws -> AudiobookshelfClient.Credentials {
        guard let store else { throw AudiobookshelfClient.APIError.invalidResponse }
        let status = try await client.status()
        // Błąd odczytu (np. odmowa dostępu do pęku kluczy) leci dalej — to nie jest „brak konta”.
        let stored = try store.load()

        if status.isInit {
            guard let stored else {
                throw NeedsPassword(reason: "Serwer ma już konto root, ale w pęku kluczy nie ma jego hasła. Podaj je, aby aplikacja mogła zarządzać biblioteką.")
            }
            return stored
        }

        // Kolejność ma znaczenie: hasło musi trwale leżeć w pęku kluczy, zanim serwer je przyjmie,
        // inaczej awaria w połowie zostawiłaby roota z hasłem, którego nikt nie zna.
        let credentials = AudiobookshelfClient.Credentials(
            username: ServerEnvironment.rootUsername,
            password: CredentialStore.generatePassword()
        )
        try store.save(credentials)
        guard try store.load() == credentials else {
            throw CredentialStore.KeychainError(status: errSecDecode)
        }
        logger.notice("Zakładam konto root na czystym serwerze")
        try await client.initialize(root: credentials)
        return credentials
    }

    /// Wykonuje zapytanie z tokenem; po 401 (token wygasł po godzinie) loguje się raz ponownie.
    private func authorized<T: Sendable>(_ operation: (AudiobookshelfClient, String) async throws -> T) async throws -> T {
        guard let credentials, let token = accessToken else {
            throw AudiobookshelfClient.APIError.unauthorized
        }
        do {
            return try await operation(client, token)
        } catch AudiobookshelfClient.APIError.unauthorized {
            let login = try await client.login(credentials)
            accessToken = login.accessToken
            return try await operation(client, login.accessToken)
        }
    }

    // MARK: - Web UI

    /// Osobna sesja dla okna web UI. Refresh tokeny są rotowane przy odświeżaniu,
    /// więc web UI nie może dzielić sesji z aplikacją.
    func webSession() async throws -> AudiobookshelfClient.Login {
        guard state == .ready, let credentials else { throw AudiobookshelfClient.APIError.unauthorized }
        return try await client.login(credentials, returnRefreshToken: true)
    }

    // MARK: - Biblioteki

    func refreshLibraries() async throws {
        libraries = try await authorized { try await $0.libraries(token: $1) }
    }

    /// Biblioteka, która już obejmuje folder (ten sam, nadrzędny albo podrzędny).
    func libraryOverlapping(_ folder: URL) -> AudiobookshelfClient.Library? {
        let path = folder.standardizedFileURL.path
        return libraries.first { library in
            library.folders.contains { existing in
                path == existing.fullPath
                    || path.hasPrefix(existing.fullPath + "/")
                    || existing.fullPath.hasPrefix(path + "/")
            }
        }
    }

    /// Tworzy bibliotekę z folderu i czeka na koniec pierwszego skanu.
    func addLibrary(folder: URL) async {
        guard state == .ready, !isScanning else { return }
        let folder = folder.standardizedFileURL
        scan = ScanProgress(folder: folder, phase: .creating)

        do {
            if let existing = libraryOverlapping(folder) {
                throw LibraryError.overlaps(existing.name)
            }
            // Pierwszy odczyt robi aplikacja: ewentualna prośba o dostęp (TCC) pojawi się
            // teraz, w odpowiedzi na wybór użytkownika. Proces `node` dziedziczy zgodę,
            // bo macOS przypisuje uprawnienia aplikacji nadrzędnej.
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)

            let name = FileManager.default.displayName(atPath: folder.path)
            let library = try await authorized {
                try await $0.createLibrary(name: name, folderPath: folder.path, token: $1)
            }
            try await refreshLibraries()

            scan?.phase = .scanning
            try await authorized { try await $0.scanLibrary(id: library.id, token: $1) }
            try await waitForScan(libraryID: library.id)
            let count = try await authorized { try await $0.itemCount(libraryID: library.id, token: $1) }
            scan?.phase = .finished(items: count)
        } catch {
            logger.error("Dodawanie biblioteki: \(error.localizedDescription, privacy: .public)")
            scan?.phase = .failed(error.localizedDescription)
        }
    }

    private enum LibraryError: LocalizedError {
        case overlaps(String)

        var errorDescription: String? {
            switch self {
            case .overlaps(let name): "Ten folder należy już do biblioteki „\(name)”."
            }
        }
    }

    /// Skan nie ma własnego endpointu stanu: trwa, dopóki na liście zadań jest
    /// `library-scan` tej biblioteki (zadania znikają z listy po zakończeniu).
    private func waitForScan(libraryID: String) async throws {
        // Zadanie pojawia się synchronicznie przy zleceniu skanu, więc pierwszy odczyt już je widzi.
        while true {
            let tasks = try await authorized { try await $0.tasks(token: $1) }
            let running = tasks.contains { $0.action == "library-scan" && $0.data?.libraryId == libraryID }
            if !running { return }
            try await Task.sleep(for: .seconds(1))
        }
    }
}
