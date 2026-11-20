import Foundation
import Observation

enum ServerState: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case failed(String)
}

/// Uruchamia serwer audiobookshelf jako proces potomny i pilnuje jego stanu.
@MainActor
@Observable
final class ServerSupervisor {
    private(set) var state: ServerState = .stopped {
        didSet {
            if state != oldValue { onStateChange?(state) }
        }
    }
    /// Środowisko ostatniego startu (`nil`, jeśli nie udało się go ustalić).
    private(set) var environment: ServerEnvironment?
    /// Adres web UI ostatnio uruchomionego serwera.
    private(set) var webURL: URL?
    @ObservationIgnored var onStateChange: ((ServerState) -> Void)?
    /// Ostatnie linie stdout/stderr serwera (ograniczony bufor).
    private(set) var recentLog: [String] = []

    var hasProcess: Bool { process != nil }

    private static let logLimit = 500
    private static let readinessTimeout: Duration = .seconds(60)
    private static let stopTimeout: Duration = .seconds(8)

    @ObservationIgnored private var process: Process?
    /// Koniec zapisu potoku stdin serwera. Dopóki aplikacja żyje, potok jest otwarty;
    /// po jej śmierci (także SIGKILL) serwer dostaje EOF i sam się wyłącza
    /// (zob. `Resources/parent-watch.js`).
    @ObservationIgnored private var lifeline: Pipe?
    /// Rośnie przy każdym starcie, żeby spóźnione zdarzenia starego procesu
    /// nie zmieniały stanu nowego.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var readinessTask: Task<Void, Never>?
    @ObservationIgnored private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var partialLine = Data()

    func start() {
        guard process == nil else { return }

        let environment: ServerEnvironment
        do {
            environment = try ServerEnvironment.resolve()
            try environment.prepareDirectories()
        } catch {
            self.environment = nil
            state = .failed(error.localizedDescription)
            return
        }
        self.environment = environment

        generation += 1
        let generation = generation
        stopRequested = false
        recentLog.removeAll()
        partialLine.removeAll()

        let process = Process()
        process.executableURL = environment.node
        process.arguments = environment.arguments
        process.environment = environment.processEnvironment
        process.currentDirectoryURL = environment.dataRoot

        let lifeline = Pipe()
        let output = Pipe()
        process.standardInput = lifeline
        process.standardOutput = output
        process.standardError = output

        // Potok musi być stale opróżniany — pełny bufor zawiesiłby serwer.
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
            state = .failed("Nie udało się uruchomić Node.js: \(error.localizedDescription)")
            return
        }
        // Nasze kopie końców należących do dziecka: bez zamknięcia nie zobaczymy EOF na wyjściu.
        try? output.fileHandleForWriting.close()
        try? lifeline.fileHandleForReading.close()

        self.process = process
        self.lifeline = lifeline
        webURL = environment.webURL
        state = .starting

        let healthURL = environment.healthURL
        readinessTask = Task { [weak self] in
            await self?.waitUntilReady(healthURL, generation: generation)
        }
    }

    /// Zatrzymuje serwer i wraca, gdy proces faktycznie się zakończył.
    func stop() async {
        guard let process else {
            state = .stopped
            return
        }
        let generation = generation
        stopRequested = true
        state = .stopping
        readinessTask?.cancel()

        // Upstream obsługuje tylko SIGINT (zamyka bazę i wychodzi).
        if process.isRunning {
            process.interrupt()
        }
        let killer = Task { [weak self] in
            try? await Task.sleep(for: Self.stopTimeout)
            guard !Task.isCancelled, let self, self.generation == generation,
                  let process = self.process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
        await withCheckedContinuation { exitWaiters.append($0) }
        killer.cancel()
    }

    func restart() async {
        await stop()
        start()
    }

    // MARK: - Zdarzenia procesu

    private func waitUntilReady(_ url: URL, generation: Int) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        let deadline = ContinuousClock.now + Self.readinessTimeout

        // Pętla kończy się też, gdy proces padnie (stan przestaje być `.starting`),
        // więc obcy program na tym samym porcie nie zostanie uznany za nasz serwer.
        while !Task.isCancelled, generation == self.generation, state == .starting {
            if let (_, response) = try? await session.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                if generation == self.generation, state == .starting {
                    state = .running
                }
                return
            }
            if ContinuousClock.now > deadline {
                state = .failed("Serwer nie odpowiedział w ciągu \(Self.readinessTimeout.components.seconds) s.")
                stopRequested = true
                if let process, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func processDidExit(generation: Int, status: Int32, reason: Process.TerminationReason) {
        guard generation == self.generation else { return }
        process = nil
        lifeline = nil
        readinessTask?.cancel()
        readinessTask = nil

        if case .failed = state {
            // Zachowaj wcześniejszy, dokładniejszy komunikat.
        } else if stopRequested {
            state = .stopped
        } else {
            state = .failed(Self.diagnose(log: recentLog, status: status, reason: reason))
        }

        let waiters = exitWaiters
        exitWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Zamienia typowe przyczyny awarii z logu Node na zrozumiały komunikat.
    private static func diagnose(log: [String], status: Int32, reason: Process.TerminationReason) -> String {
        let text = log.suffix(80).joined(separator: "\n")
        if text.contains("EADDRINUSE") {
            return "Port \(ServerEnvironment.port) jest zajęty przez inny program (EADDRINUSE). "
                + "Zamknij program, który go używa (np. inną kopię audiobookshelf), i uruchom serwer ponownie."
        }
        if text.contains("EACCES") || text.contains("EPERM") {
            return "Serwer nie ma dostępu do pliku lub folderu (EACCES/EPERM) — szczegóły w logu."
        }
        if text.contains("SQLITE_CORRUPT") || text.contains("SQLITE_CANTOPEN") {
            return "Nie udało się otworzyć bazy danych serwera — szczegóły w logu."
        }
        let detail = reason == .uncaughtSignal ? "sygnał \(status)" : "kod \(status)"
        return "Serwer zakończył się nieoczekiwanie (\(detail))."
    }

    private func appendOutput(_ chunk: Data, generation: Int) {
        guard generation == self.generation else { return }
        partialLine.append(chunk)
        while let newline = partialLine.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: partialLine[partialLine.startIndex..<newline], as: UTF8.self)
            partialLine.removeSubrange(partialLine.startIndex...newline)
            recentLog.append(line)
        }
        if recentLog.count > Self.logLimit {
            recentLog.removeFirst(recentLog.count - Self.logLimit)
        }
    }
}
