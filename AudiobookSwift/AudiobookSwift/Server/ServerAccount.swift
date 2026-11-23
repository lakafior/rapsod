import AudiobookshelfKit
import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Account")

/// Konta aplikacji na serwerze.
///
/// **Root** jest zakładany automatycznie z losowym hasłem w pęku kluczy (decyzja z etapu 2)
/// i służy wyłącznie do obsługi serwera: biblioteki, zakładanie użytkownika
/// oraz tryb „Zarządzanie serwerem” w oknie web UI.
///
/// **Użytkownik** to zwykłe konto do słuchania, wymagane i wspólne dla web UI na Macu
/// i klienta na telefonie (decyzja z etapu 3) — dzięki temu postęp słuchania jest jeden.
/// Telefon loguje się nazwą i hasłem tego konta, nigdy roota.
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

    enum UserState: Equatable {
        /// Jeszcze nie sprawdzono (serwer niepołączony).
        case unknown
        /// Nie ma konta użytkownika — trzeba je utworzyć.
        case missing
        case ready(username: String)
        /// Dane w pęku kluczy nie pasują do serwera.
        case invalid(String)
    }

    enum WebSessionKind: Sendable {
        /// Zwykłe konto użytkownika.
        case listening
        /// Konto root, tylko na czas zarządzania serwerem.
        case management
    }

    /// Rodzaj biblioteki tworzonej z folderu. Upstream nie pozwala zmienić typu
    /// istniejącej biblioteki, więc wybór zapada przy dodawaniu.
    enum LibraryKind: Equatable {
        case audiobooks
        case podcasts

        var mediaType: String {
            switch self {
            case .audiobooks: "book"
            case .podcasts: "podcast"
            }
        }

        /// Domyślne źródło metadanych; `nil` zostawia domyślne upstreamu (`google`).
        var provider: String? {
            switch self {
            case .audiobooks: nil
            case .podcasts: "itunes"
            }
        }

        /// Ikona biblioteki w web UI; `nil` zostawia domyślną upstreamu.
        var icon: String? {
            switch self {
            case .audiobooks: nil
            case .podcasts: "podcast"
            }
        }
    }

    struct ScanProgress: Equatable {
        let folder: URL
        var kind: LibraryKind = .audiobooks
        var phase: ScanPhase
    }

    private(set) var state: State = .disconnected
    private(set) var libraries: [AudiobookshelfClient.Library] = []
    private(set) var username: String?
    private(set) var userState: UserState = .unknown
    private(set) var scan: ScanProgress?
    /// Rośnie, gdy administrator zmienił uprawnienia albo dostęp konta do słuchania —
    /// okno „Biblioteka” wczytuje wtedy listy od nowa.
    private(set) var listenerRevision = 0

    var isScanning: Bool {
        switch scan?.phase {
        case .creating, .scanning: true
        default: false
        }
    }

    @ObservationIgnored private var client = AudiobookshelfClient(baseURL: ServerEnvironment.baseURL)
    @ObservationIgnored private var store: CredentialStore<AudiobookshelfClient.Credentials>?
    @ObservationIgnored private var credentials: AudiobookshelfClient.Credentials?
    @ObservationIgnored private var userStore: CredentialStore<AudiobookshelfClient.Credentials>?
    @ObservationIgnored private var userCredentials: AudiobookshelfClient.Credentials?

    /// Dane logowania konta tego Maca do innych aplikacji (profil › „Dane logowania…”).
    var phoneCredentials: AudiobookshelfClient.Credentials? {
        guard case .ready = userState else { return nil }
        return userCredentials
    }
    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var environment: ServerEnvironment?
    /// Rośnie przy każdym połączeniu/rozłączeniu, żeby spóźnione odpowiedzi nie nadpisały stanu.
    @ObservationIgnored private var generation = 0

    // MARK: - Połączenie

    /// Wywoływane, gdy serwer zaczął odpowiadać.
    func connect(environment: ServerEnvironment) async {
        generation += 1
        let generation = generation
        self.environment = environment
        client = AudiobookshelfClient(baseURL: ServerEnvironment.baseURL)
        store = CredentialStore(
            service: ServerEnvironment.keychainService,
            account: environment.keychainAccount,
            label: "AudiobookSwift — konto root audiobookshelf",
            legacyService: ServerEnvironment.legacyKeychainService
        )
        userStore = CredentialStore(
            service: ServerEnvironment.userKeychainService,
            account: environment.keychainAccount,
            label: "AudiobookSwift — konto użytkownika audiobookshelf"
        )
        accessToken = nil
        state = .connecting
        userState = .unknown

        do {
            let credentials = try await ensureRootAccount()
            guard generation == self.generation else { return }
            let login = try await client.login(credentials)
            guard generation == self.generation else { return }
            self.credentials = credentials
            accessToken = login.accessToken
            username = login.username
            // Biblioteki przed `.ready`: inaczej przez chwilę wygląda, że serwer nie ma
            // żadnej, i przy każdym starcie otwiera się ekran powitalny.
            try await refreshLibraries()
            guard generation == self.generation else { return }
            state = .ready
            await connectUser(generation: generation)
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

    /// Łączy się od nowa z działającym serwerem — np. po przywróceniu kopii zapasowej,
    /// która podmieniła bazę (konta, hasła, biblioteki).
    func reconnect() async {
        guard let environment else { return }
        await connect(environment: environment)
    }

    /// Wywoływane, gdy serwer przestał działać.
    func disconnect() {
        generation += 1
        accessToken = nil
        credentials = nil
        userCredentials = nil
        state = .disconnected
        userState = .unknown
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
        await connectUser(generation: generation)
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
            password: PasswordGenerator.generate()
        )
        try store.save(credentials)
        guard try store.load() == credentials else {
            throw KeychainError(status: errSecDecode)
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

    /// Zapytanie z tokenem administratora dla modułów spoza tego pliku
    /// (wpis źródeł metadanych w `MetadataSources/`).
    func withAdminToken<T: Sendable>(_ operation: (AudiobookshelfClient, String) async throws -> T) async throws -> T {
        try await authorized(operation)
    }

    // MARK: - Konto użytkownika

    /// Sprawdza konto użytkownika zapisane w pęku kluczy.
    private func connectUser(generation: Int) async {
        do {
            guard let stored = try userStore?.load() else {
                userState = .missing
                return
            }
            let login = try await client.login(stored)
            guard generation == self.generation else { return }
            userCredentials = stored
            userState = .ready(username: login.username)
        } catch AudiobookshelfClient.APIError.unauthorized {
            guard generation == self.generation else { return }
            userState = .invalid("Hasło konta użytkownika zapisane w pęku kluczy nie pasuje. Podaj nazwę i aktualne hasło.")
        } catch {
            guard generation == self.generation else { return }
            logger.error("Konto użytkownika: \(error.localizedDescription, privacy: .public)")
            userState = .invalid(error.localizedDescription)
        }
    }

    enum UserSetupError: LocalizedError {
        case usernameTaken
        case reserved
        case notRegularUser

        var errorDescription: String? {
            switch self {
            case .usernameTaken: "Ta nazwa jest już zajęta na serwerze. Jeśli to Twoje konto, podaj jego hasło."
            case .reserved: "Konto root służy do zarządzania serwerem — wybierz inną nazwę."
            case .notRegularUser: "To konto ma uprawnienia administratora. Do słuchania wybierz zwykłe konto użytkownika — jego hasło wpisujesz w telefonie."
            }
        }
    }

    /// Ustawia konto użytkownika: z hasłem najpierw próbuje zalogować się na istniejące
    /// konto, a gdy go nie ma — zakłada nowe. Puste hasło oznacza losowe (trafia do pęku kluczy).
    func setUpUser(username: String, password: String) async throws {
        guard state == .ready, let userStore else { throw AudiobookshelfClient.APIError.unauthorized }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard username.lowercased() != ServerEnvironment.rootUsername else { throw UserSetupError.reserved }

        var credentials = AudiobookshelfClient.Credentials(username: username, password: password)
        var login: AudiobookshelfClient.Login?
        if !password.isEmpty {
            login = try? await client.login(credentials)
        } else {
            credentials.password = PasswordGenerator.generate()
        }
        if login == nil {
            do {
                _ = try await authorized { try await $0.createUser(credentials, token: $1) }
            } catch AudiobookshelfClient.APIError.http(status: 400, _) {
                throw UserSetupError.usernameTaken
            }
            logger.notice("Założono konto użytkownika")
            login = try await client.login(credentials)
        }
        guard let login else { throw AudiobookshelfClient.APIError.unauthorized }
        // Hasło tego konta jest wpisywane w telefonie i idzie przez sieć lokalną — tylko najmniejsze uprawnienia.
        // Wyjątek: to samo konto, któremu użytkownik sam nadał uprawnienia administratora przy
        // parowaniu telefonu (etap 10b) — ponowne podanie jego hasła nie może go odrzucić.
        let type = try await client.me(token: login.accessToken).type
        let previous = (try? userStore.load())?.username
        guard type == "user" || (type == "admin" && previous == login.username) else { throw UserSetupError.notRegularUser }
        try userStore.save(credentials)
        userCredentials = credentials
        userState = .ready(username: login.username)
    }

    // MARK: - Konto root na stronie „Administrator serwera”

    /// Hasło roota z pęku kluczy (do „Pokaż” i „Kopiuj”), gdy aplikacja jest zalogowana.
    var rootPassword: String? {
        guard state == .ready else { return nil }
        return credentials?.password
    }

    enum RootPasswordError: LocalizedError {
        case notReady
        /// Nowe hasło jest w błędzie, żeby arkusz mógł je pokazać do przepisania.
        case keychain(String, password: String)

        var errorDescription: String? {
            switch self {
            case .notReady: "Zmiana hasła wymaga działającego serwera i zalogowanego konta root."
            case .keychain(let detail, _): "Serwer przyjął nowe hasło konta root, ale nie udało się zapisać go w pęku kluczy (\(detail)). Przepisz hasło pokazane niżej — bez niego aplikacja nie zaloguje się po ponownym uruchomieniu."
            }
        }
    }

    /// Zmienia hasło roota (`PATCH /api/me/password`): najpierw na serwerze, potem w pęku kluczy
    /// (kolejność z planu, część 9). Puste hasło oznacza losowe. Serwer unieważnia stare sesje
    /// roota, więc aplikacja loguje się od razu nowym hasłem. Przy błędzie zapisu w pęku kluczy
    /// rzuca `RootPasswordError.keychain` — nowe hasło trzeba wtedy pokazać do przepisania.
    @discardableResult
    func changeRootPassword(to newPassword: String) async throws -> String {
        guard state == .ready, let current = credentials, let store else { throw RootPasswordError.notReady }
        let password = newPassword.isEmpty ? PasswordGenerator.generate() : newPassword
        try await authorized { try await $0.changeMyPassword(current: current.password, new: password, token: $1) }
        logger.notice("Zmieniono hasło konta root")
        var updated = current
        updated.password = password
        credentials = updated
        let login = try await client.login(updated)
        accessToken = login.accessToken
        do {
            try store.save(updated)
        } catch {
            logger.error("Zapis hasła roota w pęku kluczy: \(error.localizedDescription, privacy: .public)")
            throw RootPasswordError.keychain(error.localizedDescription, password: password)
        }
        return password
    }

    // MARK: - Zmiany konta tego Maca z profilu („Użytkownicy”)

    /// Nazwa konta do słuchania, którego używa aplikacja (i telefon), gdy działa.
    var listeningUsername: String? {
        if case .ready(let username) = userState { return username }
        return userCredentials?.username
    }

    /// Czy konto o tej nazwie to konto tego Maca (konto do słuchania). Jedyne porównanie
    /// w aplikacji: bez rozróżniania wielkości liter, jak logowanie w audiobookshelf.
    func isListener(username: String) -> Bool {
        guard let name = listeningUsername else { return false }
        return username.caseInsensitiveCompare(name) == .orderedSame
    }

    /// Hasło konta tego Maca z pęku kluczy (do „Pokaż”, „Kopiuj” i „Danych logowania”).
    var listenerPassword: String? { phoneCredentials?.password }

    /// Serwer przyjął nową nazwę albo hasło konta do słuchania: aplikacja zapisuje je od razu,
    /// bo serwer unieważnił już stare sesje tego konta. Okno biblioteki odnowi token samo
    /// (refresh token jest unieważniony, więc zaloguje się ponownie nowymi danymi).
    func listenerCredentialsChanged(username: String?, password: String?) {
        guard var credentials = userCredentials else { return }
        if let username { credentials.username = username }
        if let password, !password.isEmpty { credentials.password = password }
        userCredentials = credentials
        do {
            try userStore?.save(credentials)
            userState = .ready(username: credentials.username)
        } catch {
            logger.error("Zapis konta użytkownika w pęku kluczy: \(error.localizedDescription, privacy: .public)")
            userState = .invalid("Serwer przyjął zmianę konta „\(credentials.username)”, ale nie udało się zapisać jej w pęku kluczy (\(error.localizedDescription)). Podaj nazwę i nowe hasło, żeby aplikacja je zapamiętała.")
        }
    }

    /// Administrator zmienił uprawnienia lub dostęp konta do słuchania.
    func listenerPermissionsChanged() {
        listenerRevision += 1
    }

    /// Konto do słuchania usunięto z serwera: aplikacja zapomina je i prosi o nowe.
    func listenerDeleted() {
        do {
            try userStore?.delete()
        } catch {
            logger.error("Usuwanie konta użytkownika z pęku kluczy: \(error.localizedDescription, privacy: .public)")
        }
        userCredentials = nil
        userState = .missing
    }

    // MARK: - Web UI

    /// Osobna sesja dla okna web UI. Refresh tokeny są rotowane przy odświeżaniu,
    /// więc web UI nie może dzielić sesji z aplikacją.
    func webSession(_ kind: WebSessionKind) async throws -> AudiobookshelfClient.Login {
        let credentials = switch kind {
        case .listening: userCredentials
        case .management: self.credentials
        }
        guard state == .ready, let credentials else { throw AudiobookshelfClient.APIError.unauthorized }
        return try await client.login(credentials, returnRefreshToken: true)
    }

    // MARK: - Biblioteki

    func refreshLibraries() async throws {
        libraries = try await authorized { try await $0.libraries(token: $1) }
    }

    /// Biblioteka, która już obejmuje folder (ten sam, nadrzędny albo podrzędny).
    func libraryOverlapping(_ folder: URL) -> AudiobookshelfClient.Library? {
        let path = folder.libraryFolderURL.path
        return libraries.first { library in
            library.folders.contains { existing in
                path == existing.fullPath
                    || path.hasPrefix(existing.fullPath + "/")
                    || existing.fullPath.hasPrefix(path + "/")
            }
        }
    }

    /// Tworzy bibliotekę z folderu i czeka na koniec pierwszego skanu.
    func addLibrary(folder: URL, kind: LibraryKind = .audiobooks) async {
        guard state == .ready, !isScanning else { return }
        let folder = folder.libraryFolderURL
        scan = ScanProgress(folder: folder, kind: kind, phase: .creating)

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
                try await $0.createLibrary(
                    name: name,
                    folderPath: folder.path,
                    mediaType: kind.mediaType,
                    provider: kind.provider,
                    icon: kind.icon,
                    token: $1
                )
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

    /// Usuwa bibliotekę z serwera. Pliki w jej folderach zostają na dysku.
    func removeLibrary(_ library: AudiobookshelfClient.Library) async throws {
        guard state == .ready, !isScanning else { return }
        try await authorized { try await $0.deleteLibrary(id: library.id, token: $1) }
        // Wynik ostatniego skanu dotyczył być może tej biblioteki — nie zostawiaj go na ekranie.
        if let scan, library.folders.contains(where: { $0.fullPath == scan.folder.path }) {
            self.scan = nil
        }
        try await refreshLibraries()
    }

    /// Kolejność bibliotek na serwerze (etap 9i; `POST /api/libraries/order`) — taka sama w telefonie i web UI.
    func moveLibrary(_ library: AudiobookshelfClient.Library, by offset: Int) async throws {
        guard state == .ready, let index = libraries.firstIndex(of: library) else { return }
        let target = index + offset
        guard libraries.indices.contains(target) else { return }
        var ids = libraries.map(\.id)
        ids.swapAt(index, target)
        try await authorized { try await $0.reorderLibraries(ids, token: $1) }
        try await refreshLibraries()
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

extension URL {
    /// Folder biblioteki z rozwiązanymi dowiązaniami (`realpath`). Skaner serwera liczy ścieżki pozycji
    /// od prawdziwej ścieżki plików, więc folder podany przez dowiązanie (np. `~/Audiobooki` → dysk
    /// zewnętrzny albo `/tmp` → `/private/tmp`) dawał sklejone ścieżki i pusty skan. `standardizedFileURL`
    /// i `resolvingSymlinksInPath` się nie nadają — oba zdejmują prefiks `/private`.
    var libraryFolderURL: URL {
        guard let resolved = realpath(path, nil) else { return standardizedFileURL }
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
    }
}
