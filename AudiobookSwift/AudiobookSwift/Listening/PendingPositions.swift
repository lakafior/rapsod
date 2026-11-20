import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Listening")

/// Pozycje, których nie udało się wysłać na serwer (serwer zatrzymany albo chwilowo niedostępny).
///
/// Źródłem prawdy jest serwer; ten plik to tylko bufor: wpis powstaje po nieudanej synchronizacji
/// i znika po udanej. Przy następnym połączeniu wpis trafia na serwer tylko wtedy, gdy jest nowszy
/// niż ostatnia zmiana postępu na serwerze (np. z telefonu). Leży w folderze danych serwera
/// (obok `sharing.json`), więc testowa kopia z `-ABSDataRoot` ma własny.
struct PendingPositions {
    struct Entry: Codable, Equatable {
        let itemID: String
        let episodeID: String?
        let currentTime: Double
        let duration: Double
        let savedAt: Date
    }

    private let url: URL
    private(set) var entries: [String: Entry]

    init(dataRoot: URL) {
        url = dataRoot.appending(path: "listening-pending.json")
        if let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([String: Entry].self, from: data) {
            self.entries = entries
        } else {
            entries = [:]
        }
    }

    subscript(key: String) -> Entry? { entries[key] }

    mutating func set(_ entry: Entry?, for key: String) {
        guard entries[key] != entry else { return }
        entries[key] = entry
        save()
    }

    private func save() {
        do {
            if entries.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            }
        } catch {
            logger.error("Zapis niewysłanej pozycji: \(error.localizedDescription, privacy: .public)")
        }
    }
}
