import Foundation

/// Ustawienia źródeł metadanych zapisane w folderze danych
/// (`metadata-sources/settings.json`). Bez sekretów: klucz API leży w pęku kluczy.
struct MetadataSourcesSettings: Codable, Sendable, Equatable {
    /// Funkcja jest opcjonalna i domyślnie wyłączona.
    var isEnabled = false
    /// Identyfikator wpisu dostawcy, który aplikacja dodała w audiobookshelf.
    /// Po nim (i po adresie) rozpoznajemy własny wpis, żeby nie ruszać dostawców
    /// dodanych ręcznie przez użytkownika.
    var providerID: String?

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
    }

    /// Brak pliku albo plik nieczytelny daje ustawienia domyślne (funkcja wyłączona).
    static func load(from url: URL) -> MetadataSourcesSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(MetadataSourcesSettings.self, from: data) else {
            return MetadataSourcesSettings()
        }
        return settings
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
