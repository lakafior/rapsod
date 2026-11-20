import Foundation

/// Sposób dostępu do serwera spoza sieci lokalnej.
enum ExternalAccessMode: String, Codable, Sendable, CaseIterable {
    /// Domyślnie: tylko ten Mac i (po włączeniu) sieć lokalna.
    case none
    /// Adres własnego tunelu lub VPN (Tailscale itp.) wpisany ręcznie.
    case custom
    /// Tunel Cloudflare zestawiany przez aplikację (moduł `Tunnel/`).
    case cloudflareTunnel
}

/// Ustawienia udostępniania zapisane w folderze danych serwera (`sharing.json`).
/// Bez sekretów: token tunelu leży wyłącznie w pęku kluczy.
struct SharingSettings: Codable, Sendable, Equatable {
    /// Serwer słucha w sieci lokalnej (wyłączone = tylko pętla zwrotna).
    var isEnabled = false
    var externalAccess = ExternalAccessMode.none
    /// Adres spoza sieci lokalnej wpisany przez użytkownika (pusty = brak). Aplikacja
    /// niczego pod nim nie zestawia — to adres własnego tunelu albo VPN użytkownika.
    /// Używany tylko w trybie `.custom`, ale zachowywany przy zmianie trybu.
    var externalURL = ""

    init() {}

    /// Brakujące pola dostają wartości domyślne. Plik sprzed wyboru trybu z wpisanym
    /// adresem zewnętrznym oznacza tryb „własny adres”.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        externalURL = try container.decodeIfPresent(String.self, forKey: .externalURL) ?? ""
        externalAccess = (try? container.decodeIfPresent(ExternalAccessMode.self, forKey: .externalAccess))
            ?? (externalURL.isEmpty ? .none : .custom)
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
