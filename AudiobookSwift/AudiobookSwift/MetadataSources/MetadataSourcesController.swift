import Foundation
import Network
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "MetadataSources")

/// Opcjonalne źródła metadanych (LubimyCzytać, Audioteka, Storytel, Audible): przełącznik,
/// uruchamianie na żądanie i wpis dostawcy w audiobookshelf.
///
/// Audiobookshelf dostaje stały adres na pętli zwrotnej (`ServerEnvironment.metadataSourcesURL`).
/// Pod tym adresem nasłuchuje sama aplikacja (`LoopbackProxy`) i przy pierwszym połączeniu
/// uruchamia agregator (`AggregatorProcess`), czeka na jego gotowość i przekazuje ruch.
/// Gdy przez `metadataSourcesIdleTimeout` nie ma żadnego połączenia ani otwartego okna
/// jego stron, agregator jest zatrzymywany — w spoczynku nie działa żaden dodatkowy proces.
/// Przy wyłączonej funkcji aplikacja nie nasłuchuje wcale.
@MainActor
@Observable
final class MetadataSourcesController {
    enum State: Equatable {
        case disabled
        /// Brak zbudowanego agregatora albo Node (z powodem).
        case unavailable(String)
        /// Aplikacja nasłuchuje, agregator nie działa — obudzi go pierwsze zapytanie.
        case sleeping
        case starting
        case running
        case failed(String)
    }

    /// Wpis dostawcy w audiobookshelf.
    enum Registration: Equatable {
        case none
        case waitingForServer
        case registered
        case failed(String)
    }

    /// Strony agregatora pokazywane w oknie aplikacji.
    enum Page: String, Sendable {
        case configuration = "admin"
        case search = "search-ui"
    }

    /// Nazwa, pod którą źródła widać w audiobookshelf (okno dopasowywania, ustawienia biblioteki).
    nonisolated static let providerName = "Źródła metadanych (AudiobookSwift)"

    private(set) var isEnabled = false
    private(set) var state: State = .disabled
    private(set) var registration: Registration = .none
    /// Trwa włączanie albo wyłączanie.
    private(set) var isBusy = false
    /// Ostatnie linie wyjścia agregatora (bez klucza API) i znaczniki startu/uśpienia.
    private(set) var recentLog: [String] = []
    /// Którą stronę ma pokazać okno źródeł metadanych; `pageRequest` rośnie przy każdym
    /// żądaniu, żeby ponowne wybranie tej samej strony wczytało ją od nowa (w oknie można
    /// było w międzyczasie przejść linkiem na drugą).
    private(set) var page: Page = .configuration
    private(set) var pageRequest = 0

    /// Działa proces, który trzeba zatrzymać przed wyjściem z aplikacji.
    var hasProcess: Bool { process.isRunning }

    private static let logLimit = 300

    @ObservationIgnored private let account: ServerAccount
    @ObservationIgnored private let process = AggregatorProcess()
    @ObservationIgnored private var proxy: LoopbackProxy?
    @ObservationIgnored private var dataRoot: URL?
    @ObservationIgnored private var settings = MetadataSourcesSettings()
    @ObservationIgnored private var store: CredentialStore<String>?
    /// Aplikacja nasłuchuje na stałym porcie.
    @ObservationIgnored private var isListening = false
    /// Połączenia przekazywane właśnie do agregatora (albo czekające na jego start).
    @ObservationIgnored private var activeConnections = 0
    /// Okno ze stroną agregatora jest otwarte — nie usypiamy go.
    @ObservationIgnored private var pageWindowIsOpen = false
    @ObservationIgnored private var startTask: Task<Int, any Error>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var accountObservation: Task<Void, Never>?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileWanted = false

    init(account: ServerAccount) {
        self.account = account
        if let dataRoot = try? ServerEnvironment.resolveDataRoot() {
            self.dataRoot = dataRoot
            settings = MetadataSourcesSettings.load(from: ServerEnvironment.metadataSourcesSettingsURL(dataRoot: dataRoot))
            store = CredentialStore(
                service: ServerEnvironment.metadataSourcesKeychainService,
                account: dataRoot.path,
                label: "AudiobookSwift — klucz źródeł metadanych"
            )
        }
        isEnabled = settings.isEnabled
        process.onLogLine = { [weak self] line in self?.appendLog(line) }
        process.onExit = { [weak self] expected, reason in self?.processDidExit(expected: expected, reason: reason) }
    }

    // MARK: - Włączanie

    /// Wywoływane raz przy starcie aplikacji. Przy wyłączonej funkcji nie robi nic poza
    /// obserwacją stanu konta (żeby usunąć wpis, który został po wcześniejszym włączeniu).
    func activate() {
        accountObservation = Task { [weak self] in
            // Także lista bibliotek: nowa biblioteka dostaje te źródła jako domyślnego dostawcę.
            let inputs = Observations { [weak self] in
                self.map { ReconcileInputs(isReady: $0.account.state == .ready, libraryIDs: $0.account.libraries.map(\.id)) }
            }
            for await _ in inputs {
                guard let self else { return }
                requestReconcile()
            }
        }
        guard isEnabled else { return }
        Task { await startListening() }
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        isEnabled = enabled
        settings.isEnabled = enabled
        saveSettings()
        if enabled {
            await startListening()
        } else {
            // Najpierw wpis w audiobookshelf, potem nasłuch — serwer nie pyta wtedy w próżnię.
            requestReconcile()
            await reconcileTask?.value
            await stopListening()
            state = .disabled
        }
    }

    /// Ponowna próba po błędzie albo po zbudowaniu agregatora.
    func retry() async {
        guard isEnabled, !isBusy else { return }
        if isListening {
            _ = try? await ensureRunning()
        } else {
            await startListening()
        }
    }

    /// Zatrzymuje nasłuch i agregator przed zakończeniem aplikacji. Wpis w audiobookshelf zostaje.
    func shutdown() async {
        accountObservation?.cancel()
        await stopListening()
    }

    private func startListening() async {
        guard isEnabled, !isListening else { return }
        guard let runtime = ServerEnvironment.metadataSourcesRuntime() else {
            state = .unavailable("Ta kopia aplikacji nie zawiera źródeł metadanych.")
            return
        }
        if let problem = runtime.problem() {
            state = .unavailable(problem)
            return
        }
        do {
            _ = try apiKey(createIfMissing: true)
        } catch {
            state = .failed("Nie udało się zapisać klucza źródeł metadanych w pęku kluczy: \(error.localizedDescription)")
            return
        }

        let proxy = LoopbackProxy(
            open: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.connectionOpened()
            },
            close: { [weak self] in
                Task { @MainActor in self?.connectionClosed() }
            },
            failure: { [weak self] error in
                Task { @MainActor in await self?.listenerDidFail(error) }
            }
        )
        do {
            try await proxy.start(port: ServerEnvironment.metadataSourcesPort)
        } catch {
            logger.error("Nasłuch źródeł metadanych: \(error.localizedDescription, privacy: .public)")
            let port = ServerEnvironment.metadataSourcesPort
            if case .posix(.EADDRINUSE) = error as? NWError {
                state = .failed("Port \(port) jest zajęty przez inny program. Zamknij go i wybierz „Spróbuj ponownie”.")
            } else {
                state = .failed("Nie udało się zacząć nasłuchu na porcie \(port): \(error.localizedDescription)")
            }
            return
        }
        // W trakcie oczekiwania funkcję mogli wyłączyć.
        guard isEnabled else {
            await proxy.stop()
            return
        }
        self.proxy = proxy
        isListening = true
        state = .sleeping
        logger.notice("Źródła metadanych nasłuchują na porcie \(ServerEnvironment.metadataSourcesPort, privacy: .public)")
        requestReconcile()
    }

    /// Nasłuch przestał działać w trakcie pracy: stan ma to pokazać, a „Spróbuj ponownie” go wznawia.
    private func listenerDidFail(_ error: any Error) async {
        guard isEnabled, isListening else { return }
        logger.error("Nasłuch źródeł metadanych przerwany: \(error.localizedDescription, privacy: .public)")
        await stopListening()
        state = .failed("Nasłuch na porcie \(ServerEnvironment.metadataSourcesPort) został przerwany (\(error.localizedDescription)). Wybierz „Spróbuj ponownie”.")
    }

    private func stopListening() async {
        idleTask?.cancel()
        isListening = false
        await proxy?.stop()
        proxy = nil
        await stopProcess()
    }

    // MARK: - Uruchamianie na żądanie

    /// Nowe połączenie na stałym porcie: budzi agregator i zwraca jego port.
    private func connectionOpened() async throws -> Int {
        activeConnections += 1
        idleTask?.cancel()
        return try await ensureRunning()
    }

    private func connectionClosed() {
        activeConnections = max(0, activeConnections - 1)
        scheduleIdleCheck()
    }

    /// Zwraca port działającego agregatora; w razie potrzeby go uruchamia. Równoległe
    /// wywołania czekają na ten sam start, a wywołanie w trakcie zatrzymywania — na jego
    /// koniec i świeży start (nie trafia do kończącego się procesu).
    private func ensureRunning() async throws -> Int {
        while let stopTask {
            await stopTask.value
        }
        guard isEnabled, isListening else { throw CancellationError() }
        if let port = process.port { return port }
        if let startTask { return try await startTask.value }
        let task = Task { [weak self] () throws -> Int in
            guard let self else { throw CancellationError() }
            defer { self.startTask = nil }
            return try await self.launch()
        }
        startTask = task
        return try await task.value
    }

    private func launch() async throws -> Int {
        state = .starting
        do {
            guard let dataRoot, let runtime = ServerEnvironment.metadataSourcesRuntime() else {
                throw AggregatorProcess.StartError(message: "Ta kopia aplikacji nie zawiera źródeł metadanych.")
            }
            if let problem = runtime.problem() {
                throw AggregatorProcess.StartError(message: problem)
            }
            let directory = ServerEnvironment.metadataSourcesDirectory(dataRoot: dataRoot)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let launch = AggregatorProcess.Launch(
                node: runtime.node,
                entryPoint: runtime.entryPoint,
                configURL: ServerEnvironment.metadataSourcesConfigURL(dataRoot: dataRoot),
                workingDirectory: directory,
                apiKey: try apiKey(createIfMissing: false)
            )
            let started = ContinuousClock.now
            appendLog("— uruchamianie (\(Date.now.formatted(date: .omitted, time: .standard))) —")
            let port = try await process.start(launch)
            let elapsed = ContinuousClock.now - started
            logger.notice("Źródła metadanych gotowe po \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
            state = .running
            scheduleIdleCheck()
            return port
        } catch {
            logger.error("Start źródeł metadanych: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    private func stopProcess() async {
        if let stopTask {
            await stopTask.value
            return
        }
        // Start w toku musi się skończyć, zanim zatrzymamy proces.
        if let startTask {
            _ = try? await startTask.value
        }
        guard process.isRunning else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.process.stop()
            self.stopTask = nil
        }
        stopTask = task
        await task.value
    }

    /// Usypia agregator, gdy przez cały `metadataSourcesIdleTimeout` nie było połączenia.
    private func scheduleIdleCheck() {
        idleTask?.cancel()
        guard process.isRunning, activeConnections == 0, !pageWindowIsOpen else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: ServerEnvironment.metadataSourcesIdleTimeout)
            // Sprawdzenie i rozpoczęcie zatrzymywania dzieją się bez zawieszenia pomiędzy,
            // więc nowe połączenie albo trafi przed nie (i odwoła uśpienie), albo poczeka na świeży start.
            guard !Task.isCancelled, let self, self.activeConnections == 0, !self.pageWindowIsOpen,
                  self.startTask == nil, self.process.isRunning else { return }
            logger.notice("Źródła metadanych: usypianie po bezczynności")
            await self.stopProcess()
        }
    }

    private func processDidExit(expected: Bool, reason: String) {
        idleTask?.cancel()
        guard isEnabled, isListening else { return }
        if expected {
            appendLog("— uśpione (\(Date.now.formatted(date: .omitted, time: .standard))) —")
            // Błąd startu ustawia własny, dokładniejszy stan.
            if state == .running { state = .sleeping }
        } else {
            appendLog("— \(reason) —")
            // Nasłuch trwa: następne zapytanie spróbuje uruchomić agregator od nowa.
            if state == .running { state = .failed(reason) }
        }
    }

    // MARK: - Okno stron agregatora

    /// Wybór strony przyciskiem w Ustawieniach aplikacji (okno otwiera wywołujący).
    func showPage(_ page: Page) {
        self.page = page
        pageRequest += 1
    }

    /// Adres strony agregatora dla okna aplikacji (z kluczem API w zapytaniu — nie logować).
    /// Budzi agregator i nie pozwala mu zasnąć, dopóki okno jest otwarte.
    func openPage(_ page: Page) async throws -> URL {
        pageWindowIsOpen = true
        idleTask?.cancel()
        _ = try await ensureRunning()
        let key = try apiKey(createIfMissing: false)
        var url = ServerEnvironment.metadataSourcesURL.appending(path: page.rawValue)
        url.append(queryItems: [URLQueryItem(name: "key", value: key)])
        return url
    }

    /// Okno zamknięte: agregator może zasnąć po zwykłym czasie bezczynności.
    func closePage() {
        guard pageWindowIsOpen else { return }
        pageWindowIsOpen = false
        scheduleIdleCheck()
    }

    // MARK: - Klucz API

    private struct MissingKey: LocalizedError {
        var errorDescription: String? { "W pęku kluczy nie ma klucza źródeł metadanych. Wyłącz i włącz źródła metadanych." }
    }

    /// Losowy klucz wspólny dla agregatora (`API_KEY`) i wpisu w audiobookshelf (`authHeaderValue`).
    private func apiKey(createIfMissing: Bool) throws -> String {
        guard let store else { throw MissingKey() }
        if let key = try store.load(), !key.isEmpty { return key }
        guard createIfMissing else { throw MissingKey() }
        let key = PasswordGenerator.generate()
        try store.save(key)
        return key
    }

    // MARK: - Wpis w audiobookshelf

    /// Uzgadnia wpis dostawcy ze stanem funkcji. Wywoływane przy każdej zmianie przełącznika,
    /// nasłuchu i przy każdym połączeniu aplikacji z serwerem; wywołania są szeregowane.
    private func requestReconcile() {
        reconcileWanted = true
        guard reconcileTask == nil else { return }
        reconcileTask = Task { [weak self] in
            while let self, self.reconcileWanted {
                self.reconcileWanted = false
                await self.reconcile()
            }
            self?.reconcileTask = nil
        }
    }

    private func reconcile() async {
        // Wyłączone i nigdy niczego nie dodaliśmy: żadnego zapytania do serwera.
        if !isEnabled, settings.providerID == nil {
            registration = .none
            return
        }
        guard account.state == .ready else {
            registration = isEnabled ? .waitingForServer : .none
            return
        }
        // Włączone, ale bez nasłuchu (brak agregatora, zajęty port): istniejącego wpisu nie
        // ruszamy — jego usunięcie przestawiłoby biblioteki na domyślnego dostawcę — i nie dodajemy nowego.
        if isEnabled, !isListening {
            registration = .none
            return
        }

        let url = ServerEnvironment.metadataSourcesURL.absoluteString
        do {
            let existing = try await account.withAdminToken { try await $0.customMetadataProviders(token: $1) }
            // Własny wpis: zapamiętany identyfikator albo dokładnie nasz adres na pętli zwrotnej.
            // Nazwa nie wystarcza — dostawców dodanych ręcznie nie ruszamy.
            let own = existing.filter { $0.id == settings.providerID || $0.url == url }

            guard isEnabled else {
                for provider in own {
                    try await account.withAdminToken { try await $0.deleteCustomMetadataProvider(id: provider.id, token: $1) }
                }
                if !own.isEmpty { logger.notice("Usunięto wpis źródeł metadanych z audiobookshelf") }
                // Biblioteki z tym dostawcą upstream sam przestawił na `google`.
                settings.providerID = nil
                settings.defaultedLibraryIDs = []
                saveSettings()
                registration = .none
                return
            }

            let key = try apiKey(createIfMissing: false)
            if own.count == 1, let current = own.first, current.url == url, current.authHeaderValue == key,
               current.mediaType == "book", current.name == Self.providerName {
                if settings.providerID != current.id {
                    settings.providerID = current.id
                    saveSettings()
                }
                try await applyLibraryDefault(providerID: current.id, replacing: [])
                registration = .registered
                return
            }
            // Upstream nie ma edycji wpisu: nieaktualny (stary adres albo klucz) zastępujemy nowym.
            let created = try await account.withAdminToken {
                try await $0.createCustomMetadataProvider(name: Self.providerName, url: url, mediaType: "book", authHeaderValue: key, token: $1)
            }
            settings.providerID = created.id
            saveSettings()
            // Przed usunięciem starego wpisu: inaczej upstream przestawiłby jego biblioteki na `google`.
            try await applyLibraryDefault(providerID: created.id, replacing: own.map(\.id))
            for provider in own {
                try await account.withAdminToken { try await $0.deleteCustomMetadataProvider(id: provider.id, token: $1) }
            }
            logger.notice("Dodano wpis źródeł metadanych w audiobookshelf")
            registration = .registered
        } catch {
            logger.error("Wpis źródeł metadanych w audiobookshelf: \(error.localizedDescription, privacy: .public)")
            registration = .failed(error.localizedDescription)
        }
    }

    /// Ustawia źródła jako domyślnego dostawcę bibliotek z książkami (decyzja użytkownika):
    /// każdej bibliotece raz — przy włączeniu funkcji albo gdy biblioteka jest nowa — oraz
    /// tym, które wskazywały na zastępowany wpis. Dostawcy zmienionego później ręcznie
    /// w audiobookshelf nie nadpisujemy. Po wyłączeniu funkcji upstream sam wraca na `google`.
    private func applyLibraryDefault(providerID: String, replacing replaced: [String]) async throws {
        let slug = "custom-\(providerID)"
        let replacedSlugs = Set(replaced.filter { $0 != providerID }.map { "custom-\($0)" })
        let libraries = try await account.withAdminToken { try await $0.libraries(token: $1) }
        var handled = Set(settings.defaultedLibraryIDs)
        for library in libraries where library.mediaType == "book" {
            let pointedAtReplaced = library.provider.map(replacedSlugs.contains) ?? false
            if library.provider != slug, pointedAtReplaced || !handled.contains(library.id) {
                try await account.withAdminToken { try await $0.setLibraryProvider(id: library.id, provider: slug, token: $1) }
                logger.notice("Ustawiono źródła metadanych jako domyślnego dostawcę biblioteki")
            }
            handled.insert(library.id)
        }
        // Usunięte biblioteki wypadają z listy.
        let updated = handled.intersection(libraries.map(\.id)).sorted()
        if updated != settings.defaultedLibraryIDs {
            settings.defaultedLibraryIDs = updated
            saveSettings()
        }
    }

    // MARK: - Pomocnicze

    private func saveSettings() {
        guard let dataRoot else { return }
        do {
            try settings.save(to: ServerEnvironment.metadataSourcesSettingsURL(dataRoot: dataRoot))
        } catch {
            logger.error("Zapis ustawień źródeł metadanych: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func appendLog(_ line: String) {
        recentLog.append(line)
        if recentLog.count > Self.logLimit {
            recentLog.removeFirst(recentLog.count - Self.logLimit)
        }
    }
}

private struct ReconcileInputs: Sendable, Equatable {
    let isReady: Bool
    let libraryIDs: [String]
}
