import AudiobookshelfKit
import Foundation
import Security

/// Sekret w pęku kluczy użytkownika (ogólne hasło, wartość zakodowana jako JSON):
/// dane logowania roota i użytkownika.
///
/// Od etapu 3 aplikacja jest podpisywana zespołem deweloperskim, więc używamy pęku kluczy
/// z ochroną danych (`kSecUseDataProtectionKeychain`): dostęp wynika z podpisu aplikacji,
/// bez pytań o zgodę po przebudowaniu.
struct CredentialStore<Value: Codable & Sendable & Equatable>: Sendable {
    let service: String
    let account: String
    let label: String

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
        try read(baseQuery)
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

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// Pęk kluczy Maca jako miejsce na sekrety kont dla kodu wspólnego (`SecretStore` z AudiobookshelfKit).
extension CredentialStore: SecretStore {}

/// Sprzątanie wpisów, których folder danych już nie istnieje. Sekrety są zapisywane osobno dla każdego
/// folderu danych (konto pozycji = ścieżka folderu), więc testowe serwery w folderach tymczasowych
/// zostawiały po sobie wpisy na zawsze. Przy starcie aplikacji usuwamy wpisy z usług aplikacji,
/// których ścieżka nie istnieje. Folder na odłączonym dysku (`/Volumes/<dysk>` niedostępny)
/// nie jest „sierotą” — ten wpis zostaje.
enum KeychainOrphans {
    static let services = [
        ServerEnvironment.keychainService,
        ServerEnvironment.userKeychainService,
        ServerEnvironment.cloudflareTunnelKeychainService,
        ServerEnvironment.metadataSourcesKeychainService,
        SponsorDetectionStore.keychainService,
    ]

    /// Zwraca liczbę usuniętych wpisów.
    @discardableResult
    static func prune(fileManager: FileManager = .default) -> Int {
        var removed = 0
        for service in services {
            for account in accounts(service: service) where isOrphan(path: account, fileManager: fileManager) {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecUseDataProtectionKeychain as String: true,
                ]
                if SecItemDelete(query as CFDictionary) == errSecSuccess { removed += 1 }
            }
        }
        return removed
    }

    /// Ścieżka bezwzględna, której nie ma, przy dostępnym dysku. Inne wartości konta zostają.
    static func isOrphan(path: String, fileManager: FileManager = .default) -> Bool {
        guard path.hasPrefix("/"), !fileManager.fileExists(atPath: path) else { return false }
        let components = (path as NSString).pathComponents
        if components.count > 2, components[1] == "Volumes" {
            return fileManager.fileExists(atPath: "/Volumes/" + components[2])
        }
        return true
    }

    private static func accounts(service: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
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
