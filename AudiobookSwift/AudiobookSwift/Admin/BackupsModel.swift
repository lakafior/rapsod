import AudiobookshelfKit
import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Admin")

/// Kopie zapasowe serwera i ustawienia ich automatu (podstrona „Kopie zapasowe”), na tokenie root.
/// Żyje razem z podstroną.
@MainActor
@Observable
final class BackupsModel {
    enum Operation: Equatable {
        case creating
        case uploading
        case restoring(String)
        case deleting(String)
        case savingSettings
        case changingPath
    }

    private let account: ServerAccount

    private(set) var backups: [AudiobookshelfClient.Backup] = []
    private(set) var location: String?
    private(set) var locationFromEnvironment = false
    /// Ustawienia automatu z serwera (do porównania ze szkicem w widoku).
    private(set) var settings: AudiobookshelfClient.BackupSettings?
    private(set) var isLoading = false
    private(set) var operation: Operation?
    var error: String?
    /// Komunikat po udanej operacji (np. po przywróceniu).
    var notice: String?

    init(account: ServerAccount) {
        self.account = account
    }

    var isAvailable: Bool { account.state == .ready }

    func load() async {
        guard isAvailable else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await account.withAdminToken { try await $0.backups(token: $1) }
            apply(list.backups)
            location = list.backupLocation
            locationFromEnvironment = list.backupPathEnvSet ?? false
            settings = try await account.withAdminToken { try await $0.backupSettings(token: $1) }
        } catch {
            self.error = ItemManager.message(for: error, action: "Nie udało się wczytać kopii zapasowych")
        }
    }

    private func apply(_ list: [AudiobookshelfClient.Backup]) {
        backups = list.sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
    }

    private func perform(_ operation: Operation, action: String, _ work: () async throws -> Void) async {
        guard self.operation == nil else { return }
        self.operation = operation
        error = nil
        notice = nil
        defer { self.operation = nil }
        do {
            try await work()
        } catch {
            logger.error("\(action, privacy: .public): \(error.localizedDescription, privacy: .public)")
            self.error = Self.message(for: error, action: action)
        }
    }

    func create() async {
        await perform(.creating, action: "Nie udało się utworzyć kopii") {
            apply(try await account.withAdminToken { try await $0.createBackup(token: $1) })
            notice = "Kopia utworzona."
        }
    }

    func delete(_ backup: AudiobookshelfClient.Backup) async {
        await perform(.deleting(backup.id), action: "Nie udało się usunąć kopii") {
            try await account.withAdminToken { try await $0.deleteBackup(id: backup.id, token: $1) }
            backups.removeAll { $0.id == backup.id }
        }
    }

    func upload(_ file: URL) async {
        await perform(.uploading, action: "Nie udało się wgrać kopii") {
            guard file.pathExtension == "audiobookshelf" else {
                throw ItemManager.ManageError.invalid("Kopia zapasowa audiobookshelf ma rozszerzenie .audiobookshelf.")
            }
            let accessing = file.startAccessingSecurityScopedResource()
            defer { if accessing { file.stopAccessingSecurityScopedResource() } }
            apply(try await account.withAdminToken { try await $0.uploadBackup(file: file, token: $1) })
            notice = "Kopia „\(file.lastPathComponent)” jest na liście — możesz ją przywrócić."
        }
    }

    /// Przywraca kopię i łączy aplikację z serwerem od nowa: baza z kopii ma własne konta,
    /// hasła i biblioteki, więc stare tokeny i stan konta do słuchania nie są już pewne.
    func restore(_ backup: AudiobookshelfClient.Backup) async {
        await perform(.restoring(backup.id), action: "Nie udało się przywrócić kopii") {
            logger.notice("Przywracanie kopii zapasowej \(backup.id, privacy: .public)")
            try await account.withAdminToken { try await $0.applyBackup(id: backup.id, token: $1) }
            await account.reconnect()
            guard account.state == .ready else {
                notice = "Kopia przywrócona. Aplikacja potrzebuje teraz danych konta root — zobacz Ustawienia → Użytkownicy → Administrator serwera."
                return
            }
            await load()
            notice = "Przywrócono stan z \(Self.dateText(backup)). Aplikacja połączyła się z serwerem ponownie."
        }
    }

    func updateSettings(schedule: AudiobookshelfClient.BackupSchedule, backupsToKeep: Int, maxBackupSize: Double) async {
        guard let current = settings else { return }
        await perform(.savingSettings, action: "Nie udało się zapisać ustawień kopii") {
            guard (1...99).contains(backupsToKeep) else {
                throw ItemManager.ManageError.invalid("Liczba kopii musi być od 1 do 99.")
            }
            guard maxBackupSize >= 0 else {
                throw ItemManager.ManageError.invalid("Limit rozmiaru nie może być ujemny.")
            }
            // Tylko zmienione pola: nieznany harmonogram zostaje nietknięty.
            try await account.withAdminToken {
                try await $0.updateBackupSettings(
                    schedule: schedule == current.backupSchedule ? nil : schedule,
                    backupsToKeep: backupsToKeep == current.backupsToKeep ? nil : backupsToKeep,
                    maxBackupSize: maxBackupSize == current.maxBackupSize ? nil : maxBackupSize,
                    token: $1
                )
            }
            settings = try await account.withAdminToken { try await $0.backupSettings(token: $1) }
            notice = "Ustawienia automatu zapisane."
        }
    }

    func changeLocation(to folder: URL) async {
        await perform(.changingPath, action: "Nie udało się zmienić folderu kopii") {
            // Pierwszy odczyt robi aplikacja, żeby ewentualna prośba o dostęp (TCC) dotyczyła jej,
            // a proces `node` odziedziczył zgodę — jak przy dodawaniu biblioteki.
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            try await account.withAdminToken { try await $0.setBackupPath(folder.standardizedFileURL.path, token: $1) }
            await load()
            notice = "Kopie są teraz w „\(folder.path)”."
        }
    }

    static func dateText(_ backup: AudiobookshelfClient.Backup) -> String {
        guard let date = backup.date else { return backup.id }
        // Aplikacja ma tylko lokalizację en, a interfejs jest po polsku.
        return date.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(Locale(identifier: "pl_PL")))
    }

    private static func message(for error: any Error, action: String) -> String {
        if case AudiobookshelfClient.APIError.http(status: 500, let body) = error, body == "Internal Server Error" || body.isEmpty {
            return "\(action): serwer zgłosił błąd. Przy tworzeniu kopii najczęstszą przyczyną jest przekroczony limit rozmiaru kopii (zwiększ go albo ustaw 0 = bez limitu); szczegóły są w logu serwera."
        }
        return ItemManager.message(for: error, action: action)
    }
}

/// Harmonogram automatu w postaci, którą da się wybrać w ustawieniach. Upstream zapisuje cron;
/// wyrażenia, których tu nie da się przedstawić, zostają jako `.custom` i nie są zmieniane.
enum BackupScheduleChoice: Equatable {
    case disabled
    case daily(hour: Int, minute: Int)
    /// `weekday` jak w cron: 0 = niedziela.
    case weekly(weekday: Int, hour: Int, minute: Int)
    case custom(String)

    init(_ schedule: AudiobookshelfClient.BackupSchedule) {
        guard case .cron(let expression) = schedule else {
            self = .disabled
            return
        }
        let fields = expression.split(separator: " ").map(String.init)
        guard fields.count == 5, let minute = Int(fields[0]), let hour = Int(fields[1]),
              (0...59).contains(minute), (0...23).contains(hour), fields[2] == "*", fields[3] == "*"
        else {
            self = .custom(expression)
            return
        }
        if fields[4] == "*" {
            self = .daily(hour: hour, minute: minute)
        } else if let weekday = Int(fields[4]), (0...7).contains(weekday) {
            self = .weekly(weekday: weekday % 7, hour: hour, minute: minute)
        } else {
            self = .custom(expression)
        }
    }

    var schedule: AudiobookshelfClient.BackupSchedule {
        switch self {
        case .disabled: .disabled
        case .daily(let hour, let minute): .cron("\(minute) \(hour) * * *")
        case .weekly(let weekday, let hour, let minute): .cron("\(minute) \(hour) * * \(weekday)")
        case .custom(let expression): .cron(expression)
        }
    }
}
