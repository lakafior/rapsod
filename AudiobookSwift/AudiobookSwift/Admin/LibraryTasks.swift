import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Admin")

/// Ponowny skan i dopasowanie całej biblioteki z podstrony „Biblioteki” (token root).
///
/// Serwer nie ma endpointu stanu skanu: trwa on, dopóki na liście `GET /api/tasks` jest zadanie
/// `library-scan` (albo `library-match-all`) tej biblioteki — to jest źródło prawdy, odpytywane
/// co 2 s, więc widać też skany zlecone przez obserwator plików albo telefon. Wynik (dodane,
/// zmienione, brakujące) serwer podaje tylko w zdarzeniu `task_finished` przez Socket.IO;
/// dlatego na czas pracy działa też osobne połączenie zdarzeń na tokenie root. Gdy zdarzenie
/// nie dotrze, wiersz pokazuje samo „zakończono”.
///
/// Odpytywanie i połączenie działają tylko, gdy podstrona jest widoczna albo coś trwa.
@MainActor
@Observable
final class LibraryTasks {
    enum Kind: Equatable {
        case scan(force: Bool)
        case matchAll
    }

    enum Phase: Equatable {
        case requested
        case running
        case finished(AudiobookshelfClient.ServerTask.ScanResults?, canceled: Bool)
        case failed(String)
    }

    struct Activity: Equatable {
        var kind: Kind
        var phase: Phase
        let since: Date

        var isRunning: Bool {
            switch phase {
            case .requested, .running: true
            case .finished, .failed: false
            }
        }
    }

    private let account: ServerAccount
    /// Ostatnia czynność każdej biblioteki (po identyfikatorze biblioteki).
    private(set) var activities: [String: Activity] = [:]

    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var events: ListeningEvents?
    /// Ile kolejnych odczytów nie widziało zadania, które powinno trwać.
    @ObservationIgnored private var misses: [String: Int] = [:]

    private static let actions: Set<String> = ["library-scan", "library-match-all"]

    init(account: ServerAccount) {
        self.account = account
    }

    func isRunning(_ libraryID: String) -> Bool {
        activities[libraryID]?.isRunning ?? false
    }

    var anyRunning: Bool { activities.values.contains(where: \.isRunning) }

    // MARK: Widoczność podstrony

    func appear() {
        viewers += 1
        startIfNeeded()
    }

    /// Konto root połączyło się ponownie (np. po restarcie serwera) przy otwartej podstronie.
    func resume() {
        if viewers > 0 { startIfNeeded() }
    }

    func disappear() {
        viewers = max(0, viewers - 1)
    }

    // MARK: Polecenia

    func scan(_ library: AudiobookshelfClient.Library, force: Bool) {
        start(library, kind: .scan(force: force)) { client, token in
            try await client.scanLibrary(id: library.id, force: force, token: token)
        }
    }

    func matchAll(_ library: AudiobookshelfClient.Library) {
        start(library, kind: .matchAll) { client, token in
            try await client.matchAllItems(libraryID: library.id, token: token)
        }
    }

    private func start(
        _ library: AudiobookshelfClient.Library,
        kind: Kind,
        request: @escaping @Sendable (AudiobookshelfClient, String) async throws -> Void
    ) {
        guard account.state == .ready, !isRunning(library.id) else { return }
        activities[library.id] = Activity(kind: kind, phase: .requested, since: .now)
        misses[library.id] = 0
        startIfNeeded()
        Task {
            do {
                try await account.withAdminToken(request)
            } catch {
                let action = kind == .matchAll ? "Nie udało się zlecić dopasowania" : "Nie udało się zlecić skanu"
                logger.error("\(action, privacy: .public): \(error.localizedDescription, privacy: .public)")
                activities[library.id]?.phase = .failed(ItemManager.message(for: error, action: action))
            }
        }
    }

    /// Zapomina wynik (np. po usunięciu biblioteki).
    func forget(_ libraryID: String) {
        activities[libraryID] = nil
    }

    // MARK: Odpytywanie i zdarzenia

    private func startIfNeeded() {
        guard loop == nil else { return }
        startEvents()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard viewers > 0 || anyRunning, account.state == .ready else { break }
                await poll()
                try? await Task.sleep(for: .seconds(2))
            }
            self?.stopLoop()
        }
    }

    private func stopLoop() {
        loop = nil
        events?.stop()
        events = nil
    }

    private func startEvents() {
        guard events == nil else { return }
        let account = account
        let events = ListeningEvents(baseURL: ServerEnvironment.baseURL, token: { rejected in
            try await account.withAdminToken { client, token in
                // Odrzucony token: zapytanie z nim dostanie 401, a `withAdminToken` zaloguje się ponownie.
                if token == rejected { let _: AudiobookshelfClient.User = try await client.me(token: token) }
                return token
            }
        }, handler: { [weak self] event in
            guard case .task(let task, let finished) = event else { return }
            self?.handle(task, finished: finished)
        })
        self.events = events
        events.start()
    }

    private func handle(_ task: AudiobookshelfClient.ServerTask, finished: Bool) {
        guard Self.actions.contains(task.action), let libraryID = task.data?.libraryId else { return }
        let kind: Kind = task.action == "library-match-all" ? .matchAll : (activities[libraryID]?.kind ?? .scan(force: false))
        if !finished {
            if activities[libraryID]?.isRunning != true {
                activities[libraryID] = Activity(kind: kind, phase: .running, since: .now)
            } else {
                activities[libraryID]?.phase = .running
            }
            misses[libraryID] = 0
            startIfNeeded()
            return
        }
        let phase: Phase = if task.isFailed == true {
            .failed(Self.failureText(task, kind: kind))
        } else {
            .finished(task.data?.scanResults, canceled: task.description?.localizedCaseInsensitiveContains("cancel") == true)
        }
        if activities[libraryID] == nil {
            activities[libraryID] = Activity(kind: kind, phase: phase, since: .now)
        } else {
            activities[libraryID]?.phase = phase
        }
        if case .finished(let results, _) = phase, (results?.added ?? 0) + (results?.missing ?? 0) > 0 {
            Task { try? await account.refreshLibraries() }
        }
    }

    private static func failureText(_ task: AudiobookshelfClient.ServerTask, kind: Kind) -> String {
        if task.error == "No items found" { return "Biblioteka nie ma pozycji do dopasowania." }
        let what = kind == .matchAll ? "Dopasowanie" : "Skan"
        return "\(what) nie powiódł się" + (task.error.map { " (\($0))" } ?? "") + ". Szczegóły są w logu serwera."
    }

    private func poll() async {
        let tasks: [AudiobookshelfClient.ServerTask]
        do {
            tasks = try await account.withAdminToken { try await $0.tasks(token: $1) }
        } catch {
            logger.notice("Lista zadań serwera: \(error.localizedDescription, privacy: .public)")
            return
        }
        let running = Dictionary(
            tasks.compactMap { task in
                task.data?.libraryId.flatMap { Self.actions.contains(task.action) ? ($0, task) : nil }
            },
            uniquingKeysWith: { first, _ in first }
        )
        for (libraryID, task) in running where activities[libraryID]?.isRunning != true || activities[libraryID]?.phase == .requested {
            handle(task, finished: false)
        }
        for (libraryID, activity) in activities where activity.isRunning && running[libraryID] == nil {
            // Zlecone zadanie może jeszcze nie stać na liście; trwające mogło się właśnie skończyć,
            // a jego `task_finished` (z wynikiem) bywa o chwilę później niż ten odczyt.
            let count = (misses[libraryID] ?? 0) + 1
            misses[libraryID] = count
            let grace = activity.phase == .requested ? 3 : 2
            if count >= grace {
                activities[libraryID]?.phase = .finished(nil, canceled: false)
            }
        }
    }
}
