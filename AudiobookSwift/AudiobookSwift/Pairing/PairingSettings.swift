import Foundation

/// Ustawienia parowania zapisane w folderze danych serwera (`pairing.json`).
struct PairingSettings: Codable, Sendable, Equatable {
    /// Stały identyfikator serwera: nazwa rekordu CloudKit i wartość `id` w Bonjour.
    var serverID = UUID().uuidString
    /// Parowanie włączone: serwer słucha w sieci lokalnej, rekord i Bonjour są publikowane.
    var isEnabled = false
    /// Adres spoza sieci lokalnej wpisany przez użytkownika (pusty = brak).
    var externalURL = ""
    /// Wyłączenie parowania nie zdołało usunąć klucza API albo rekordu (serwer nie działał,
    /// brak sieci) — sprzątanie zostanie powtórzone przy następnej okazji.
    var needsCleanup = false

    init() {}

    /// Brakujące pola dostają wartości domyślne, żeby starszy plik nie zgubił identyfikatora.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverID = try container.decode(String.self, forKey: .serverID)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        externalURL = try container.decodeIfPresent(String.self, forKey: .externalURL) ?? ""
        needsCleanup = try container.decodeIfPresent(Bool.self, forKey: .needsCleanup) ?? false
    }

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
