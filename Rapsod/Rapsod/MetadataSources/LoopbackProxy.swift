import Foundation
import Network

/// Przekaźnik TCP na pętli zwrotnej: nasłuchuje na stałym porcie i każde połączenie
/// przekazuje bajt po bajcie do portu, który poda `open` — dopiero gdy ten wróci.
///
/// Dzięki temu usługa za przekaźnikiem może nie działać w spoczynku: `open` ją budzi,
/// a klient w tym czasie po prostu czeka na odpowiedź (jego dane leżą w buforze jądra,
/// bo przed połączeniem z usługą niczego nie czytamy). Przekaźnik nie rozumie HTTP;
/// usługa widzi nagłówek `Host` z portem przekaźnika.
///
/// Cały stan żyje na jednej kolejce szeregowej.
final class LoopbackProxy: @unchecked Sendable {
    /// Wywoływane raz dla każdego przyjętego połączenia; zwraca port usługi.
    /// Błąd zamyka połączenie bez odpowiedzi.
    typealias Open = @Sendable () async throws -> Int
    /// Wywoływane raz po zakończeniu każdego przyjętego połączenia (także nieudanego).
    typealias Close = @Sendable () -> Void
    /// Nasłuch, który już działał, przestał działać (np. po zmianie stanu sieci).
    typealias Failure = @Sendable (any Error) -> Void

    private let queue = DispatchQueue(label: "net.smigi.rapsod.loopback-proxy")
    private let open: Open
    private let close: Close
    private let failure: Failure
    private var listener: NWListener?
    private var pendingStart: CheckedContinuation<Void, any Error>?
    private var relays: [ObjectIdentifier: Relay] = [:]

    init(open: @escaping Open, close: @escaping Close, failure: @escaping Failure) {
        self.open = open
        self.close = close
        self.failure = failure
    }

    /// Zaczyna nasłuch na `127.0.0.1:port`. Zgłasza błąd, gdy port jest zajęty.
    func start(port: Int) async throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw NWError.posix(.EINVAL)
        }
        let parameters = NWParameters.tcp
        // Tylko pętla zwrotna: przekaźnik nie jest osiągalny z sieci.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        parameters.acceptLocalOnly = true
        // Bez tego szybkie wyłączenie i włączenie funkcji trafiałoby na zajęty port.
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.listen(listener, continuation: continuation)
            }
        }
    }

    private func listen(_ listener: NWListener, continuation: CheckedContinuation<Void, any Error>) {
        self.listener?.cancel()
        self.listener = listener
        pendingStart = continuation
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.finishStart(nil)
            case .failed(let error), .waiting(let error):
                self.listener?.cancel()
                self.listener = nil
                // Błąd przy starcie dostaje wywołujący `start`; późniejszy — właściciel przekaźnika,
                // żeby nie pokazywał działającego nasłuchu przy zamkniętym porcie.
                if self.pendingStart != nil {
                    self.finishStart(error)
                } else {
                    self.failure(error)
                }
            case .cancelled:
                self.finishStart(CancellationError())
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    /// Kończy nasłuch i wszystkie trwające połączenia; wraca, gdy to zlecono.
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.listener?.cancel()
                self.listener = nil
                for relay in Array(self.relays.values) {
                    relay.finish()
                }
                continuation.resume()
            }
        }
    }

    private func finishStart(_ error: (any Error)?) {
        guard let continuation = pendingStart else { return }
        pendingStart = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func accept(_ inbound: NWConnection) {
        let relay = Relay(inbound: inbound, queue: queue) { [weak self] relay in
            guard let self else { return }
            self.relays[ObjectIdentifier(relay)] = nil
            self.close()
        }
        relays[ObjectIdentifier(relay)] = relay
        relay.begin()

        let open = open
        let queue = queue
        Task {
            do {
                let port = try await open()
                queue.async { relay.connect(toPort: port) }
            } catch {
                queue.async { relay.finish() }
            }
        }
    }
}

/// Jedno połączenie klienta i jego połączenie z usługą. Używane tylko na kolejce przekaźnika.
private final class Relay: @unchecked Sendable {
    private let inbound: NWConnection
    private var outbound: NWConnection?
    private let queue: DispatchQueue
    private let onFinish: (Relay) -> Void
    private var isFinished = false
    private var isPumping = false

    init(inbound: NWConnection, queue: DispatchQueue, onFinish: @escaping (Relay) -> Void) {
        self.inbound = inbound
        self.queue = queue
        self.onFinish = onFinish
    }

    /// Przyjmuje połączenie klienta, ale jeszcze niczego z niego nie czyta.
    func begin() {
        inbound.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        inbound.start(queue: queue)
    }

    func connect(toPort port: Int) {
        guard !isFinished, let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            finish()
            return
        }
        let outbound = NWConnection(host: .ipv4(.loopback), port: endpointPort, using: .tcp)
        self.outbound = outbound
        outbound.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !self.isPumping else { return }
                self.isPumping = true
                self.pump(from: self.inbound, to: outbound, isResponse: false)
                self.pump(from: outbound, to: self.inbound, isResponse: true)
            case .failed, .cancelled, .waiting:
                // `.waiting` to m.in. odmowa połączenia — usługa właśnie zniknęła.
                self.finish()
            default:
                break
            }
        }
        outbound.start(queue: queue)
    }

    /// Kolejny odczyt następuje dopiero po wysłaniu poprzedniej porcji, więc wolny
    /// odbiorca wstrzymuje nadawcę zamiast zapełniać pamięć.
    private func pump(from source: NWConnection, to destination: NWConnection, isResponse: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isFinished else { return }
            // Zerwane połączenie (np. klient zniknął w połowie żądania): nie ma komu odpowiadać.
            if error != nil {
                self.finish()
                return
            }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self, !self.isFinished else { return }
                    if sendError != nil {
                        self.finish()
                    } else if isComplete {
                        self.sourceEnded(destination: destination, isResponse: isResponse)
                    } else {
                        self.pump(from: source, to: destination, isResponse: isResponse)
                    }
                })
            } else if isComplete {
                self.sourceEnded(destination: destination, isResponse: isResponse)
            } else {
                self.pump(from: source, to: destination, isResponse: isResponse)
            }
        }
    }

    /// Koniec danych z jednej strony przekazujemy drugiej jako zamknięcie jej kierunku (FIN),
    /// nie zrywając drugiego: odpowiedź wysyłana po zamknięciu zapisu przez klienta dochodzi cała.
    private func sourceEnded(destination: NWConnection, isResponse: Bool) {
        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            // Usługa skończyła odpowiadać i zamknęła połączenie: nic więcej nie przyjdzie,
            // więc klient od razu dostaje zamknięcie (nie zostaje z martwym połączeniem keep-alive).
            if isResponse { self?.finish() }
        })
        if !isResponse {
            // Klient zamknął swój kierunek. Usługa ma ograniczony czas na dokończenie
            // odpowiedzi — połączenie, którego nie zamknie, nie może trzymać jej przy życiu bez końca.
            queue.asyncAfter(deadline: .now() + Self.responseGrace) { [weak self] in
                self?.finish()
            }
        }
    }

    /// Dłużej niż klient (audiobookshelf: 10 s) czeka na odpowiedź.
    private static let responseGrace: DispatchTimeInterval = .seconds(15)

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        inbound.stateUpdateHandler = nil
        outbound?.stateUpdateHandler = nil
        inbound.cancel()
        outbound?.cancel()
        onFinish(self)
    }
}
