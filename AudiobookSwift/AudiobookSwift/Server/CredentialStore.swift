import Foundation
import Security

/// Sekret w pęku kluczy użytkownika (ogólne hasło, wartość zakodowana jako JSON):
/// dane logowania roota i użytkownika.
///
/// Od etapu 3 aplikacja jest podpisywana zespołem deweloperskim, więc używamy pęku kluczy
/// z ochroną danych (`kSecUseDataProtectionKeychain`): dostęp wynika z podpisu aplikacji,
/// bez pytań o zgodę po przebudowaniu. `legacyService` wskazuje pozycję z klasycznego
/// pęku kluczy logowania (etapy 1–2), przenoszoną przy pierwszym odczycie.
struct CredentialStore<Value: Codable & Sendable & Equatable>: Sendable {
    let service: String
    let account: String
    let label: String
    var legacyService: String?

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// `nil` oznacza wyłącznie brak pozycji. Odmowa dostępu i inne błędy są zgłaszane,
    /// żeby nie wziąć ich za „brak konta” i nie próbować zakładać go od nowa.
    func load() throws -> Value? {
        if let value = try read(baseQuery) {
            return value
        }
        guard let legacyService else { return nil }
        // Jednorazowa migracja: macOS zapyta raz o zgodę na odczyt starej pozycji.
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account,
        ]
        guard let value = try read(legacyQuery) else { return nil }
        try save(value)
        SecItemDelete(legacyQuery as CFDictionary)
        return value
    }

    private func read(_ base: [String: Any]) throws -> Value? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = try? JSONDecoder().decode(Value.self, from: data) else {
                throw KeychainError(status: errSecDecode)
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func save(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = label
        // Aplikacja startuje przy logowaniu, także zanim użytkownik odblokuje ekran po raz drugi.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "kod \(status)"
        return "Błąd pęku kluczy: \(detail)"
    }
}

enum PasswordGenerator {
    /// Losowe hasło: 32 znaki alfanumeryczne (ok. 185 bitów).
    static func generate() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<32).map { _ in alphabet.randomElement(using: &generator)! })
    }
}
