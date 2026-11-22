// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: na wzór `DownloadManager` z projektu Dove (`Packages/DoveKit/Sources/DoveKit/Downloads/
// DownloadManager.swift`, MPL-2.0, ten sam autor): sesja tła z delegatem na głównej kolejce,
// identyfikator zadania w `taskDescription`, podłączanie zadań po ponownym uruchomieniu,
// wstrzymanie z danymi wznowienia, przeniesienie pliku przed powrotem z `didFinishDownloadingTo`,
// wyłączenie z kopii iCloud i sprawdzenie wolnego miejsca. Reszta (pozycje z wieloma plikami,
// bramka sieci, zmiana adresu serwera, ponawianie, spójność indeksu) — kod własny etapu 10f.

import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "net.smigi.abswift", category: "Downloads")

/// Pobieranie plików audio pozycji na urządzenie przez sesję tła `URLSession`: pliki pobierają się
/// także po zamknięciu aplikacji, a system budzi ją, żeby oddać gotowe.
///
/// - **Kolejka.** Wszystkie pliki czekających pozycji trafiają od razu do sesji — kolejka działa
///   też wtedy, gdy aplikacja śpi. Równoległość ogranicza `httpMaximumConnectionsPerHost`.
/// - **Sieć.** Pobiera tylko przy otwartej bramce (`setGate`): adres serwera wybrany w chwili startu
///   zadania. Zamknięcie bramki wstrzymuje zadania z danymi wznowienia; zmiana adresu (sieć lokalna ↔
///   tunel) zaczyna bieżące pliki od nowa pod nowym adresem — dane wznowienia są związane z adresem.
/// - **Błędy sieci** ponawia z rosnącym odstępem; po `DownloadIndex.maxAutomaticAttempts` czeka na
///   zmianę sieci albo „Ponów”. Odmowa serwera (403, 404) od razu kończy się błędem.
/// - **Indeks** (`DownloadedItem`) jest trwały, ścieżki względne. Plik jest „pobrany” dopiero po
///   sprawdzeniu statusu HTTP i rozmiaru.
@MainActor
@Observable
public final class DownloadManager: NSObject {
    /// Stan jednej pozycji do obserwacji w widoku: zmiana procentu przerysowuje tylko ją.
    @MainActor
    @Observable
    public final class Entry {
        public fileprivate(set) var status: DownloadStatus
        init(_ status: DownloadStatus) { self.status = status }
    }

    public enum DownloadError: LocalizedError, Equatable {
        case notEnoughSpace(needed: Int64, available: Int64)
        case nothingToDownload

        public var errorDescription: String? {
            switch self {
            case let .notEnoughSpace(needed, available):
                "Za mało miejsca na telefonie: potrzeba \(needed.formatted(.byteCount(style: .file))), wolne \(available.formatted(.byteCount(style: .file)))."
            case .nothingToDownload:
                "Ta pozycja nie ma plików audio do pobrania."
            }
        }
    }

    @ObservationIgnored public private(set) var items: [String: DownloadedItem] = [:]
    /// Rośnie, gdy pozycja dochodzi, znika albo zmienia stan (nie przy zmianie procentu) — listy.
    public private(set) var revision = 0
    public private(set) var gate: DownloadGate = .closed(.connection)
    /// Serwer, z którego pliki wolno teraz pobierać (pozycje innych serwerów czekają).
    @ObservationIgnored public var activeScope: String? {
        didSet { if activeScope != oldValue { pump() } }
    }
    public let directory: URL

    /// Klucz API (albo token) do nagłówka `Authorization` — przy tworzeniu zadania.
    @ObservationIgnored public var authorization: (@MainActor () -> String?)?
    /// Zadanie nie doszło do serwera — warto sprawdzić adres od nowa.
    @ObservationIgnored public var onConnectionError: (@MainActor () -> Void)?
    /// Przekazane przez aplikację, gdy system obudził ją dla tej sesji; wołane po oddaniu zdarzeń.
    @ObservationIgnored public var backgroundEventsCompletion: (() -> Void)?
    /// Wolne miejsce (bajty); podmieniane w testach.
    @ObservationIgnored public var availableSpace: () -> Int64?

    @ObservationIgnored private let indexURL: URL?
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private var tasks: [DownloadTaskID: URLSessionDownloadTask] = [:]
    /// Adres serwera, pod którym zadanie wystartowało.
    @ObservationIgnored private var taskBases: [DownloadTaskID: URL] = [:]
    /// Zadania anulowane celowo (pauza, zmiana sieci, usunięcie) — ich błąd nie jest błędem.
    @ObservationIgnored private var intentional: Set<DownloadTaskID> = []
    /// Zadania, których plik już obsłużył `didFinishDownloadingTo`.
    @ObservationIgnored private var handled: Set<DownloadTaskID> = []
    @ObservationIgnored private var written: [String: [String: Int64]] = [:]
    @ObservationIgnored private var lastProgress: [String: Date] = [:]
    @ObservationIgnored private var retryAt: [DownloadTaskID: Date] = [:]
    @ObservationIgnored private var retryTimer: Task<Void, Never>?
    @ObservationIgnored private var attached = false
    private static let progressInterval: TimeInterval = 0.5

    /// Konfiguracja sesji tła dla aplikacji (testy używają zwykłej).
    public static func backgroundConfiguration(identifier: String, maximumConnections: Int = 2) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = false
        configuration.httpMaximumConnectionsPerHost = maximumConnections
        configuration.timeoutIntervalForRequest = 60
        #if os(iOS)
        configuration.sessionSendsLaunchEvents = true
        #endif
        return configuration
    }

    /// - Parameters:
    ///   - directory: katalog pobranych (wyłączany z kopii iCloud).
    ///   - indexURL: plik indeksu; `nil` — tylko w pamięci (testy).
    public init(configuration: URLSessionConfiguration, directory: URL, indexURL: URL?) {
        self.directory = directory
        self.indexURL = indexURL
        self.availableSpace = { [directory] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        }
        super.init()
        prepareDirectory()
        if let indexURL, let data = try? Data(contentsOf: indexURL) {
            do {
                let list = try JSONDecoder().decode([DownloadedItem].self, from: data)
                items = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            } catch {
                logger.error("Indeks pobranych nieczytelny: \(error.localizedDescription, privacy: .public)")
            }
        }
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        Task { await attachRunningTasks() }
    }

    // MARK: - Odczyt

    public func item(itemID: String, episodeID: String?) -> DownloadedItem? {
        items[ProgressJournal.key(itemID, episodeID)]
    }

    /// Pobrana w całości — do odtwarzania z pliku.
    public func completeItem(itemID: String, episodeID: String?) -> DownloadedItem? {
        item(itemID: itemID, episodeID: episodeID).flatMap { $0.isComplete ? $0 : nil }
    }

    public func entry(itemID: String, episodeID: String?) -> Entry {
        let key = ProgressJournal.key(itemID, episodeID)
        if let entry = entries[key] { return entry }
        let entry = Entry(status(of: key))
        entries[key] = entry
        return entry
    }

    /// Pozycje serwera, od ostatnio dodanej (obserwuje `revision`).
    public func items(scope: String) -> [DownloadedItem] {
        _ = revision
        return items.values.filter { $0.scope == scope }.sorted { $0.addedAt > $1.addedAt }
    }

    public func fileURL(_ item: DownloadedItem, _ file: DownloadedFile) -> URL {
        directory.appending(path: item.folder).appending(path: file.fileName)
    }

    public func coverURL(_ item: DownloadedItem) -> URL? {
        item.hasCover ? directory.appending(path: item.folder).appending(path: "cover.jpg") : nil
    }

    /// Zajęte miejsce (pobrane pliki i okładki); `scope == nil` — wszystkich serwerów.
    public func usedBytes(scope: String? = nil) -> Int64 {
        _ = revision
        return items.values.filter { scope == nil || $0.scope == scope }.reduce(0) { sum, item in
            sum + item.files.filter { $0.state == .done }.reduce(0) { $0 + ($1.expectedSize ?? 0) }
        }
    }

    private func status(of key: String) -> DownloadStatus {
        guard let item = items[key] else { return .notDownloaded }
        let gate = item.scope == activeScope ? gate : .closed(.connection)
        return DownloadIndex.status(of: item, gate: gate, written: written[key] ?? [:])
    }

    // MARK: - Działania

    /// Dodaje pozycję do kolejki (albo zostawia już pobieraną). Sprawdza wolne miejsce.
    public func enqueue(_ item: DownloadedItem, cover: Data? = nil) throws {
        if let existing = items[item.id] {
            if existing.failure != nil { retry(key: item.id) }
            return
        }
        guard !item.files.isEmpty else { throw DownloadError.nothingToDownload }
        if let available = availableSpace(), !DownloadIndex.hasRoom(for: item.remainingBytes, available: available) {
            throw DownloadError.notEnoughSpace(needed: item.remainingBytes, available: available)
        }
        var item = item
        let folder = directory.appending(path: item.folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let cover, (try? cover.write(to: folder.appending(path: "cover.jpg"), options: .atomic)) != nil {
            item.hasCover = true
        }
        items[item.id] = item
        changed(item.id)
        pump()
    }

    public func pause(key: String) {
        guard var item = items[key], !item.isPaused, !item.isComplete else { return }
        item.isPaused = true
        items[key] = item
        for file in item.files where file.state == .downloading { suspend(DownloadTaskID(itemKey: key, ino: file.ino)) }
        changed(key)
    }

    public func resume(key: String) {
        guard var item = items[key], item.isPaused else { return }
        item.isPaused = false
        items[key] = item
        changed(key)
        pump()
    }

    /// „Ponów” po błędzie: liczniki prób od zera.
    public func retry(key: String) {
        guard var item = items[key] else { return }
        for index in item.files.indices where item.files[index].state != .done {
            item.files[index].state = .queued
            item.files[index].attempts = 0
            retryAt[DownloadTaskID(itemKey: key, ino: item.files[index].ino)] = nil
        }
        item.isPaused = false
        items[key] = item
        changed(key)
        pump()
    }

    /// Przerywa pobieranie i usuwa pozycję razem z plikami.
    public func remove(key: String) {
        guard let item = items.removeValue(forKey: key) else { return }
        for file in item.files {
            let id = DownloadTaskID(itemKey: key, ino: file.ino)
            cancel(id)
            removeResumeData(id)
        }
        try? FileManager.default.removeItem(at: directory.appending(path: item.folder))
        written[key] = nil
        changed(key)
    }

    /// „Usuń wszystkie pobrane”; `scope == nil` — wszystkich serwerów.
    public func removeAll(scope: String? = nil) {
        for key in items.values.filter({ scope == nil || $0.scope == scope }).map(\.id) { remove(key: key) }
    }

    /// Nowy stan sieci albo adresu serwera.
    public func setGate(_ newGate: DownloadGate) {
        let old = gate
        guard newGate != old else {
            pump()
            return
        }
        gate = newGate
        switch newGate {
        case .closed(let wait):
            logger.notice("Pobieranie czeka: \(wait.text, privacy: .public)")
            for id in Array(tasks.keys) { suspend(id) }
        case .open(let base, _):
            // Inny adres: dane wznowienia i trwające zadania są związane ze starym.
            for (id, taskBase) in taskBases where !Self.sameServer(taskBase, base) {
                cancel(id)
                requeue(id)
            }
            // Po zmianie sieci warto spróbować także plików, które wyczerpały próby.
            retryNetworkFailures()
        }
        refreshAll()
        pump()
    }

    // MARK: - Zadania

    /// Uruchamia zadania dla wszystkich czekających plików aktywnego serwera.
    public func pump() {
        guard attached, case .open(let base, let allowsCellular) = gate, let scope = activeScope, let token = authorization?() else { return }
        let now = Date.now
        var nextRetry: Date?
        for item in items.values.sorted(by: { $0.addedAt < $1.addedAt }) where item.scope == scope && !item.isPaused {
            for file in item.files where file.state == .queued {
                let id = DownloadTaskID(itemKey: item.id, ino: file.ino)
                guard tasks[id] == nil else { continue }
                if let due = retryAt[id], due > now {
                    nextRetry = min(nextRetry ?? due, due)
                    continue
                }
                retryAt[id] = nil
                let task: URLSessionDownloadTask
                if let resume = loadResumeData(id), Self.sameServer(resume.base, base) {
                    task = session.downloadTask(withResumeData: resume.data)
                } else {
                    var request = URLRequest(url: base.appending(path: "api/items/\(item.itemID)/file/\(file.ino)/download"))
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.allowsCellularAccess = allowsCellular
                    task = session.downloadTask(with: request)
                }
                removeResumeData(id)
                task.taskDescription = id.description
                tasks[id] = task
                taskBases[id] = base
                setFileState(id, .downloading)
                task.resume()
            }
        }
        scheduleRetry(at: nextRetry)
        persist()
    }

    private func scheduleRetry(at date: Date?) {
        retryTimer?.cancel()
        guard let date else { return }
        retryTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, date.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.pump()
        }
    }

    /// Wstrzymuje zadanie z danymi wznowienia (plik wraca do kolejki).
    private func suspend(_ id: DownloadTaskID) {
        guard let task = tasks.removeValue(forKey: id) else { return }
        let base = taskBases.removeValue(forKey: id)
        intentional.insert(id)
        requeue(id)
        task.cancel(byProducingResumeData: { [weak self] data in
            guard let data, let base else { return }
            Task { @MainActor in self?.saveResumeData(data, base: base, for: id) }
        })
    }

    private func cancel(_ id: DownloadTaskID) {
        guard let task = tasks.removeValue(forKey: id) else { return }
        taskBases[id] = nil
        intentional.insert(id)
        task.cancel()
    }

    private func requeue(_ id: DownloadTaskID) {
        guard let file = items[id.itemKey]?.files.first(where: { $0.ino == id.ino }), file.state == .downloading else { return }
        setFileState(id, .queued)
    }

    private func retryNetworkFailures() {
        for (key, item) in items {
            var changedAny = false
            var copy = item
            for index in copy.files.indices where copy.files[index].attempts >= DownloadIndex.maxAutomaticAttempts {
                if case .failed = copy.files[index].state {
                    copy.files[index].state = .queued
                    copy.files[index].attempts = 0
                    changedAny = true
                }
            }
            if changedAny {
                items[key] = copy
                changed(key)
            }
        }
    }

    /// Po ponownym uruchomieniu: zadania, które sesja prowadziła dalej, wracają pod swoje pliki;
    /// pliki „w trakcie” bez zadania — do kolejki. Potem spójność z dyskiem.
    private func attachRunningTasks() async {
        let running = await session.allTasks
        var runningIDs: Set<String> = []
        for task in running {
            guard let text = task.taskDescription, let id = DownloadTaskID(text), let download = task as? URLSessionDownloadTask,
                  items[id.itemKey]?.files.contains(where: { $0.ino == id.ino && $0.state != .done }) == true else {
                task.cancel()
                continue
            }
            tasks[id] = download
            if let url = download.originalRequest?.url ?? download.currentRequest?.url, let base = Self.base(of: url) { taskBases[id] = base }
            runningIDs.insert(text)
            setFileState(id, .downloading)
        }
        reconcileWithDisk(running: runningIDs)
        attached = true
        logger.notice("Pobieranie: \(self.items.count) pozycji, \(running.count) zadań w sesji")
        refreshAll()
        pump()
    }

    /// Spójność indeksu i plików na dysku (po awarii, po wyczyszczeniu przez system).
    private func reconcileWithDisk(running: Set<String>) {
        let fm = FileManager.default
        var disk: [String: [String: Int64]] = [:]
        let folders = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard !folder.lastPathComponent.hasPrefix(".") else { continue }
            var files: [String: Int64] = [:]
            for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                files[file.lastPathComponent] = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            disk[folder.lastPathComponent] = files
        }
        let result = DownloadIndex.reconcile(Array(items.values), disk: disk, runningFiles: running)
        for orphan in result.orphans {
            logger.notice("Usuwam plik bez wpisu w indeksie")
            try? fm.removeItem(at: directory.appending(path: orphan))
        }
        let fixed = Dictionary(result.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if fixed != items {
            logger.notice("Indeks pobranych poprawiony po sprawdzeniu dysku")
            items = fixed
            revision += 1
        }
        persist()
    }

    // MARK: - Zdarzenia sesji

    private func finished(_ id: DownloadTaskID, location: URL, response: URLResponse?) {
        handled.insert(id)
        tasks[id] = nil
        taskBases[id] = nil
        guard let item = items[id.itemKey], let file = item.files.first(where: { $0.ino == id.ino }) else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            switch status {
            case 401: setFileState(id, .failed("Serwer odrzucił klucz tego telefonu."))
            case 403: setFileState(id, .failed("Konto nie ma uprawnienia do pobierania (ustawienia użytkownika na serwerze)."))
            case 404: setFileState(id, .failed("Pliku nie ma już na serwerze."))
            default: failedAttempt(id, reason: "Serwer odpowiedział błędem HTTP \(status).")
            }
            return
        }
        let target = fileURL(item, file)
        do {
            let size = Int64((try location.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            if let expected = file.expectedSize, expected > 0, size != expected {
                failedAttempt(id, reason: "Plik dotarł niekompletny (\(size) z \(expected) B).")
                return
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: location, to: target)
            var target = target
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? target.setResourceValues(values)
            update(id.itemKey) { item in
                guard let index = item.files.firstIndex(where: { $0.ino == id.ino }) else { return }
                item.files[index].state = .done
                item.files[index].attempts = 0
                if item.files[index].expectedSize == nil { item.files[index].expectedSize = size }
                if item.isComplete { item.completedAt = .now }
            }
            written[id.itemKey]?[id.ino] = nil
            if items[id.itemKey]?.isComplete == true { logger.notice("Pozycja pobrana w całości") }
        } catch {
            setFileState(id, .failed("Nie udało się zapisać pliku: \(error.localizedDescription)"))
        }
    }

    private func completed(_ id: DownloadTaskID, error: (any Error)?) {
        if intentional.remove(id) != nil { return }
        if handled.remove(id) != nil { return }
        tasks[id] = nil
        let base = taskBases.removeValue(forKey: id)
        guard let error else { return }
        let nsError = error as NSError
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, let base {
            saveResumeData(data, base: base, for: id)
        }
        logger.error("Pobieranie pliku: \(error.localizedDescription, privacy: .public)")
        if AddressSelection.isConnectionError(error) { onConnectionError?() }
        failedAttempt(id, reason: Self.reason(for: nsError))
    }

    /// Błąd, który ponawianie może naprawić: plik wraca do kolejki z odstępem; po wyczerpaniu prób — błąd.
    private func failedAttempt(_ id: DownloadTaskID, reason: String) {
        var attempts = 0
        update(id.itemKey) { item in
            guard let index = item.files.firstIndex(where: { $0.ino == id.ino }) else { return }
            item.files[index].attempts += 1
            attempts = item.files[index].attempts
            item.files[index].state = attempts >= DownloadIndex.maxAutomaticAttempts ? .failed(reason) : .queued
        }
        if attempts < DownloadIndex.maxAutomaticAttempts {
            retryAt[id] = .now.addingTimeInterval(TimeInterval(DownloadIndex.retryDelay(attempts: attempts).components.seconds))
            pump()
        }
    }

    nonisolated static func reason(for error: NSError) -> String {
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return "Brak sieci."
            case NSURLErrorTimedOut: return "Serwer nie odpowiada."
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost: return "Nie można połączyć się z serwerem."
            default: break
            }
        }
        return error.localizedDescription
    }

    private func progress(_ id: DownloadTaskID, written bytes: Int64) {
        written[id.itemKey, default: [:]][id.ino] = bytes
        let now = Date.now
        if let last = lastProgress[id.itemKey], now.timeIntervalSince(last) < Self.progressInterval { return }
        lastProgress[id.itemKey] = now
        refresh(id.itemKey)
    }

    // MARK: - Stan

    private func setFileState(_ id: DownloadTaskID, _ state: DownloadedFile.State) {
        update(id.itemKey) { item in
            guard let index = item.files.firstIndex(where: { $0.ino == id.ino }) else { return }
            item.files[index].state = state
        }
    }

    private func update(_ key: String, _ change: (inout DownloadedItem) -> Void) {
        guard var item = items[key] else { return }
        let before = item
        change(&item)
        guard item != before else { return }
        items[key] = item
        changed(key)
    }

    /// Zmiana stanu pozycji: zapis indeksu, listy i jej wpis.
    private func changed(_ key: String) {
        revision += 1
        persist()
        refresh(key)
    }

    private func refresh(_ key: String) {
        guard let entry = entries[key] else { return }
        let status = status(of: key)
        if entry.status != status { entry.status = status }
    }

    private func refreshAll() {
        for key in entries.keys { refresh(key) }
    }

    private func persist() {
        guard let indexURL else { return }
        do {
            let data = try JSONEncoder().encode(items.values.sorted { $0.id < $1.id })
            try data.write(to: indexURL, options: [.atomic])
        } catch {
            logger.error("Zapis indeksu pobranych: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func prepareDirectory() {
        var directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    // MARK: - Dane wznowienia (na dysku: przeżywają zamknięcie aplikacji)

    private struct ResumeEntry: Codable {
        let base: URL
        let data: Data
    }

    private var resumeDirectory: URL { directory.appending(path: ".resume") }

    private func resumeFile(_ id: DownloadTaskID) -> URL {
        resumeDirectory.appending(path: DownloadedItem.folderName(for: id.description) + ".json")
    }

    private func saveResumeData(_ data: Data, base: URL, for id: DownloadTaskID) {
        guard items[id.itemKey] != nil, let encoded = try? JSONEncoder().encode(ResumeEntry(base: base, data: data)) else { return }
        try? encoded.write(to: resumeFile(id), options: .atomic)
    }

    private func loadResumeData(_ id: DownloadTaskID) -> ResumeEntry? {
        guard let data = try? Data(contentsOf: resumeFile(id)) else { return nil }
        return try? JSONDecoder().decode(ResumeEntry.self, from: data)
    }

    private func removeResumeData(_ id: DownloadTaskID) {
        try? FileManager.default.removeItem(at: resumeFile(id))
    }

    // MARK: - Adresy

    /// Ten sam serwer pod tym samym adresem (schemat, host, port, ścieżka bazowa).
    nonisolated static func sameServer(_ a: URL, _ b: URL) -> Bool {
        a.scheme == b.scheme && a.host() == b.host() && a.port == b.port && a.path().trimmingSuffix("/") == b.path().trimmingSuffix("/")
    }

    /// Adres bazowy z adresu pliku (`…/api/items/…`).
    nonisolated static func base(of url: URL) -> URL? {
        let text = url.absoluteString
        guard let range = text.range(of: "/api/items/") else { return nil }
        return URL(string: String(text[..<range.lowerBound]))
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let text = downloadTask.taskDescription, let id = DownloadTaskID(text) else { return }
        let response = downloadTask.response
        // Plik trzeba przenieść przed powrotem z tej metody — delegat jest na głównej kolejce.
        MainActor.assumeIsolated { finished(id, location: location, response: response) }
    }

    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let text = downloadTask.taskDescription, let id = DownloadTaskID(text) else { return }
        MainActor.assumeIsolated { progress(id, written: totalBytesWritten) }
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let text = task.taskDescription, let id = DownloadTaskID(text) else { return }
        MainActor.assumeIsolated { completed(id, error: error) }
    }

    nonisolated public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            backgroundEventsCompletion?()
            backgroundEventsCompletion = nil
        }
    }
}
