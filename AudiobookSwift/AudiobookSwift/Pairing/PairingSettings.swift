import Foundation

/// Ustawienia parowania zapisane w folderze danych serwera (`pairing.json`).
struct PairingSettings: Codable, Sendable, Equatable {
    /// Stały identyfikator serwera: nazwa rekordu CloudKit i wartość `id` w Bonjour.
    var serverID = UUID().uuidString
    /// Parowanie włączone: serwer słucha w sieci lokalnej, rekord i Bonjour są publikowane.
    var isEnabled = false
    /// Adres spoza sieci lokalnej wpisany przez użytkownika (pusty = brak).
    var externalURL = ""

    /// Brak pliku albo plik nieczytelny daje ustawienia domyślne (parowanie wyłączone).
    static func load(from url: URL) -> PairingSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(PairingSettings.self, from: data) else {
            return PairingSettings()
        }
        return settings
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
