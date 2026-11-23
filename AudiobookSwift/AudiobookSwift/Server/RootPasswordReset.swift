import AudiobookshelfKit
import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "RootReset")

/// Reset hasła konta root, gdy nikt go nie zna (decyzja z części 9 planu, etap 2c). Audiobookshelf
/// nie ma resetu przez API, więc aplikacja, która zarządza serwerem:
///
/// 1. zatrzymuje serwer i blokuje jego start (`ServerSupervisor.isMaintenanceLocked`),
/// 2. kopiuje bazę do `<folder danych>/root-password-reset/<data>/` (pliki 0600) i zapisuje
///    znacznik operacji `in-progress.json`,
/// 3. dołączonym Node z bibliotekami serwera (`dist-server/server/libs/bcryptjs`, koszt 8 jak
///    `LocalAuthStrategy.hashPassword`, i `node_modules/sqlite3`) zmienia `pash` konta `type = 'root'`
///    w tabeli `users`, w jednej transakcji, i sprawdza zapis `bcrypt.compare`,
/// 4. zapisuje nowe hasło w pęku kluczy i usuwa znacznik (punkt zatwierdzenia),
/// 5. uruchamia serwer i czeka, aż aplikacja zaloguje się nowym hasłem.
///
/// Przy błędzie przed punktem zatwierdzenia baza wraca z kopii, a serwer startuje jak wcześniej.
/// Gdy aplikacja zginie w trakcie, `recoverIfNeeded` przy następnym starcie sprawdza, czy hasło
/// z pęku kluczy pasuje do bazy: pasuje — reset się udał; nie — baza wraca z kopii. Inne konta,
/// ich sesje i klucze API (telefony) nie są ruszane: zmienia się tylko jedna kolumna jednego wiersza,
/// a sekret podpisu tokenów (`tokenSecret`) zostaje ten sam. Hasło trafia do Node przez stdin.
@MainActor
@Observable
final class RootPasswordReset {
    enum Phase: Equatable {
        case idle
        case running(String)
        case finished(username: String, password: String, backup: URL)
        case failed(String, backup: URL?)
    }

    private(set) var phase: Phase = .idle

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Zamyka arkusz wyniku; hasło znika z pamięci tego obiektu.
    func dismiss() {
        guard !isRunning else { return }
        phase = .idle
    }

    enum ResetError: LocalizedError {
        case noEnvironment
        case database(String)
        case keychain(String)
        case serverDidNotStart

        var errorDescription: String? {
            switch self {
            case .noEnvironment: "Nie znaleziono serwera ani folderu danych."
            case .database(let detail): "Nie udało się zmienić hasła w bazie serwera: \(detail)"
            case .keychain(let detail): "Nie udało się zapisać nowego hasła w pęku kluczy: \(detail)"
            case .serverDidNotStart: "Serwer nie wrócił po resecie w ciągu 90 sekund. Sprawdź stan w Ustawieniach → Ogólne."
            }
        }
    }

    // MARK: - Reset

    func run(supervisor: ServerSupervisor, account: ServerAccount) async {
        guard !isRunning else { return }
        guard let environment = (try? ServerEnvironment.resolve()) ?? supervisor.environment else {
            phase = .failed(ResetError.noEnvironment.localizedDescription, backup: nil)
            return
        }
        let files = Files(dataRoot: environment.dataRoot)
        logger.notice("Reset hasła roota: start")
        phase = .running("Zatrzymywanie serwera…")
        supervisor.isMaintenanceLocked = true
        await supervisor.stop()

        var backup: URL?
        var committed = false
        do {
            phase = .running("Kopia bazy…")
            let made = try files.makeBackup()
            backup = made
            try files.writeMarker(backup: made)
            try await Self.pause("before")

            phase = .running("Zmiana hasła w bazie…")
            let password = PasswordGenerator.generate()
            let username = try await Self.runHelper(.reset, password: password, environment: environment, database: files.database)
            try await Self.pause("after")

            phase = .running("Zapis w pęku kluczy…")
            do {
                try ServerAccount.rootStore(dataRoot: environment.dataRoot)
                    .save(AudiobookshelfClient.Credentials(username: username, password: password))
            } catch {
                throw ResetError.keychain(error.localizedDescription)
            }
            // Punkt zatwierdzenia: od teraz baza i pęk kluczy zgadzają się na nowym haśle.
            files.removeMarker()
            committed = true
            logger.notice("Reset hasła roota: zatwierdzony")

            phase = .running("Uruchamianie serwera i logowanie…")
            supervisor.isMaintenanceLocked = false
            supervisor.start()
            try await Self.waitForLogin(account)
            phase = .finished(username: username, password: password, backup: made)
        } catch {
            logger.error("Reset hasła roota: \(error.localizedDescription, privacy: .public)")
            if !committed, let backup {
                do {
                    try files.restore(from: backup)
                    logger.notice("Reset hasła roota: baza przywrócona z kopii")
                    files.removeMarker()
                } catch {
                    // Baza mogła zostać w nieznanym stanie: serwer nie startuje (założyłby pustą bazę
                    // i nowego roota), znacznik zostaje, żeby następny start aplikacji spróbował znowu.
                    logger.fault("Reset hasła roota: przywrócenie kopii nie powiodło się: \(error.localizedDescription, privacy: .public)")
                    let message = Self.restoreFailedMessage(backup: backup, error: error)
                    supervisor.blockStart(message)
                    phase = .failed(message, backup: backup)
                    return
                }
            }
            supervisor.isMaintenanceLocked = false
            if !supervisor.hasProcess { supervisor.start() }
            phase = .failed(
                (committed ? "" : "Baza wróciła do stanu sprzed resetu. ") + error.localizedDescription,
                backup: backup
            )
        }
    }

    private static func restoreFailedMessage(backup: URL, error: Error) -> String {
        "Nie udało się przywrócić bazy z kopii (\(error.localizedDescription)). Serwer zostaje zatrzymany, żeby nie założył pustej bazy. Kopia leży w \(backup.path) — zamknij aplikację i skopiuj z niej plik absdatabase.sqlite do folderu config w folderze danych albo uruchom aplikację ponownie, żeby spróbowała jeszcze raz."
    }

    /// Wywoływane przy starcie aplikacji, zanim ruszy serwer: dokańcza albo cofa reset
    /// przerwany przez zamknięcie aplikacji. Zwraca komunikat, gdy serwera nie wolno uruchomić
    /// (przywrócenie kopii się nie udało).
    static func recoverIfNeeded() async -> String? {
        guard let environment = try? ServerEnvironment.resolve() else { return nil }
        let files = Files(dataRoot: environment.dataRoot)
        guard let backup = files.markerBackup() else { return nil }
        logger.notice("Reset hasła roota: znaleziono przerwaną operację")
        var matches = false
        if let stored = try? ServerAccount.rootStore(dataRoot: environment.dataRoot).load() {
            matches = (try? await runHelper(.check, password: stored.password, environment: environment, database: files.database)) != nil
        }
        if matches {
            logger.notice("Reset hasła roota: hasło w pęku kluczy pasuje do bazy — reset zakończony")
        } else {
            do {
                try files.restore(from: backup)
                logger.notice("Reset hasła roota: baza przywrócona z kopii po przerwaniu")
            } catch {
                logger.fault("Reset hasła roota: przywrócenie po przerwaniu nie powiodło się: \(error.localizedDescription, privacy: .public)")
                return restoreFailedMessage(backup: backup, error: error)
            }
        }
        files.removeMarker()
        return nil
    }

    // MARK: - Pliki

    struct Files {
        let dataRoot: URL
        var folder: URL { dataRoot.appending(path: "root-password-reset", directoryHint: .isDirectory) }
        var marker: URL { folder.appending(path: "in-progress.json") }
        var database: URL { dataRoot.appending(path: "config/absdatabase.sqlite") }
        /// Plik bazy i jej ewentualne pliki pomocnicze SQLite.
        private var databaseFiles: [URL] {
            ["", "-wal", "-shm", "-journal"].map { URL(filePath: database.path + $0) }
        }

        func makeBackup() throws -> URL {
            let fm = FileManager.default
            guard fm.fileExists(atPath: database.path) else { throw ResetError.database("brak pliku bazy") }
            let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.standard).timeSeparator(.omitted))
            let target = folder.appending(path: stamp.replacingOccurrences(of: ":", with: ""), directoryHint: .isDirectory)
            try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            for file in databaseFiles where fm.fileExists(atPath: file.path) {
                let copy = target.appending(path: file.lastPathComponent)
                try fm.copyItem(at: file, to: copy)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
            }
            return target
        }

        func writeMarker(backup: URL) throws {
            let data = try JSONEncoder().encode(["backup": backup.path])
            try data.write(to: marker, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        }

        func markerBackup() -> URL? {
            guard let data = try? Data(contentsOf: marker),
                  let object = try? JSONDecoder().decode([String: String].self, from: data),
                  let path = object["backup"] else { return nil }
            return URL(filePath: path, directoryHint: .isDirectory)
        }

        func removeMarker() {
            try? FileManager.default.removeItem(at: marker)
        }

        /// Kładzie z powrotem pliki bazy z kopii. Każdy plik trafia najpierw obok (`.restore`),
        /// a potem atomowo zastępuje bieżący, więc nieudane kopiowanie nie zostawia bazy w połowie
        /// ani bez pliku. Pliki pomocnicze, których w kopii nie było, są usuwane na końcu.
        func restore(from backup: URL) throws {
            let fm = FileManager.default
            guard fm.fileExists(atPath: backup.appending(path: database.lastPathComponent).path) else {
                throw ResetError.database("w kopii nie ma pliku bazy")
            }
            for file in databaseFiles {
                let copy = backup.appending(path: file.lastPathComponent)
                guard fm.fileExists(atPath: copy.path) else { continue }
                let staged = URL(filePath: file.path + ".restore")
                if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
                try fm.copyItem(at: copy, to: staged)
                if fm.fileExists(atPath: file.path) {
                    _ = try fm.replaceItemAt(file, withItemAt: staged)
                } else {
                    try fm.moveItem(at: staged, to: file)
                }
            }
            for file in databaseFiles where !fm.fileExists(atPath: backup.appending(path: file.lastPathComponent).path) {
                if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            }
        }
    }

    // MARK: - Node

    private enum HelperMode: String {
        case reset
        case check
    }

    /// Skrypt dla dołączonego Node: biblioteki bierze z serwera, hasło czyta ze stdin, nic
    /// poza nazwą konta nie wypisuje. `check` kończy się kodem 3, gdy hasło nie pasuje.
    private static let helperScript = #"""
    const path = require('path')
    const [serverRoot, dbPath, mode] = process.argv.slice(1)
    const bcrypt = require(path.join(serverRoot, 'dist-server', 'server', 'libs', 'bcryptjs'))
    const sqlite3 = require(path.join(serverRoot, 'node_modules', 'sqlite3'))
    let input = ''
    process.stdin.setEncoding('utf8')
    process.stdin.on('data', (c) => { input += c })
    process.stdin.on('end', () => {
      const password = input.replace(/\n$/, '')
      const fail = (code, message) => { process.stderr.write(message + '\n'); process.exit(code) }
      if (!password) fail(2, 'puste hasło')
      const db = new sqlite3.Database(dbPath, mode === 'check' ? sqlite3.OPEN_READONLY : sqlite3.OPEN_READWRITE, (err) => {
        if (err) fail(2, 'otwarcie bazy: ' + err.message)
        db.all("SELECT id, username, pash FROM users WHERE type = 'root'", (err, rows) => {
          if (err) fail(2, 'odczyt kont: ' + err.message)
          if (rows.length !== 1) fail(2, 'kont root w bazie: ' + rows.length)
          const root = rows[0]
          if (mode === 'check') {
            const ok = !!root.pash && bcrypt.compareSync(password, root.pash)
            db.close(() => { if (!ok) process.exit(3); process.stdout.write(JSON.stringify({ username: root.username })); process.exit(0) })
            return
          }
          const hash = bcrypt.hashSync(password, 8)
          db.serialize(() => {
            db.run('BEGIN IMMEDIATE')
            db.run("UPDATE users SET pash = ? WHERE id = ? AND type = 'root'", [hash, root.id], function (err) {
              if (err || this.changes !== 1) { db.run('ROLLBACK'); fail(2, 'zapis: ' + (err ? err.message : 'zmienione wiersze ' + this.changes)) }
            })
            db.get('SELECT pash FROM users WHERE id = ?', [root.id], (err, row) => {
              if (err || !row || !bcrypt.compareSync(password, row.pash)) { db.run('ROLLBACK'); fail(2, 'sprawdzenie zapisu') }
              db.run('COMMIT', (err) => {
                if (err) fail(2, 'zatwierdzenie: ' + err.message)
                db.close(() => { process.stdout.write(JSON.stringify({ username: root.username })); process.exit(0) })
              })
            })
          })
        })
      })
    })
    """#

    /// Uruchamia skrypt i zwraca nazwę konta root. Rzuca przy każdym niepowodzeniu (także
    /// przy niepasującym haśle w trybie `check`).
    private static func runHelper(_ mode: HelperMode, password: String, environment: ServerEnvironment, database: URL) async throws -> String {
        let process = Process()
        process.executableURL = environment.node
        process.arguments = ["-e", helperScript, environment.serverRoot.path, database.path, mode.rawValue]
        process.currentDirectoryURL = environment.dataRoot
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ResetError.database("nie udało się uruchomić Node: \(error.localizedDescription)"))
                return
            }
            input.fileHandleForWriting.write(Data(password.utf8))
            try? input.fileHandleForWriting.close()
        }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0,
              let object = try? JSONSerialization.jsonObject(with: out) as? [String: String],
              let username = object["username"] else {
            throw ResetError.database(status == 3 ? "hasło nie pasuje" : (err.isEmpty ? "kod \(status)" : err))
        }
        return username
    }

    // MARK: - Pomocnicze

    private static func waitForLogin(_ account: ServerAccount) async throws {
        let deadline = ContinuousClock.now + .seconds(90)
        while account.state != .ready {
            guard ContinuousClock.now < deadline else { throw ResetError.serverDidNotStart }
            // Po zatrzymaniu serwera stan to `.disconnected`, więc `.needsPassword` znaczy, że nowe hasło nie przeszło.
            if case .needsPassword = account.state { throw ResetError.database("serwer nie przyjął nowego hasła") }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Tylko do testów na testowej kopii: `-ABSRootResetPause before|after` zatrzymuje
    /// reset na 30 s przed albo po zapisie w bazie, żeby można było zabić aplikację.
    /// `-ABSRootResetFail after` udaje błąd po zapisie w bazie (sprawdzenie przywracania z kopii).
    private static func pause(_ point: String) async throws {
        if UserDefaults.standard.string(forKey: "ABSRootResetFail") == point {
            throw ResetError.database("błąd wymuszony do testu (-ABSRootResetFail)")
        }
        guard UserDefaults.standard.string(forKey: "ABSRootResetPause") == point else { return }
        logger.notice("Reset hasła roota: pauza testowa (\(point, privacy: .public))")
        print("RESET PAUSE \(point)")
        fflush(stdout)
        try await Task.sleep(for: .seconds(30))
    }
}
