// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Security
import AudiobookshelfKit

/// Sekret w pęku kluczy iOS (`kSecClassGenericPassword`), zakodowany jako JSON.
///
/// Dostęp „po pierwszym odblokowaniu, tylko to urządzenie”: późniejsze etapy (odtwarzanie
/// w tle, pobieranie) potrzebują klucza przy zablokowanym ekranie, a klucz nie powinien
/// trafiać do kopii zapasowej przenoszonej na inny telefon.
struct KeychainStore<Value: Codable & Sendable & Equatable>: SecretStore {
    let service: String
    let account: String

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Błąd pęku kluczy (\(status))."
        }
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() throws -> Value? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
