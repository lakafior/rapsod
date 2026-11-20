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

    init(account: ServerAccount) {
        self.account = account
    }

    /// Edycja jest możliwa, gdy aplikacja ma działające konto root.
    var isAvailable: Bool { account.state == .ready }

    /// Dlaczego edycja jest niedostępna (podpowiedź na wyszarzonym przycisku).
    var unavailableReason: String {
        switch account.state {
        case .needsPassword: "Edycja wymaga konta root — podaj jego hasło w Ustawieniach → Konta."
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
