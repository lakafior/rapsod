import Foundation

/// Proces agregatora źródeł metadanych (`aio-abs-providers`, submodule
/// `vendor/aio-abs-providers`, bez modyfikacji) uruchamiany jako proces potomny.
///
/// Jedyne miejsce w aplikacji, które zna jego kontrakt (README agregatora, sekcje
/// „Environment” i „Embedding in another app”):
/// - `PORT=0` — wolny port; faktyczny adres jest w linii wyjścia `Backbone listening on …`;
/// - `HOST=127.0.0.1` — tylko pętla zwrotna (agregator odrzuca wtedy także obce nagłówki `Host`);
/// - `CONFIG_PATH` — plik konfiguracji w folderze danych, tworzony z domyślnego;
/// - `API_KEY` — wymagany na każdym endpoincie poza `/healthz`;
/// - `EXIT_ON_STDIN_CLOSE=1` — kończy się, gdy zniknie potok stdin trzymany przez aplikację
///   (także po `kill -9` aplikacji), więc nie zostaje osierocony;
/// - gotowość: `GET /healthz` → 200.
@MainActor
final class AggregatorProcess {
    struct Launch: Sendable {
        let node: URL
        let entryPoint: URL
        let configURL: URL
        let workingDirectory: URL
        let apiKey: String
    }

    struct StartError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Port, na którym agregator odpowiada (`nil`, dopóki nie jest gotowy).
    private(set) var port: Int?
    var isRunning: Bool { process != nil }

    /// Linia wyjścia agregatora (już bez klucza API).
    var onLogLine: ((String) -> Void)?
    /// Proces się zakończył; `expected` = na nasze żądanie. `reason` opisuje nieoczekiwany koniec.
    var onExit: ((_ expected: Bool, _ reason: String) -> Void)?

    /// Audiobookshelf czeka na dostawcę 10 s (`CustomProviderAdapter.js`), więc start,
    /// który się nie mieści, i tak nie zdąży odpowiedzieć.
    private static let startTimeout: Duration = .seconds(8)
    private static let stopTimeout: Duration = .seconds(5)

    private var process: Process?
    /// Koniec zapisu potoku stdin agregatora — zob. `EXIT_ON_STDIN_CLOSE` wyżej.
    private var lifeline: Pipe?
    private var generation = 0
    private var stopRequested = false
    private var listeningPort: Int?
    private var partialLine = Data()
    private var recentLines: [String] = []
    private var apiKey = ""
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    /// Uruchamia agregator i wraca z jego portem, gdy `/healthz` odpowiada 200.
    func start(_ launch: Launch) async throws -> Int {
        if let port { return port }
        guard process == nil else { throw StartError(message: "Źródła metadanych są właśnie zatrzymywane.") }

        generation += 1
        let generation = generation
        stopRequested = false
        listeningPort = nil
        partialLine.removeAll()
        recentLines.removeAll()
        apiKey = launch.apiKey

        let process = Process()
        process.executableURL = launch.node
        process.arguments = [launch.entryPoint.path]
        process.currentDirectoryURL = launch.workingDirectory
        // Środowisko budowane jawnie, bez dziedziczenia po aplikacji. Celowo bez
        // `NODE_USE_SYSTEM_CA`: z certyfikatami systemu Node 24 nie składa łańcucha
        // audioteka.com (zob. `src/lib/http.js` agregatora).
        var environment: [String: String] = [
            "NODE_ENV": "production",
            "PORT": "0",
            "HOST": ServerEnvironment.host,
            "CONFIG_PATH": launch.configURL.path,
            "API_KEY": launch.apiKey,
            "EXIT_ON_STDIN_CLOSE": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "TZ"] {
            environment[key] = inherited[key]
        }
        process.environment = environment

        let lifeline = Pipe()
        let output = Pipe()
        process.standardInput = lifeline
        process.standardOutput = output
        process.standardError = output

        // Potok musi być stale opróżniany — pełny bufor zawiesiłby agregator.
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
            let reason = process.terminationReason
            Task { @MainActor in
                self?.processDidExit(generation: generation, status: status, reason: reason)
            }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            throw StartError(message: "Nie udało się uruchomić Node.js: \(error.localizedDescription)")
        }
        // Nasze kopie końców należących do dziecka: bez zamknięcia nie zobaczymy EOF na wyjściu.
        try? output.fileHandleForWriting.close()
        try? lifeline.fileHandleForReading.close()
        self.process = process
        self.lifeline = lifeline

        do {
            let port = try await waitUntilReady(generation: generation)
            self.port = port
            return port
        } catch {
            if self.generation == generation, self.process != nil {
                await stop()
            }
            throw error
        }
    }

    /// Zatrzymuje agregator i wraca, gdy proces faktycznie się zakończył.
    func stop() async {
        guard let process else { return }
        let generation = generation
        stopRequested = true
        port = nil
        // Zamknięcie potoku stdin to dla agregatora polecenie zakończenia (kod 0).
        try? lifeline?.fileHandleForWriting.close()
        let killer = Task { [weak self] in
            try? await Task.sleep(for: Self.stopTimeout)
            guard !Task.isCancelled, let self, self.generation == generation, self.process === process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
        await withCheckedContinuation { exitWaiters.append($0) }
        killer.cancel()
    }

    // MARK: - Gotowość

    private func waitUntilReady(generation: Int) async throws -> Int {
        let deadline = ContinuousClock.now + Self.startTimeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        while true {
            // Proces padł w trakcie startu (np. nieprawidłowy plik konfiguracji).
            guard generation == self.generation, process != nil else {
                // Ostatnie linie wyjścia (z powodem) mogą dojść chwilę po zakończeniu procesu.
                try? await Task.sleep(for: .milliseconds(100))
                throw StartError(message: Self.diagnose(log: recentLines, detail: nil))
            }
            if let listeningPort,
               let url = URL(string: "http://\(ServerEnvironment.host):\(listeningPort)/healthz"),
               let (_, response) = try? await session.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                // W czasie zapytania proces mógł się skończyć, a port dostać ktoś inny.
                guard generation == self.generation, process != nil else { continue }
                return listeningPort
            }
            if ContinuousClock.now > deadline {
                throw StartError(message: "Źródła metadanych nie odpowiedziały w ciągu \(Self.startTimeout.components.seconds) s.")
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Zdarzenia procesu

    private func processDidExit(generation: Int, status: Int32, reason: Process.TerminationReason) {
        guard generation == self.generation else { return }
        process = nil
        lifeline = nil
        port = nil
        listeningPort = nil

        let detail = reason == .uncaughtSignal ? "sygnał \(status)" : "kod \(status)"
        onExit?(stopRequested, Self.diagnose(log: recentLines, detail: detail))

        let waiters = exitWaiters
        exitWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Zamienia znane komunikaty agregatora (`src/backbone/server.js`) na zrozumiały powód.
    private static func diagnose(log: [String], detail: String?) -> String {
        if let line = log.last(where: { $0.hasPrefix("Failed to load config, exiting:") }) {
            let cause = line.dropFirst("Failed to load config, exiting:".count).trimmingCharacters(in: .whitespaces)
            return "Plik konfiguracji źródeł metadanych jest nieprawidłowy (\(cause)). Popraw go albo usuń — zostanie utworzony od nowa."
        }
        if let line = log.last(where: { $0.hasPrefix("Cannot listen on") }) {
            return "Źródła metadanych nie mogły zacząć nasłuchu: \(line)"
        }
        let suffix = detail.map { " (\($0))" } ?? ""
        return "Źródła metadanych zakończyły się nieoczekiwanie\(suffix) — szczegóły w logu źródeł."
    }

    private func appendOutput(_ chunk: Data, generation: Int) {
        guard generation == self.generation else { return }
        partialLine.append(chunk)
        while let newline = partialLine.firstIndex(of: UInt8(ascii: "\n")) {
            var line = String(decoding: partialLine[partialLine.startIndex..<newline], as: UTF8.self)
            partialLine.removeSubrange(partialLine.startIndex...newline)
            // Agregator nie wypisuje klucza, ale log trafia na ekran i do schowka — na wszelki wypadek.
            if !apiKey.isEmpty {
                line = line.replacingOccurrences(of: apiKey, with: "•••")
            }
            if listeningPort == nil, let match = line.firstMatch(of: /^Backbone listening on http:\/\/127\.0\.0\.1:(\d+)/) {
                listeningPort = Int(match.1)
            }
            recentLines.append(line)
            if recentLines.count > 40 {
                recentLines.removeFirst(recentLines.count - 40)
            }
            onLogLine?(line)
        }
    }
}
