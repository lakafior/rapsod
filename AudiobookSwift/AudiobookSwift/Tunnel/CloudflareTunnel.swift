import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Tunnel")

/// Opcjonalny Cloudflare Tunnel zarządzany zdalnie (konfiguracja w panelu Cloudflare,
/// tu tylko token): nadzoruje `cloudflared` jako proces potomny i ustala publiczny adres.
///
/// Jedyne miejsce w aplikacji, które wie o Cloudflare. Reszta zna tylko `publicURL`
/// jako „adres zewnętrzny”. Tunel kieruje ruch na pętlę zwrotną, więc nie wymaga
/// udostępniania w sieci lokalnej.
@MainActor
@Observable
final class CloudflareTunnel {
    enum State: Equatable {
        /// Tunel nie jest wybrany albo został zatrzymany.
        case off
        /// Brak `cloudflared` w systemie.
        case unavailable
        case needsToken
        /// Tunel startuje dopiero, gdy serwer działa i ma konto root.
        case waitingForServer
        /// `cloudflared` działa, ale nie ma jeszcze połączenia z Cloudflare (z ewentualnym powodem).
        case connecting(String?)
        case connected
        case failed(String)
    }

    private(set) var state: State = .off
    /// Ostatnie linie logu `cloudflared` (bez tokenu).
    private(set) var recentLog: [String] = []
    /// Identyfikator tunelu z zapisanego tokenu (`nil` = brak tokenu).
    private(set) var tunnelID: String?
    /// Nazwa hosta opublikowana w panelu dla naszego serwera (z konfiguracji, którą
    /// `cloudflared` dostaje od Cloudflare).
    private(set) var hostname: String?
    /// Konfiguracja w panelu nie prowadzi do serwera (brak trasy albo inny port).
    private(set) var configurationProblem: String?
    private(set) var tokenError: String?
    /// Ścieżka do `cloudflared` ustalona przy ostatniej próbie (`nil` = brak).
    private(set) var cloudflared: URL? = ServerEnvironment.cloudflared()

    var isRunning: Bool { process != nil }

    /// Publiczny adres serwera — tylko gdy tunel jest połączony i trasa prowadzi do serwera.
    var publicURL: URL? {
        guard state == .connected, let hostname else { return nil }
        return URL(string: "https://\(hostname)")
    }

    private static let logLimit = 300
    private static let stopTimeout: Duration = .seconds(8)

    @ObservationIgnored private var store: CredentialStore<String>?
    @ObservationIgnored private var process: Process?
    /// Koniec zapisu potoku stdin pośrednika `tunnel-watch.sh`: pierwsza linia to token,
    /// potem potok jest tylko trzymany. Zamknięcie (także śmierć aplikacji) kończy `cloudflared`.
    @ObservationIgnored private var lifeline: Pipe?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var partialLine = Data()
    @ObservationIgnored private var connections: Set<String> = []
    /// Ostatni czytelny powód problemu z logu (do stanu łączenia i błędu).
    @ObservationIgnored private var lastProblem: String?
    /// Ostatnie wejścia z `update` — do ponownej próby i zmiany tokenu.
    @ObservationIgnored private var selected = false
    @ObservationIgnored private var serverReady = false

    // MARK: - Token

    /// Wskazuje pozycję w pęku kluczy dla folderu danych i sprawdza, czy jest w niej token.
    func load(dataRoot: URL) {
        let store = CredentialStore<String>(
            service: ServerEnvironment.cloudflareTunnelKeychainService,
            account: dataRoot.path,
            label: "AudiobookSwift — token Cloudflare Tunnel"
        )
        self.store = store
        do {
            tunnelID = try store.load().flatMap { CloudflareTunnelToken(pasted: $0)?.tunnelID }
        } catch {
            tokenError = error.localizedDescription
        }
    }

    /// Zapisuje token w pęku kluczy (przyjmuje też całe polecenie skopiowane z panelu).
    /// Zwraca `false`, gdy tekst nie zawiera prawidłowego tokenu.
    @discardableResult
    func saveToken(_ text: String) async -> Bool {
        guard let token = CloudflareTunnelToken(pasted: text) else {
            tokenError = "To nie wygląda na token tunelu. W panelu Cloudflare skopiuj polecenie instalacji (zawiera długi ciąg zaczynający się od „eyJ”) i wklej je tutaj."
            return false
        }
        guard let store else { return false }
        do {
            try store.save(token.value)
        } catch {
            tokenError = error.localizedDescription
            return false
        }
        tokenError = nil
        tunnelID = token.tunnelID
        // Działający `cloudflared` ma stary token — uruchom go od nowa z nowym.
        await stop()
        await retry()
        return true
    }

    func removeToken() async {
        await stop()
        try? store?.delete()
        tunnelID = nil
        tokenError = nil
        hostname = nil
        await retry()
    }

    /// Ponowna próba po błędzie albo po doinstalowaniu `cloudflared`.
    func retry() async {
        await update(selected: selected, serverReady: serverReady, retry: true)
    }

    // MARK: - Uruchamianie

    /// Doprowadza tunel do stanu wynikającego z ustawień i stanu serwera. Wywoływane przy
    /// każdej zmianie wejść; po błędzie nie wznawia sam, dopóki wejścia się nie zmienią
    /// albo użytkownik nie wybierze „Spróbuj ponownie”.
    func update(selected: Bool, serverReady: Bool, retry: Bool = false) async {
        self.selected = selected
        self.serverReady = serverReady
        cloudflared = ServerEnvironment.cloudflared()
        guard selected else {
            await stop()
            state = .off
            return
        }
        guard let cloudflared else {
            await stop()
            state = .unavailable
            return
        }
        guard tunnelID != nil else {
            await stop()
            state = .needsToken
            return
        }
        guard serverReady else {
            await stop()
            state = .waitingForServer
            return
        }
        if case .failed = state, !retry { return }
        guard process == nil else { return }
        start(cloudflared: cloudflared)
    }

    private func start(cloudflared: URL) {
        let token: String
        do {
            guard let stored = try store?.load() else {
                tunnelID = nil
                state = .needsToken
                return
            }
            token = stored
        } catch {
            state = .failed("Nie udało się odczytać tokenu z pęku kluczy: \(error.localizedDescription)")
            return
        }
        guard let script = Bundle.main.url(forResource: "tunnel-watch", withExtension: "sh"),
              let config = Bundle.main.url(forResource: "cloudflared", withExtension: "yml") else {
            state = .failed("Brak zasobów tunelu w paczce aplikacji — przebuduj aplikację.")
            return
        }

        generation += 1
        let generation = generation
        stopRequested = false
        recentLog.removeAll()
        partialLine.removeAll()
        connections.removeAll()
        lastProblem = nil
        configurationProblem = nil

        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        // Własny, pusty plik konfiguracyjny: bez `--config` cloudflared czytałby
        // `~/.cloudflared/config.yml` użytkownika (np. jego innego tunelu).
        process.arguments = [
            script.path, cloudflared.path,
            "tunnel", "--config", config.path, "--no-autoupdate",
            "--metrics", "127.0.0.1:0", "--grace-period", "2s", "--loglevel", "info",
            "run",
        ]
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] {
            environment[key] = ProcessInfo.processInfo.environment[key]
        }
        process.environment = environment

        let lifeline = Pipe()
        let output = Pipe()
        process.standardInput = lifeline
        process.standardOutput = output
        process.standardError = output

        let (chunks, continuation) = AsyncStream.makeStream(of: Data.self)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        Task { [weak self] in
            for await chunk in chunks {
                self?.appendOutput(chunk, generation: generation)
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in self?.processDidExit(generation: generation, status: status) }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            state = .failed("Nie udało się uruchomić cloudflared: \(error.localizedDescription)")
            return
        }
        try? output.fileHandleForWriting.close()
        try? lifeline.fileHandleForReading.close()
        do {
            try lifeline.fileHandleForWriting.write(contentsOf: Data((token + "\n").utf8))
        } catch {
            logger.error("Nie udało się przekazać tokenu do cloudflared: \(error.localizedDescription, privacy: .public)")
        }

        self.process = process
        self.lifeline = lifeline
        state = .connecting(nil)
        logger.notice("Uruchomiono cloudflared")
    }

    /// Zatrzymuje `cloudflared` i wraca, gdy pośrednik się zakończył.
    func stop() async {
        guard process != nil else { return }
        let generation = generation
        stopRequested = true
        // Zamknięcie potoku = sygnał dla strażnika w `tunnel-watch.sh` (SIGTERM dla cloudflared).
        try? lifeline?.fileHandleForWriting.close()
        let killer = Task { [weak self] in
            try? await Task.sleep(for: Self.stopTimeout)
            guard !Task.isCancelled, let self, self.generation == generation,
                  let process = self.process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
        await withCheckedContinuation { exitWaiters.append($0) }
        killer.cancel()
    }

    // MARK: - Zdarzenia procesu

    private func processDidExit(generation: Int, status: Int32) {
        guard generation == self.generation else { return }
        process = nil
        lifeline = nil
        connections.removeAll()

        if stopRequested {
            state = .off
        } else {
            state = .failed(lastProblem ?? "cloudflared zakończył się nieoczekiwanie (kod \(status)) — szczegóły w logu tunelu.")
        }
        let waiters = exitWaiters
        exitWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func appendOutput(_ chunk: Data, generation: Int) {
        guard generation == self.generation else { return }
        partialLine.append(chunk)
        while let newline = partialLine.firstIndex(of: UInt8(ascii: "\n")) {
            let line = CloudflareTunnelToken.redact(String(decoding: partialLine[partialLine.startIndex..<newline], as: UTF8.self))
            partialLine.removeSubrange(partialLine.startIndex...newline)
            recentLog.append(line)
            interpret(line)
        }
        if recentLog.count > Self.logLimit {
            recentLog.removeFirst(recentLog.count - Self.logLimit)
        }
    }

    /// Stan z logu `cloudflared` (format 2025–2026: `INF Registered tunnel connection connIndex=0 …`).
    private func interpret(_ line: String) {
        let connIndex = line.firstMatch(of: /connIndex=(\d+)/).map { String($0.1) }

        if line.contains("Registered tunnel connection"), let connIndex {
            connections.insert(connIndex)
            lastProblem = nil
        } else if let connIndex,
                  line.contains("Unregistered tunnel connection") || line.contains("Retrying connection")
                    || line.contains("Connection terminated") || line.contains("Serve tunnel error") {
            connections.remove(connIndex)
        }

        if line.contains("Updated to new configuration") {
            applyConfiguration(line)
        } else if Self.isRejectedToken(line) {
            // Odrzuconego tokenu nie naprawi ponawianie — zatrzymaj i pokaż błąd.
            guard process != nil, !stopRequested else { return }
            let message = "Cloudflare nie przyjmuje tego tokenu — tunel mógł zostać usunięty w panelu albo token jest nieaktualny. Skopiuj aktualny token z panelu."
            Task {
                await stop()
                state = .failed(message)
            }
            return
        } else if let problem = Self.problem(in: line) {
            lastProblem = problem
        }

        guard process != nil, !stopRequested else { return }
        state = connections.isEmpty ? .connecting(lastProblem) : .connected
    }

    private static func isRejectedToken(_ line: String) -> Bool {
        ["Failed to get tunnel", "Unauthorized", "Invalid tunnel secret", "token is not valid"].contains { line.contains($0) }
    }

    private static func problem(in line: String) -> String? {
        guard line.contains(" ERR ") else { return nil }
        if line.contains("no such host") || line.contains("network is unreachable") || line.contains("i/o timeout")
            || line.contains("failed to dial") || line.contains("DNS") {
            return "Brak połączenia z Cloudflare (sieć niedostępna) — cloudflared ponawia próby."
        }
        return nil
    }

    // MARK: - Konfiguracja z panelu

    /// Ustala nazwę hosta z konfiguracji tunelu, którą `cloudflared` dostaje od Cloudflare
    /// i wypisuje jako `config="{\"ingress\":[…]}"`.
    private func applyConfiguration(_ line: String) {
        guard let rules = Self.ingressRules(in: line) else {
            hostname = nil
            configurationProblem = "Nie udało się odczytać adresu z konfiguracji tunelu (nieznany format logu cloudflared). Wpisz adres ręcznie w trybie „Własny adres”."
            return
        }
        let published = rules.filter { $0.hostname != nil }
        if let match = published.first(where: { Self.pointsAtServer($0.service) }) {
            hostname = match.hostname
            configurationProblem = nil
        } else if let other = published.first {
            hostname = nil
            configurationProblem = "W panelu Cloudflare adres \(other.hostname ?? "") prowadzi do \(other.service), a serwer działa na http://127.0.0.1:\(ServerEnvironment.port). Popraw usługę w trasie tunelu."
        } else {
            hostname = nil
            configurationProblem = "Tunel nie ma opublikowanej aplikacji. W panelu Cloudflare dodaj trasę „Published application” z usługą http://127.0.0.1:\(ServerEnvironment.port)."
        }
    }

    struct IngressRule: Equatable {
        let hostname: String?
        let service: String
    }

    static func ingressRules(in line: String) -> [IngressRule]? {
        guard let start = line.range(of: "config=\"")?.upperBound,
              let end = line.range(of: "\" version=", options: .backwards)?.lowerBound, start < end else { return nil }
        let json = line[start..<end]
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let ingress = object["ingress"] as? [[String: Any]] else { return nil }
        return ingress.compactMap { rule in
            guard let service = rule["service"] as? String else { return nil }
            let hostname = (rule["hostname"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return IngressRule(hostname: hostname, service: service)
        }
    }

    /// Czy usługa z trasy to nasz serwer na tym Macu (`http://localhost:PORT` albo `127.0.0.1`).
    static func pointsAtServer(_ service: String) -> Bool {
        guard let url = URL(string: service), url.scheme?.lowercased() == "http",
              let host = url.host()?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) && (url.port ?? 80) == ServerEnvironment.port
    }
}
