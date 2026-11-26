import AppKit
import Foundation
import Observation
import RapsodUpdates

/// Automatyczne aktualizacje z GitHub Releases (etap 14b), bez zewnętrznych bibliotek.
///
/// Sprawdza `/releases/latest` przy starcie i raz na dobę (gdy włączone w Ogólne › Aplikacja)
/// albo na żądanie z menu. Nowa wersja otwiera okno „Aktualizacja”; „Zainstaluj i uruchom
/// ponownie” pobiera obraz dysku, weryfikuje go (`UpdateVerifier`), kopiuje aplikację obok
/// bieżącej i kończy Rapsod jak zwykłe „Zakończ” (serwer, tunel i źródła metadanych zatrzymane).
/// Tuż przed wyjściem `applicationWillTerminate` uruchamia `SwapScript`, który po zakończeniu
/// procesu podmienia pakiet i otwiera aplikację ponownie.
@MainActor @Observable
final class UpdateController {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppUpdate)
        /// Postęp 0…1, `nil` przed pierwszym bajtem.
        case downloading(AppUpdate, Double?)
        case verifying(AppUpdate)
        /// Kopia zweryfikowana, aplikacja się kończy.
        case installing(AppUpdate)
        case failed(String)
    }

    /// Adres API wydań. Repozytorium musi być publiczne — anonimowe API nie widzi prywatnych.
    static let defaultFeedURL = URL(string: "https://api.github.com/repos/lakafior/rapsod/releases/latest")!

    private(set) var phase: Phase = .idle
    /// Nowsza wersja znaleziona przy ostatnim sprawdzeniu (oznaczenie w menu), także po
    /// „Przypomnij później”; po „Pomiń tę wersję” znika.
    private(set) var pending: AppUpdate?
    private(set) var lastCheck: Date?
    /// Rośnie, gdy okno aktualizacji ma się otworzyć samo (obserwuje to ikona w pasku menu).
    private(set) var windowRequest = 0
    /// Punkt zaczepienia dla powiadomień systemowych (etap 14e): wywoływany raz na wersję,
    /// gdy automatyczne sprawdzenie znajdzie nowszą wersję do pokazania.
    var onUpdateFound: ((AppUpdate) -> Void)?

    var automaticChecks: Bool {
        didSet { defaults.set(automaticChecks, forKey: Keys.automatic) }
    }

    let currentVersion: AppVersion
    private let defaults = UserDefaults.standard
    private var schedule: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var stagedApp: URL?
    private var announcedVersion: AppVersion?

    private enum Keys {
        static let automatic = "updates.automaticChecks"
        static let lastCheck = "updates.lastCheck"
        static let skipped = "updates.skippedVersion"
        static let remindAfter = "updates.remindAfter"
        /// Tylko do testów: inne źródło odpowiedzi API (`-RapsodUpdateFeedURL http://127.0.0.1:…`).
        /// Weryfikacja pobranej wersji jest taka sama.
        static let feedOverride = "RapsodUpdateFeedURL"
    }

    init() {
        defaults.register(defaults: [Keys.automatic: true])
        automaticChecks = defaults.bool(forKey: Keys.automatic)
        lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        currentVersion = AppVersion(short) ?? AppVersion("0")!
    }

    var feedURL: URL {
        if let text = defaults.string(forKey: Keys.feedOverride), let url = URL(string: text),
           url.scheme == "https" || url.scheme == "http" {
            return url
        }
        return Self.defaultFeedURL
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .verifying, .installing: true
        case .idle, .upToDate, .available, .failed: false
        }
    }

    // MARK: Harmonogram

    /// Sprawdzenie przy starcie (po chwili, żeby nie konkurować ze startem serwera), potem co godzinę
    /// pytanie, czy minęła doba od ostatniego.
    func activate() {
        guard schedule == nil else { return }
        // Kopia z przerwanej instalacji (np. awaria przed wyjściem) — przy następnej i tak powstanie od nowa.
        try? FileManager.default.removeItem(at: SwapScript.stagedURL(for: Bundle.main.bundleURL))
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                if self.automaticChecks, first || UpdatePolicy.isCheckDue(lastCheck: self.lastCheck, now: .now) {
                    await self.check(userInitiated: false)
                }
                first = false
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    // MARK: Sprawdzanie

    /// Ręczne sprawdzenie z menu: okno pokazuje wynik, także „masz najnowszą wersję” i błędy.
    func checkFromMenu() {
        guard !isBusy else { return }
        work = Task { await check(userInitiated: true) }
    }

    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        let previous = phase
        if userInitiated { phase = .checking }
        do {
            let update = try await fetchLatest()
            lastCheck = .now
            defaults.set(lastCheck, forKey: Keys.lastCheck)
            guard let update else {
                pending = nil
                phase = userInitiated ? .upToDate : idleAfterQuietCheck(previous)
                return
            }
            let verdict = UpdatePolicy.verdict(
                for: update.version,
                current: currentVersion,
                userInitiated: userInitiated,
                skippedVersion: defaults.string(forKey: Keys.skipped),
                remindAfter: defaults.object(forKey: Keys.remindAfter) as? Date,
                now: .now
            )
            switch verdict {
            case .upToDate:
                pending = nil
                phase = userInitiated ? .upToDate : idleAfterQuietCheck(previous)
            case .quiet:
                let skipped = defaults.string(forKey: Keys.skipped).flatMap(AppVersion.init)
                pending = skipped == update.version ? nil : update
                phase = idleAfterQuietCheck(previous)
            case .present:
                pending = update
                phase = .available(update)
                if !userInitiated {
                    windowRequest += 1
                    if announcedVersion != update.version {
                        announcedVersion = update.version
                        onUpdateFound?(update)
                    }
                }
            }
        } catch {
            NSLog("Aktualizacje: %@", error.localizedDescription)
            phase = userInitiated ? .failed(error.localizedDescription) : idleAfterQuietCheck(previous)
        }
    }

    /// Ciche sprawdzenie w tle nie przerywa tego, co okno akurat pokazuje.
    private func idleAfterQuietCheck(_ previous: Phase) -> Phase {
        if case .available = previous { return previous }
        return previous == .checking ? .idle : previous
    }

    /// Najnowsze wydanie albo `nil`, gdy repozytorium nie ma żadnego.
    private func fetchLatest() async throws -> AppUpdate? {
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Rapsod/\(currentVersion.string)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 404: return nil
        case 403, 429:
            throw UpdateError(String(localized: "GitHub chwilowo ogranicza liczbę zapytań. Spróbuj ponownie za godzinę."))
        default:
            throw UpdateError(String(localized: "Serwer wydań odpowiedział kodem \(status)."))
        }
        let release: GitHubRelease
        do {
            release = try GitHubRelease.decode(data)
        } catch {
            throw UpdateError(String(localized: "Nie udało się odczytać odpowiedzi serwera wydań."))
        }
        do {
            return try AppUpdate(release: release)
        } catch .draftOrPrerelease {
            return nil
        } catch {
            throw UpdateError(String(localized: "Najnowsze wydanie (\(release.tagName)) nie ma obrazu dysku z sumą SHA-256 — nie da się go zainstalować automatycznie."))
        }
    }

    // MARK: Decyzje z okna

    /// Ponowne pokazanie wersji oznaczonej w menu (po „Przypomnij później”).
    func showAvailable(_ update: AppUpdate) {
        guard !isBusy else { return }
        phase = .available(update)
    }

    func remindLater() {
        defaults.set(Date.now.addingTimeInterval(UpdatePolicy.remindInterval), forKey: Keys.remindAfter)
        if case .available = phase { phase = .idle }
    }

    func skip(_ update: AppUpdate) {
        defaults.set(update.version.string, forKey: Keys.skipped)
        if pending?.version == update.version { pending = nil }
        if case .available = phase { phase = .idle }
    }

    /// Zamknięcie okna z wynikiem, który nie wymaga decyzji, czyści go do następnego razu.
    func windowClosed() {
        switch phase {
        case .upToDate, .failed: phase = .idle
        default: break
        }
    }

    // MARK: Instalacja

    func install(_ update: AppUpdate) {
        guard !isBusy else { return }
        work = Task { await download(update) }
    }

    func cancelDownload() {
        work?.cancel()
    }

    private func download(_ update: AppUpdate) async {
        let app = Bundle.main.bundleURL
        if let problem = InstallLocation.problem(for: app) {
            phase = .failed(problem)
            return
        }
        guard let teamID = UpdateVerifier.runningTeamID() else {
            phase = .failed(String(localized: "Ta kopia Rapsodu nie ma podpisu z identyfikatorem zespołu (build deweloperski?), więc nie da się sprawdzić, czy nowa wersja pochodzi od tego samego wydawcy."))
            return
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "RapsodUpdate-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            phase = .downloading(update, nil)
            let checksumText = try await fetchText(update.checksum.downloadURL)
            guard let expected = ChecksumFile.sha256(for: update.diskImage.name, in: checksumText) else {
                throw UpdateError(String(localized: "Plik sumy kontrolnej wydania nie zawiera sumy dla \(update.diskImage.name)."))
            }
            let image = folder.appending(path: update.diskImage.name)
            try await downloadFile(update.diskImage.downloadURL, to: image) { [weak self] fraction in
                self?.phase = .downloading(update, fraction)
            }
            try Task.checkCancellation()

            phase = .verifying(update)
            let staged = try await verifyAndStage(image: image, expectedHash: expected, update: update, teamID: teamID, folder: folder, app: app)
            stagedApp = staged
            phase = .installing(update)
            // Chwila na pokazanie stanu w oknie, potem zwykłe pełne zakończenie aplikacji.
            try? await Task.sleep(for: .milliseconds(600))
            // Nie wprost z zadania: `applicationShouldTerminate` odpowiada `.terminateLater`
            // i AppKit czeka w zagnieżdżonej pętli zdarzeń, a zadania zamykające serwer działają
            // na kolejce głównej, zajętej przez bieżący blok — aplikacja by się zawiesiła.
            // Blok pętli wykonań startuje poza kolejką, jak kliknięcie w menu.
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated { AppQuit.quit() }
            }
        } catch is CancellationError {
            phase = .available(update)
        } catch let error as URLError where error.code == .cancelled {
            phase = .available(update)
        } catch {
            NSLog("Aktualizacje: %@", error.localizedDescription)
            phase = .failed(error.localizedDescription)
        }
    }

    private func verifyAndStage(image: URL, expectedHash: String, update: AppUpdate, teamID: String, folder: URL, app: URL) async throws -> URL {
        let actual = try await Task.detached(priority: .userInitiated) { try UpdateVerifier.sha256(of: image) }.value
        guard actual == expectedHash else {
            throw UpdateError(String(localized: "Suma SHA-256 pobranego pliku nie zgadza się z opublikowaną. Plik mógł zostać uszkodzony albo podmieniony."))
        }
        try UpdateVerifier.checkSignature(of: image, requirement: UpdateVerifier.developerIDRequirement(teamID: teamID), nested: false)
        try await UpdateVerifier.assessDiskImage(image)

        let mountPoint = folder.appending(path: "volume", directoryHint: .isDirectory)
        try await UpdateVerifier.mount(image, at: mountPoint)
        let staged = SwapScript.stagedURL(for: app)
        do {
            let source = mountPoint.appending(path: app.lastPathComponent, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw UpdateError(String(localized: "Obraz dysku nie zawiera \(app.lastPathComponent)."))
            }
            try await UpdateVerifier.copyBundle(from: source, to: staged)
            await UpdateVerifier.detach(mountPoint)
        } catch {
            await UpdateVerifier.detach(mountPoint)
            throw error
        }

        do {
            // Sprawdzenia na kopii, która naprawdę zostanie uruchomiona, nie na zamontowanym obrazie.
            let bundleID = Bundle.main.bundleIdentifier ?? "net.smigi.rapsod"
            try UpdateVerifier.checkSignature(of: staged, requirement: UpdateVerifier.appRequirement(bundleID: bundleID, teamID: teamID), nested: true)
            try await UpdateVerifier.assessApp(staged)
            guard let info = Bundle(url: staged)?.infoDictionary,
                  info["CFBundleIdentifier"] as? String == bundleID,
                  let stagedVersion = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) else {
                throw UpdateError(String(localized: "Nowa wersja ma nieprawidłowe Info.plist."))
            }
            guard stagedVersion == update.version, stagedVersion > currentVersion else {
                throw UpdateError(String(localized: "Pakiet w obrazie dysku ma wersję \(stagedVersion.string) zamiast \(update.version.string)."))
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return staged
    }

    private func fetchText(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError(String(localized: "Nie udało się pobrać pliku sumy kontrolnej."))
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Pobieranie z postępem odczytywanym co 0,2 s z zadania `URLSession`.
    private func downloadFile(_ url: URL, to destination: URL, progress: @escaping @MainActor (Double?) -> Void) async throws {
        let box = DownloadBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                        continuation.resume(throwing: UpdateError(String(localized: "Nie udało się pobrać obrazu dysku.")))
                        return
                    }
                    do {
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: location, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.task = task
                task.resume()
                Task { @MainActor in
                    while task.state == .running || task.state == .suspended {
                        let total = task.countOfBytesExpectedToReceive
                        progress(total > 0 ? Double(task.countOfBytesReceived) / Double(total) : nil)
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    // MARK: Wyjście

    /// Wywoływane z `applicationWillTerminate`: skrypt podmiany startuje tylko wtedy, gdy
    /// zweryfikowana kopia czeka obok aplikacji.
    func launchSwapIfPending() {
        guard let staged = stagedApp, FileManager.default.fileExists(atPath: staged.path) else { return }
        let app = Bundle.main.bundleURL
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appending(path: "Logs/Rapsod", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = SwapScript.arguments(
            pid: ProcessInfo.processInfo.processIdentifier,
            app: app,
            staged: staged,
            backup: SwapScript.backupURL(for: app),
            log: logs.appending(path: "aktualizacja.log"),
            relaunchArguments: Array(CommandLine.arguments.dropFirst())
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("Aktualizacje: nie udało się uruchomić podmiany: %@", error.localizedDescription)
        }
    }
}

/// Zadanie pobierania dostępne dla obsługi anulowania.
private final class DownloadBox: @unchecked Sendable {
    var task: URLSessionDownloadTask?
}
