import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Manage")

/// Długie zadania pozycji na serwerze (etap 9e): osadzenie metadanych i scalenie do M4B.
///
/// Źródłem prawdy jest `GET /api/tasks?include=queue` (token root), odpytywane co 2 s, gdy
/// strona książki albo zakładka „Narzędzia” jest widoczna lub coś trwa — dzięki temu widać też
/// zadania zlecone z web UI i po ponownym otwarciu okna. Postęp (`task_progress`, `track_started`)
/// serwer wysyła **tylko administratorom**, więc na czas trwania zadania działa osobne gniazdo
/// zdarzeń na tokenie root, tak jak w `LibraryTasks`. Gniazdo słuchacza (`ListeningController`)
/// nie dostaje tokenu roota i tych zdarzeń nie widzi.
///
/// Stan żyje poza arkuszem edycji: zamknięcie arkusza nie przerywa ani nie gubi zadania.
@MainActor
@Observable
final class ItemTasks {
    enum Kind: String {
        case embed = "embed-metadata"
        case encode = "encode-m4b"

        var title: String {
            switch self {
            case .embed: "Osadzanie metadanych"
            case .encode: "Scalanie do M4B"
            }
        }
    }

    enum Phase: Equatable {
        /// Zlecone, jeszcze niewidoczne na liście zadań serwera.
        case requested
        /// Osadzanie czeka w kolejce serwera (działa jedno naraz).
        case queued
        case running
        case finished
        /// Zadanie zniknęło z listy serwera, a `task_finished` nie dotarło (np. błąd zaraz po starcie,
        /// zanim gniazdo root się połączyło) — wyniku nie znamy, więc nie udajemy sukcesu.
        case ended
        case canceled
        case failed(String)
    }

    struct Job: Equatable {
        let kind: Kind
        var phase: Phase
        /// 0…1, gdy serwer przysłał postęp.
        var progress: Double?
        /// `ino` przetwarzanego pliku (`track_started`).
        var currentFile: String?

        var isActive: Bool {
            switch phase {
            case .requested, .queued, .running: true
            case .finished, .ended, .canceled, .failed: false
            }
        }
    }

    private let account: ServerAccount
    /// Ostatnie zadanie każdej pozycji (po identyfikatorze pozycji).
    private(set) var jobs: [String: Job] = [:]

    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var events: ListeningEvents?
    @ObservationIgnored private var misses: [String: Int] = [:]
    /// Gniazdo root przeszło `auth` (serwer przysłał `init`).
    @ObservationIgnored private var socketReady = false

    init(account: ServerAccount) {
        self.account = account
    }

    var anyActive: Bool { jobs.values.contains(where: \.isActive) }

    func job(_ itemID: String) -> Job? { jobs[itemID] }

    // MARK: Widoczność

    func appear() {
        viewers += 1
        startIfNeeded()
    }

    func disappear() {
        viewers = max(0, viewers - 1)
    }

    /// Okno „Biblioteka” się zamyka: koniec odpytywania i gniazda root (zadanie na serwerze trwa dalej,
    /// a po ponownym otwarciu okna wraca z listy zadań).
    func shutdown() {
        loop?.cancel()
        loop = nil
        stopEvents()
    }

    /// Zapomina zakończone zadanie (przycisk „OK” przy wyniku).
    func dismiss(_ itemID: String) {
        if jobs[itemID]?.isActive == false { jobs[itemID] = nil }
    }

    // MARK: Polecenia

    func embed(itemID: String, backup: Bool) async throws {
        try await start(itemID, kind: .embed) { try await $0.embedMetadata(itemID: itemID, backup: backup, token: $1) }
    }

    func encode(itemID: String, options: AudiobookshelfClient.EncodeOptions) async throws {
        try await start(itemID, kind: .encode) { try await $0.encodeM4b(itemID: itemID, options: options, token: $1) }
    }

    func cancelEncode(itemID: String) async throws {
        try await account.withAdminToken { try await $0.cancelM4b(itemID: itemID, token: $1) }
        // `task_finished` z `Task canceled by user` przyjdzie gniazdem; to tylko szybsza odpowiedź.
        if jobs[itemID]?.kind == .encode, jobs[itemID]?.isActive == true { jobs[itemID]?.phase = .canceled }
    }

    private func start(_ itemID: String, kind: Kind, request: @Sendable (AudiobookshelfClient, String) async throws -> Void) async throws {
        guard jobs[itemID]?.isActive != true else { return }
        jobs[itemID] = Job(kind: kind, phase: .requested)
        misses[itemID] = 0
        startIfNeeded()
        // Błąd zaraz po starcie (np. folder tylko do odczytu) serwer zgłasza tylko w `task_finished`,
        // więc najpierw czekamy chwilę, aż gniazdo root się połączy.
        for _ in 0..<30 where !socketReady {
            try? await Task.sleep(for: .milliseconds(100))
        }
        do {
            try await account.withAdminToken(request)
        } catch {
            jobs[itemID] = nil
            throw error
        }
        await poll()
    }

    // MARK: Odpytywanie i zdarzenia

    private func startIfNeeded() {
        if anyActive { startEvents() }
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard viewers > 0 || anyActive, account.state == .ready else { break }
                await poll()
                if anyActive { startEvents() } else { stopEvents() }
                try? await Task.sleep(for: .seconds(2))
            }
            self?.loop = nil
            self?.stopEvents()
        }
    }

    private func startEvents() {
        guard events == nil, account.state == .ready else { return }
        let account = account
        let events = ListeningEvents(baseURL: ServerEnvironment.baseURL, token: { rejected in
            try await account.withAdminToken { client, token in
                if token == rejected { let _: AudiobookshelfClient.User = try await client.me(token: token) }
                return token
            }
        }, handler: { [weak self] event in
            self?.handle(event)
        })
        self.events = events
        events.start()
    }

    private func stopEvents() {
        events?.stop()
        events = nil
        socketReady = false
    }

    private func handle(_ event: ListeningEvents.Event) {
        switch event {
        case .task(let task, let finished):
            guard let kind = Kind(rawValue: task.action), let itemID = task.data?.libraryItemId else { return }
            if finished {
                finish(itemID, kind: kind, task: task)
            } else {
                mark(itemID, kind: kind, phase: .running)
            }
        case .taskProgress(let itemID, let progress):
            guard jobs[itemID]?.isActive == true else { return }
            jobs[itemID]?.phase = .running
            jobs[itemID]?.progress = min(1, max(0, progress / 100))
        case .trackStarted(let itemID, let ino):
            guard jobs[itemID]?.isActive == true else { return }
            jobs[itemID]?.currentFile = ino
        case .connected, .reconnected:
            socketReady = true
        default:
            break
        }
    }

    private func mark(_ itemID: String, kind: Kind, phase: Phase) {
        if jobs[itemID]?.isActive == true, jobs[itemID]?.kind == kind {
            jobs[itemID]?.phase = phase
        } else {
            jobs[itemID] = Job(kind: kind, phase: phase)
        }
        misses[itemID] = 0
        startIfNeeded()
    }

    private func finish(_ itemID: String, kind: Kind, task: AudiobookshelfClient.ServerTask) {
        let phase: Phase
        if task.isFailed == true {
            phase = task.errorKey == "MessageTaskCanceledByUser" || task.error == "Task canceled by user"
                ? .canceled
                : .failed(Self.failureText(task))
        } else {
            phase = .finished
        }
        let wasActive = jobs[itemID].map { $0.isActive || $0.phase == .ended } ?? false
        jobs[itemID] = Job(kind: kind, phase: phase, progress: phase == .finished ? 1 : jobs[itemID]?.progress)
        if phase == .finished, wasActive { rescan(itemID) }
    }

    /// Pliki się zmieniły (nowy M4B, inne rozmiary). Obserwator plików serwera bywa wyłączony,
    /// więc skan pozycji zlecamy sami — wynik (`item_updated`) odświeży stronę książki.
    private func rescan(_ itemID: String) {
        Task {
            do {
                _ = try await account.withAdminToken { try await $0.scanItem(id: itemID, token: $1) }
            } catch {
                logger.notice("Skan po zadaniu: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func failureText(_ task: AudiobookshelfClient.ServerTask) -> String {
        let known: [String: String] = [
            "MessageTaskTargetDirectoryNotWritable": "Serwer nie może pisać w folderze książki.",
            "MessageTaskFailedToWriteMetadataFile": "Nie udało się zapisać pliku metadanych.",
            "MessageTaskFailedToMergeAudioFiles": "ffmpeg nie scalił plików audio.",
            "MessageTaskFailedToMoveM4bFile": "Nie udało się przenieść gotowego pliku M4B do folderu książki.",
            "MessageTaskFailedToEmbedMetadataInFile": "ffmpeg nie osadził metadanych w pliku.",
            "MessageTaskFailedToBackupAudioFile": "Nie udało się zrobić kopii pliku audio.",
            "MessageTaskAudioFileNotWritable": "Plik audio jest tylko do odczytu.",
            "MessageTaskFailedToCreateCacheDirectory": "Nie udało się utworzyć folderu podręcznego.",
        ]
        let text = task.errorKey.flatMap { known[$0] } ?? task.error.map { "Serwer zgłosił błąd: \($0)." } ?? "Zadanie nie powiodło się."
        return text + " Szczegóły są w logu serwera."
    }

    private func poll() async {
        let list: AudiobookshelfClient.TaskList
        do {
            list = try await account.withAdminToken { try await $0.itemTasks(token: $1) }
        } catch {
            logger.notice("Lista zadań serwera: \(error.localizedDescription, privacy: .public)")
            return
        }
        var seen = Set<String>()
        for task in list.tasks.elements where task.isFinished != true {
            guard let kind = Kind(rawValue: task.action), let itemID = task.data?.libraryItemId else { continue }
            seen.insert(itemID)
            if jobs[itemID]?.isActive != true || jobs[itemID]?.phase == .requested || jobs[itemID]?.phase == .queued {
                mark(itemID, kind: kind, phase: .running)
            }
        }
        for itemID in list.queuedEmbeds where !seen.contains(itemID) {
            seen.insert(itemID)
            if jobs[itemID]?.phase != .queued { mark(itemID, kind: .embed, phase: .queued) }
        }
        for (itemID, job) in jobs where job.isActive && !seen.contains(itemID) {
            // Zadanie znika z listy po zakończeniu; wynik niesie `task_finished`, który bywa o chwilę później.
            let count = (misses[itemID] ?? 0) + 1
            misses[itemID] = count
            if count >= (job.phase == .requested ? 3 : 2) {
                jobs[itemID]?.phase = .ended
                rescan(itemID)
            }
        }
    }
}
