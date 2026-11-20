import Foundation

/// Ustawienia udostępniania zapisane w folderze danych serwera (`sharing.json`).
struct SharingSettings: Codable, Sendable, Equatable {
    /// Serwer słucha w sieci lokalnej (wyłączone = tylko pętla zwrotna).
    var isEnabled = false
    /// Adres spoza sieci lokalnej wpisany przez użytkownika (pusty = brak). Aplikacja
    /// niczego pod nim nie zestawia — to adres własnego tunelu albo VPN użytkownika.
    var externalURL = ""

    init() {}

    /// Brakujące pola dostają wartości domyślne.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        externalURL = try container.decodeIfPresent(String.self, forKey: .externalURL) ?? ""
    }

    /// Brak pliku albo plik nieczytelny daje ustawienia domyślne (udostępnianie wyłączone).
    static func load(from url: URL) -> SharingSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(SharingSettings.self, from: data) else {
            return SharingSettings()
        }
        return settings
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
