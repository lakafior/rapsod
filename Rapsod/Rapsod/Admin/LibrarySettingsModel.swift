import AudiobookshelfKit
import Foundation
import Observation

/// Ustawienia biblioteki na jej podstronie (Biblioteki › biblioteka). Każda zmiana zapisuje się
/// sama po chwili (`draftChanged()`), jednym `PATCH` całego formularza, jak „Zapisz” w web UI.
/// Nieudany zapis przywraca pola do stanu z serwera i zostawia komunikat błędu.
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

    /// Wszystko, co zapisuje `save()` — porównywane z ostatnim stanem z serwera.
    struct Draft: Equatable {
        var name: String
        var icon: String
        var provider: String
        var settings: AudiobookshelfClient.LibrarySettings?
        var sources: [String]
        var finishedRule: FinishedRule
        var finishedValue: Double
        var schedule: BackupScheduleChoice
    }

    var draft: Draft {
        Draft(name: name, icon: icon, provider: provider, settings: settings,
              sources: sources.map { "\($0.id):\($0.enabled)" }, finishedRule: finishedRule,
              finishedValue: finishedValue, schedule: schedule)
    }

    /// Stan zapisany na serwerze (po wczytaniu albo ostatnim udanym zapisie).
    @ObservationIgnored private var savedDraft: Draft?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(account: ServerAccount, libraryID: String) {
        self.account = account
        self.libraryID = libraryID
    }

    var isPodcast: Bool { loaded?.mediaType == "podcast" }

    /// Harmonogram skanu zapisany na serwerze (do powrotu na „Własny (cron)”).
    var savedSchedule: BackupScheduleChoice {
        loaded?.settings.autoScanCronExpression.map { BackupScheduleChoice(.cron($0)) } ?? .disabled
    }

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
        savedDraft = draft
    }

    /// Pole formularza się zmieniło: zapis po krótkiej przerwie (kilka kliknięć w rzędzie to jeden zapis).
    func draftChanged() {
        guard let savedDraft, draft != savedDraft else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            // Osobne zadanie: anulowanie przy następnej zmianie przerywa tylko odliczanie, nie zapis.
            Task { await self?.saveNow() }
        }
    }

    /// Zapisuje od razu (np. przed wyjściem z podstrony); czeka, aż skończy się trwająca operacja.
    func saveNow() async {
        while status.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
        guard let savedDraft, draft != savedDraft else { return }
        if await save() { return }
        // Na stronie nie może zostać wartość, której nie ma na serwerze.
        if let loaded { apply(loaded, providers: providers) }
    }

    /// Zapis całego formularza jednym `PATCH`; po nim pola pokazują to, co zwrócił serwer.
    private func save() async -> Bool {
        guard var settings else { return false }
        let target = draft
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
            let details = try await account.withAdminToken { try await $0.libraryDetails(id: libraryID, token: $1) }
            // Zmiana w trakcie zapisu czeka na swój zapis — nie nadpisujemy jej odpowiedzią serwera.
            if draft == target { apply(details, providers: providers) } else { loaded = details; savedDraft = target }
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
        // Tylko foldery — reszta formularza może czekać na zapis.
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
