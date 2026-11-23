import AudiobookshelfKit
import Foundation
import Observation

/// Wąski klient zarządzania pozycją (decyzja użytkownika z etapu 9b2): dopasowanie i edycja
/// idą tokenem konta root (`ServerAccount.withAdminToken`), a nie kontem słuchacza.
/// Konto słuchacza — to samo, na które loguje się telefon — zostaje bez prawa edycji,
/// a `ListeningAuth` nigdy nie dostaje tokenu roota. Żyje razem z oknem „Biblioteka”.
@MainActor
@Observable
final class ItemManager {
    private let account: ServerAccount
    /// Dostawcy metadanych serwera (wczytani przy pierwszym otwarciu edycji).
    private(set) var providers: AudiobookshelfClient.SearchProviders?
    /// Osadzanie metadanych i scalanie do M4B (etap 9e).
    let tasks: ItemTasks

    init(account: ServerAccount) {
        self.account = account
        tasks = ItemTasks(account: account)
    }

    /// Edycja jest możliwa, gdy aplikacja ma działające konto root.
    var isAvailable: Bool { account.state == .ready }

    /// Dlaczego edycja jest niedostępna (podpowiedź na wyszarzonym przycisku).
    var unavailableReason: String {
        switch account.state {
        case .needsPassword: "Edycja wymaga konta root — podaj jego hasło w Ustawieniach → Użytkownicy → Administrator serwera."
        case .failed(let message): "Brak połączenia z kontem root: \(message)"
        default: "Konto root nie jest jeszcze połączone."
        }
    }

    func run<T: Sendable>(_ operation: (AudiobookshelfClient, String) async throws -> T) async throws -> T {
        guard isAvailable else { throw ManageError.unavailable(unavailableReason) }
        return try await account.withAdminToken(operation)
    }

    func loadProviders() async throws -> AudiobookshelfClient.SearchProviders {
        if let providers { return providers }
        let loaded = try await run { try await $0.searchProviders(token: $1) }
        providers = loaded
        return loaded
    }

    // MARK: Usunięcie (etap 9e)

    enum DeleteMode {
        /// Tylko z bazy — pliki zostają, a następny skan biblioteki doda pozycję z powrotem.
        case databaseOnly
        /// Aplikacja przenosi folder (albo plik) pozycji do Kosza, potem usuwa ją z bazy.
        case trash
        /// Serwer kasuje pliki trwale (`?hard=1`) — tylko gdy Kosza nie da się użyć.
        case permanent
    }

    /// Kosz niedostępny (np. dysk sieciowy albo brak uprawnień) — widok pyta wtedy o trwałe usunięcie.
    struct TrashUnavailable: LocalizedError {
        let reason: String
        var errorDescription: String? { "Nie udało się przenieść plików do Kosza: \(reason)" }
    }

    /// Usuwa pozycję. Przy `.trash` najpierw Kosz (odwracalne), potem baza; gdy serwer
    /// odmówi, pliki wracają z Kosza na miejsce.
    func delete(itemID: String, path: String?, mode: DeleteMode) async throws {
        var trashed: (original: URL, inTrash: URL)?
        if mode == .trash {
            guard let path else { throw TrashUnavailable(reason: "serwer nie podał ścieżki pozycji.") }
            let original = URL(filePath: path)
            if FileManager.default.fileExists(atPath: path) {
                var result: NSURL?
                do {
                    try FileManager.default.trashItem(at: original, resultingItemURL: &result)
                } catch {
                    throw TrashUnavailable(reason: error.localizedDescription)
                }
                if let inTrash = result as URL? { trashed = (original, inTrash) }
            }
        }
        do {
            try await run { try await $0.deleteItem(id: itemID, hard: mode == .permanent, token: $1) }
        } catch AudiobookshelfClient.APIError.http(404, _) where trashed != nil {
            // Obserwator plików zdążył usunąć pozycję po zniknięciu folderu — o to chodziło.
        } catch {
            if let trashed { try? FileManager.default.moveItem(at: trashed.inTrash, to: trashed.original) }
            throw error
        }
    }

    enum ManageError: LocalizedError {
        case unavailable(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let message), .invalid(let message): message
            }
        }
    }

    /// Czytelny komunikat błędu serwera (upstream odpowiada gołym statusem albo `{"error": …}`).
    static func message(for error: any Error, action: String) -> String {
        switch error {
        case AudiobookshelfClient.APIError.http(let status, let body):
            let detail: String = {
                if let data = body.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = json["error"] as? String { return text }
                // Goły status Expressa („Forbidden”, „Internal Server Error”) nic nie dodaje.
                return ["Forbidden", "Bad Request", "Internal Server Error", "Not Found"].contains(body) ? "" : body
            }()
            let reason = switch status {
            case 403: "brak uprawnień"
            case 404: "pozycja nie istnieje (może została usunięta)"
            case 400: "serwer odrzucił dane"
            default: "błąd serwera (HTTP \(status))"
            }
            return "\(action): \(reason)" + (detail.isEmpty ? "." : " — \(detail)")
        case let error as URLError where error.code == .timedOut:
            return "\(action): serwer nie odpowiedział na czas."
        default:
            return "\(action): \(error.localizedDescription)"
        }
    }
}
