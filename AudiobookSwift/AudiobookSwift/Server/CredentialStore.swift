import Foundation
import Security

/// Dane logowania konta root w pęku kluczy użytkownika (ogólne hasło, JSON z nazwą i hasłem).
///
/// Używamy klasycznego pęku kluczy logowania, a nie „data protection keychain”: ten drugi
/// wymaga podpisu z zespołem deweloperskim, a aplikacja jest na razie podpisywana ad hoc.
/// Skutek uboczny podpisu ad hoc: po każdym przebudowaniu macOS pyta raz o zgodę na odczyt.
struct CredentialStore: Sendable {
    let service: String
    let account: String

    struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "kod \(status)"
            return "Błąd pęku kluczy: \(detail)"
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// `nil` oznacza wyłącznie brak pozycji. Odmowa dostępu i inne błędy są zgłaszane,
    /// żeby nie wziąć ich za „brak konta” i nie próbować zakładać go od nowa.
    func load() throws -> AudiobookshelfClient.Credentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let credentials = try? JSONDecoder().decode(AudiobookshelfClient.Credentials.self, from: data) else {
                throw KeychainError(status: errSecDecode)
            }
            return credentials
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func save(_ credentials: AudiobookshelfClient.Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "AudiobookSwift — konto root audiobookshelf"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Losowe hasło: 32 znaki alfanumeryczne (ok. 185 bitów).
    static func generatePassword() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<32).map { _ in alphabet.randomElement(using: &generator)! })
    }
}
