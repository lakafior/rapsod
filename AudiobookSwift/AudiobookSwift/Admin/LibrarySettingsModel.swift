import Foundation
import Observation

/// Ustawienia biblioteki (etap 9g; wzorzec: `components/modals/libraries/EditModal.vue` z kartami
/// `EditLibrary`, `LibrarySettings`, `LibraryScannerSettings`, `ScheduleScan` i `LibraryTools`).
/// Kształty z upstreamu v2.38.0: `models/Library.js` (`LibrarySettingsObject`) i
/// `LibraryController.update` / `removeAllMetadataFiles`. Tokenem root.
///
/// Foldery biblioteki zostają poza arkuszem: usunięcie folderu w `PATCH` usuwa z bazy wszystkie
/// jego pozycje, a aplikacja ma własny przepływ „Dodaj folder…” i „Usuń bibliotekę”.
extension AudiobookshelfClient {
    struct LibrarySettings: Codable, Sendable, Equatable {
        /// 0 — okładki prostokątne (1,6 : 1), 1 — kwadratowe (`BookCoverAspectRatio`).
        var coverAspectRatio: Int?
        var disableWatcher: Bool?
        var skipMatchingMediaWithAsin: Bool?
        var skipMatchingMediaWithIsbn: Bool?
        var audiobooksOnly: Bool?
        var epubsAllowScriptedContent: Bool?
        var hideSingleBookSeries: Bool?
        var onlyShowLaterBooksInContinueSeries: Bool?
        var metadataPrecedence: [String]?
        /// Kod kraju sklepu iTunes do szukania podcastów (tylko biblioteki podcastów).
        var podcastSearchRegion: String?
        var markAsFinishedTimeRemaining: Double?
        var markAsFinishedPercentComplete: Double?
        /// `nil` — bez automatycznego skanu.
        var autoScanCronExpression: String?

        private enum CodingKeys: String, CodingKey {
            case coverAspectRatio, disableWatcher, skipMatchingMediaWithAsin, skipMatchingMediaWithIsbn,
                 audiobooksOnly, epubsAllowScriptedContent, hideSingleBookSeries, onlyShowLaterBooksInContinueSeries,
                 metadataPrecedence, podcastSearchRegion, markAsFinishedTimeRemaining, markAsFinishedPercentComplete,
                 autoScanCronExpression
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            coverAspectRatio = (try? c.decodeIfPresent(Double.self, forKey: .coverAspectRatio)).flatMap { $0.map(Int.init) }
            disableWatcher = try? c.decodeIfPresent(Bool.self, forKey: .disableWatcher)
            skipMatchingMediaWithAsin = try? c.decodeIfPresent(Bool.self, forKey: .skipMatchingMediaWithAsin)
            skipMatchingMediaWithIsbn = try? c.decodeIfPresent(Bool.self, forKey: .skipMatchingMediaWithIsbn)
            audiobooksOnly = try? c.decodeIfPresent(Bool.self, forKey: .audiobooksOnly)
            epubsAllowScriptedContent = try? c.decodeIfPresent(Bool.self, forKey: .epubsAllowScriptedContent)
            hideSingleBookSeries = try? c.decodeIfPresent(Bool.self, forKey: .hideSingleBookSeries)
            onlyShowLaterBooksInContinueSeries = try? c.decodeIfPresent(Bool.self, forKey: .onlyShowLaterBooksInContinueSeries)
            metadataPrecedence = try? c.decodeIfPresent([String].self, forKey: .metadataPrecedence)
            podcastSearchRegion = try? c.decodeIfPresent(String.self, forKey: .podcastSearchRegion)
            markAsFinishedTimeRemaining = try? c.decodeIfPresent(Double.self, forKey: .markAsFinishedTimeRemaining)
            markAsFinishedPercentComplete = try? c.decodeIfPresent(Double.self, forKey: .markAsFinishedPercentComplete)
            autoScanCronExpression = try? c.decodeIfPresent(String.self, forKey: .autoScanCronExpression)
        }

        /// Wysyłamy tylko pola, które dana biblioteka ma (serwer odrzuca obce typy), a tam,
        /// gdzie `null` coś znaczy (harmonogram, „oznacz jako ukończone”) — jawne `null`.
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(coverAspectRatio, forKey: .coverAspectRatio)
            try c.encodeIfPresent(disableWatcher, forKey: .disableWatcher)
            try c.encodeIfPresent(skipMatchingMediaWithAsin, forKey: .skipMatchingMediaWithAsin)
            try c.encodeIfPresent(skipMatchingMediaWithIsbn, forKey: .skipMatchingMediaWithIsbn)
            try c.encodeIfPresent(audiobooksOnly, forKey: .audiobooksOnly)
            try c.encodeIfPresent(epubsAllowScriptedContent, forKey: .epubsAllowScriptedContent)
            try c.encodeIfPresent(hideSingleBookSeries, forKey: .hideSingleBookSeries)
            try c.encodeIfPresent(onlyShowLaterBooksInContinueSeries, forKey: .onlyShowLaterBooksInContinueSeries)
            try c.encodeIfPresent(metadataPrecedence, forKey: .metadataPrecedence)
            try c.encodeIfPresent(podcastSearchRegion, forKey: .podcastSearchRegion)
            try c.encode(markAsFinishedTimeRemaining, forKey: .markAsFinishedTimeRemaining)
            try c.encode(markAsFinishedPercentComplete, forKey: .markAsFinishedPercentComplete)
            try c.encode(autoScanCronExpression, forKey: .autoScanCronExpression)
        }
    }

    struct LibraryDetails: Decodable, Sendable {
        let id: String
        let name: String
        let icon: String?
        let mediaType: String
        let provider: String?
        let folders: [Library.Folder]
        let settings: LibrarySettings
    }

    struct LibraryUpdate: Encodable, Sendable {
        let name: String
        let icon: String
        let provider: String
        let settings: LibrarySettings
    }

    /// Dostawcy do wyboru jako domyślne źródło (`GET /api/search/providers` → `books`/`podcasts`).
    struct ProviderChoice: Decodable, Sendable, Hashable {
        let value: String
        let text: String
    }

    func libraryDetails(id: String, token: String) async throws -> LibraryDetails {
        try decode(LibraryDetails.self, from: await send("GET", "api/libraries/\(id)", token: token))
    }

    func updateLibrary(id: String, _ update: LibraryUpdate, token: String) async throws {
        _ = try await send("PATCH", "api/libraries/\(id)", body: update, token: token)
    }

    func libraryProviders(token: String) async throws -> (books: [ProviderChoice], podcasts: [ProviderChoice]) {
        struct Response: Decodable {
            struct Providers: Decodable {
                let books: [ProviderChoice]
                let podcasts: [ProviderChoice]?
            }
            let providers: Providers
        }
        let response = try decode(Response.self, from: await send("GET", "api/search/providers", token: token))
        return (response.providers.books, response.providers.podcasts ?? [])
    }

    /// Usuwa pliki `metadata.json` albo `metadata.abs` z folderów pozycji biblioteki.
    func removeMetadataFiles(libraryID: String, ext: String, token: String) async throws -> (found: Int, removed: Int) {
        struct Response: Decodable {
            let found: Int?
            let removed: Int?
        }
        let response = try decode(Response.self, from: await send("POST", "api/libraries/\(libraryID)/remove-metadata", query: [URLQueryItem(name: "ext", value: ext)], token: token))
        return (response.found ?? 0, response.removed ?? 0)
    }
}

/// Szkic arkusza „Ustawienia biblioteki”.
@MainActor
@Observable
final class LibrarySettingsModel {
    /// Źródła metadanych skanera (`LibraryScannerSettings.vue`), w kolejności od najsłabszego.
    static let metadataSources: [(id: String, title: String, detail: String)] = [
        ("folderStructure", "Struktura folderów", "autor/seria/tytuł z nazw folderów"),
        ("audioMetatags", "Tagi plików audio", "tytuł, autor, lektor i rozdziały zapisane w plikach"),
        ("nfoFile", "Plik NFO", "plik .nfo w folderze książki"),
        ("txtFiles", "Pliki desc.txt i reader.txt", "opis i lektor"),
        ("opfFile", "Plik OPF", "metadane z pliku .opf (np. z Calibre)"),
        ("absMetadata", "Plik metadata.json", "metadane zapisane przez audiobookshelf"),
    ]

    /// Ikony bibliotek upstreamu (`store/globals.js`, `libraryIcons`) z odpowiednikami SF Symbols.
    static let icons: [(id: String, symbol: String)] = [
        ("database", "cylinder.split.1x2"), ("audiobookshelf", "books.vertical.fill"), ("books-1", "books.vertical"),
        ("books-2", "book.closed"), ("book-1", "book"), ("microphone-1", "mic"), ("microphone-3", "mic.fill"),
        ("radio", "radio"), ("podcast", "antenna.radiowaves.left.and.right"), ("rss", "dot.radiowaves.up.forward"),
        ("headphones", "headphones"), ("music", "music.note"), ("file-picture", "photo"), ("rocket", "paperplane"),
        ("power", "power"), ("star", "star"), ("heart", "heart"),
    ]

    enum FinishedRule: Hashable { case timeRemaining, percentComplete }

    let account: ServerAccount
    let libraryID: String
    let status = AdminStatus()

    private(set) var loaded: AudiobookshelfClient.LibraryDetails?
    var name = ""
    var icon = "database"
    var provider = "google"
    var settings: AudiobookshelfClient.LibrarySettings?
    /// Kolejność źródeł od najważniejszego (na górze listy), z włączeniem każdego.
    var sources: [(id: String, enabled: Bool)] = []
    var finishedRule = FinishedRule.timeRemaining
    var finishedValue = 10.0
    var schedule = BackupScheduleChoice.disabled
    private(set) var providers: [AudiobookshelfClient.ProviderChoice] = []

    init(account: ServerAccount, libraryID: String) {
        self.account = account
        self.libraryID = libraryID
    }

    var isPodcast: Bool { loaded?.mediaType == "podcast" }

    func load() async {
        await status.run("Wczytywanie…", failure: "Nie udało się wczytać ustawień biblioteki") {
            let details = try await account.withAdminToken { try await $0.libraryDetails(id: libraryID, token: $1) }
            let choices = try await account.withAdminToken { try await $0.libraryProviders(token: $1) }
            apply(details, providers: details.mediaType == "podcast" ? choices.podcasts : choices.books)
        }
    }

    private func apply(_ details: AudiobookshelfClient.LibraryDetails, providers: [AudiobookshelfClient.ProviderChoice]) {
        loaded = details
        name = details.name
        icon = details.icon ?? "database"
        provider = details.provider ?? (details.mediaType == "podcast" ? "itunes" : "google")
        var list = providers
        if !list.contains(where: { $0.value == provider }) { list.append(.init(value: provider, text: provider)) }
        self.providers = list
        settings = details.settings
        // Upstream trzyma kolejność od najsłabszego; na liście najważniejsze jest na górze.
        let active = Array((details.settings.metadataPrecedence ?? []).reversed())
        sources = active.map { ($0, true) } + Self.metadataSources.map(\.id).filter { !active.contains($0) }.map { ($0, false) }
        if let percent = details.settings.markAsFinishedPercentComplete {
            finishedRule = .percentComplete
            finishedValue = percent
        } else {
            finishedRule = .timeRemaining
            finishedValue = details.settings.markAsFinishedTimeRemaining ?? 10
        }
        schedule = details.settings.autoScanCronExpression.map { BackupScheduleChoice(.cron($0)) } ?? .disabled
    }

    /// Zapis całego formularza jednym `PATCH` (jak przycisk „Zapisz” w web UI).
    func save() async -> Bool {
        guard var settings else { return false }
        let name = name.trimmingCharacters(in: .whitespaces)
        if !isPodcast {
            settings.metadataPrecedence = sources.filter(\.enabled).map(\.id).reversed()
        }
        switch finishedRule {
        case .timeRemaining:
            settings.markAsFinishedTimeRemaining = max(0, finishedValue)
            settings.markAsFinishedPercentComplete = nil
        case .percentComplete:
            settings.markAsFinishedPercentComplete = min(100, max(0, finishedValue))
            settings.markAsFinishedTimeRemaining = nil
        }
        if case .cron(let expression) = schedule.schedule { settings.autoScanCronExpression = expression } else { settings.autoScanCronExpression = nil }
        let update = AudiobookshelfClient.LibraryUpdate(name: name, icon: icon, provider: provider, settings: settings)
        return await status.run("Zapisywanie…", failure: "Nie udało się zapisać ustawień biblioteki") {
            guard !name.isEmpty else { throw ItemManager.ManageError.invalid("Nazwa biblioteki nie może być pusta.") }
            guard isPodcast || sources.contains(where: \.enabled) else {
                throw ItemManager.ManageError.invalid("Włącz co najmniej jedno źródło metadanych skanera.")
            }
            try await account.withAdminToken { try await $0.updateLibrary(id: libraryID, update, token: $1) }
            try? await account.refreshLibraries()
        }
    }

    // MARK: Foldery (etap 9i)

    /// Dodaje folder do biblioteki i zleca skan. Folder nie może nakładać się na inną bibliotekę.
    func addFolder(_ folder: URL) async {
        let folder = folder.libraryFolderURL
        guard let current = loaded?.folders else { return }
        await status.run("Dodawanie folderu…", failure: "Nie udało się dodać folderu") {
            if let other = account.libraryOverlapping(folder) {
                throw ItemManager.ManageError.invalid(other.id == libraryID
                    ? "Ten folder (albo nadrzędny) już należy do tej biblioteki."
                    : "Ten folder nakłada się na bibliotekę „\(other.name)”.")
            }
            // Pierwszy odczyt robi aplikacja — ewentualna prośba o dostęp pojawi się teraz (jak przy nowej bibliotece).
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            let folders = current.map { AudiobookshelfClient.FolderEntry(id: $0.id, fullPath: $0.fullPath) } + [.init(id: nil, fullPath: folder.path)]
            try await account.withAdminToken { try await $0.updateLibraryFolders(id: libraryID, folders: folders, token: $1) }
            try await account.withAdminToken { try await $0.scanLibrary(id: libraryID, token: $1) }
            try await reloadFolders()
            status.notice = "Dodano folder; serwer skanuje bibliotekę."
        }
    }

    /// Usuwa folder z biblioteki: jego pozycje znikają z bazy (z postępem słuchania), pliki zostają.
    func removeFolder(_ folder: AudiobookshelfClient.Library.Folder) async {
        guard let current = loaded?.folders else { return }
        await status.run("Usuwanie folderu…", failure: "Nie udało się usunąć folderu") {
            guard current.count > 1 else {
                throw ItemManager.ManageError.invalid("Biblioteka musi mieć co najmniej jeden folder — usuń całą bibliotekę.")
            }
            let folders = current.filter { $0.id != folder.id }.map { AudiobookshelfClient.FolderEntry(id: $0.id, fullPath: $0.fullPath) }
            try await account.withAdminToken { try await $0.updateLibraryFolders(id: libraryID, folders: folders, token: $1) }
            try await reloadFolders()
            status.notice = "Folder usunięty z biblioteki. Pliki zostały na dysku."
        }
    }

    private func reloadFolders() async throws {
        let details = try await account.withAdminToken { try await $0.libraryDetails(id: libraryID, token: $1) }
        // Tylko foldery — reszta formularza mogła być już zmieniona i czeka na „Zapisz”.
        loaded = details
        try? await account.refreshLibraries()
    }

    func removeMetadataFiles(ext: String) async {
        await status.run("Usuwanie plików metadata.\(ext)…", failure: "Nie udało się usunąć plików metadanych") {
            let result = try await account.withAdminToken { try await $0.removeMetadataFiles(libraryID: libraryID, ext: ext, token: $1) }
            status.notice = result.found == 0
                ? "W tej bibliotece nie ma plików metadata.\(ext)."
                : "Usunięto \(result.removed) z \(result.found) plików metadata.\(ext)."
        }
    }
}
