import AudiobookshelfKit
import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Rapsod", category: "Notifications")

/// Stałe połączenie zdarzeń serwera na czas działania aplikacji (etap 14e), niezależne od okien.
///
/// Gniazdo okna „Biblioteka” (`ListeningController`) i gniazda podstron (`LibraryTasks`, `ItemTasks`)
/// żyją tylko, gdy coś jest widoczne albo trwa — a powiadomienia są potrzebne właśnie wtedy, gdy
/// żadne okno nie jest otwarte (skan z harmonogramu albo obserwatora plików, pobieranie odcinków
/// w nocy). Ten obserwator działa, dopóki serwer działa, konto root jest połączone i któryś rodzaj
/// powiadomień tego wymaga; nie odpytuje serwera, tylko słucha. Zdarzenia przekazuje do tych samych
/// modeli, z których korzysta panel na pasku menu (stan skanu, kolejka pobierania), więc panel też
/// widzi skany i pobierania zlecone poza aplikacją.
///
/// Token root, bo konto root aplikacja zakłada i trzyma sama (konta słuchacza może nie być);
/// `task_*` i `episode_download_*` serwer wysyła wszystkim zalogowanym (`SocketAuthority.emitter`).
@MainActor
final class ServerActivityMonitor {
    private let account: ServerAccount
    private var events: ListeningEvents?
    private var watcher: Task<Void, Never>?
    /// Czy ktoś potrzebuje zdarzeń (powiadomienia włączone i dozwolone).
    private var wanted = false
    var onEvent: ((ListeningEvents.Event) -> Void)?

    init(account: ServerAccount) {
        self.account = account
    }

    var isRunning: Bool { events != nil }

    func activate() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            let changes = Observations { [weak self] in self?.account.state }
            for await state in changes {
                guard let self, state != nil else { return }
                apply()
            }
        }
    }

    func setWanted(_ wanted: Bool) {
        self.wanted = wanted
        apply()
    }

    private func apply() {
        if wanted, account.state == .ready {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard events == nil else { return }
        let account = account
        let events = ListeningEvents(baseURL: ServerEnvironment.baseURL, token: { rejected in
            try await account.withAdminToken { client, token in
                // Odrzucony token: zapytanie z nim dostanie 401, a `withAdminToken` zaloguje się ponownie.
                if token == rejected { let _: AudiobookshelfClient.User = try await client.me(token: token) }
                return token
            }
        }, handler: { [weak self] event in self?.onEvent?(event) })
        self.events = events
        events.start()
        logger.info("Zdarzenia serwera dla powiadomień: start")
    }

    private func stop() {
        guard let events else { return }
        events.stop()
        self.events = nil
        logger.info("Zdarzenia serwera dla powiadomień: stop")
    }
}
