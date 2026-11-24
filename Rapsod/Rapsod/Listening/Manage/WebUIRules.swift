import AudiobookshelfKit
import Foundation

// Reguły przetłumaczone z klienta web audiobookshelf (GPL-3.0). Zostają w aplikacji (GPL-3.0),
// poza wspólnym pakietem AudiobookshelfKit (MPL-2.0); klient iOS potrzebuje własnych odpowiedników.

extension AudiobookshelfClient {
    /// Adres odcinka bez parametrów śledzących — tak `EpisodeFeed.vue` porównuje z pobranymi
    /// (zostaje tylko `id`, bo bywa częścią adresu pliku).
    static func cleanEpisodeURL(_ url: String) -> String {
        guard var components = URLComponents(string: url), let items = components.queryItems, !items.isEmpty else { return url }
        let kept = items.filter { $0.name == "id" }
        guard !kept.isEmpty else { return url }
        components.queryItems = kept
        return components.string ?? url
    }

    /// Nazwa folderu z tytułu — ta sama zasada co `$sanitizeFilename` web UI (pierwszy dwukropek → „ - ”).
    static func podcastFolderName(_ title: String) -> String {
        var name = title
        if let colon = name.firstIndex(of: ":") { name.replaceSubrange(colon...colon, with: " - ") }
        name = name.replacingOccurrences(of: "[/?<>\\\\:*|\"]", with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: "[\\x00-\\x1f\\x80-\\x9f\\n\\r]", with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: "[. ]+$", with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        name = name.trimmingCharacters(in: .whitespaces)
        if name.allSatisfy({ $0 == "." }) { name = "" }
        // 255 bajtów UTF-16 jak w upstreamie — tnie po znakach, nie w połowie.
        while name.utf16.count * 2 > 255 { name.removeLast() }
        return name
    }
}

extension AudiobookshelfClient.Permissions {
    /// Domyślne uprawnienia typu konta (jak `userTypeUpdated` w `AccountModal.vue`).
    static func defaults(for type: String) -> Self {
        var permissions = Self()
        let isAdmin = type == "admin"
        permissions.download = type != "guest"
        permissions.update = isAdmin
        permissions.delete = isAdmin
        permissions.upload = isAdmin
        permissions.accessExplicitContent = isAdmin
        permissions.createEreader = isAdmin
        return permissions
    }
}
