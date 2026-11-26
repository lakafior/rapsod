import AppIntents
import AudiobookshelfKit
import AudiobookshelfPlayback
import Foundation
import RapsodIntegration
import UniformTypeIdentifiers

// Akcje Skrótów (etap 14e). Odtwarzanie i zadania serwera działają w tle (bez wysuwania okna);
// „Otwórz…” i „Wgraj…” wysuwają okno Biblioteka, bo ich wynikiem jest coś do obejrzenia.

// MARK: - Odtwarzanie

struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Odtwarzaj lub wstrzymaj"
    static let description = IntentDescription("Wstrzymuje odtwarzanie albo je wznawia. Gdy nic nie jest wczytane, kontynuuje ostatnio słuchaną pozycję.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = try await IntentBridge.ready(.listener)
        let player = app.listening.player
        guard player.book != nil else {
            let title = try await ResumeListening.resume(app)
            return .result(dialog: "Kontynuuję „\(title)”.")
        }
        player.togglePlayPause()
        return .result(dialog: player.isPlaying ? "Odtwarzanie wznowione." : "Odtwarzanie wstrzymane.")
    }
}

struct ContinueListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Kontynuuj słuchanie"
    static let description = IntentDescription("Odtwarza ostatnio słuchaną książkę albo odcinek od zapisanego miejsca.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = try await IntentBridge.ready(.listener)
        let player = app.listening.player
        if let book = player.book {
            if !player.isPlaying { player.play() }
            return .result(dialog: "Kontynuuję „\(book.title)”.")
        }
        let title = try await ResumeListening.resume(app)
        return .result(dialog: "Kontynuuję „\(title)”.")
    }
}

/// Ostatnio słuchana pozycja z serwera — ta sama kolejność co „Słuchaj dalej” w panelu.
@MainActor
enum ResumeListening {
    static func resume(_ app: AppDelegate) async throws -> String {
        // Świeży postęp z serwera (np. z telefonu albo po ponownym starcie) — kolejność jak w panelu.
        await app.listening.refreshMe()
        let items = try await app.listening.api { try await $0.itemsInProgress(token: $1) }
        let entries = ContinueListening.recent(inProgress: items, progress: app.listening.progress)
        for entry in entries {
            switch entry.kind {
            case .book(let item):
                try await play(app, itemID: item.id, episodeID: nil)
                return item.title
            case .serverEpisode(let item, let episode, _):
                try await play(app, itemID: item.id, episodeID: episode.id)
                return episode.title ?? item.title
            case .localEpisode:
                continue
            }
        }
        throw IntentError.nothingToResume
    }

    static func play(_ app: AppDelegate, itemID: String, episodeID: String?) async throws {
        app.listening.loadError = nil
        await app.listening.play(itemID: itemID, episodeID: episodeID)
        if let error = app.listening.loadError {
            app.listening.loadError = nil
            throw IntentError.playbackFailed(error)
        }
    }
}

struct SkipForwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Przewiń do przodu"
    static let description = IntentDescription("Przeskakuje do przodu w bieżącej książce albo odcinku.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Sekundy", description: "Domyślnie 30 s.", inclusiveRange: (1, 3600))
    var seconds: Int?

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try await IntentBridge.ready(.listener)
        guard app.listening.player.book != nil else { throw IntentError.nothingPlaying }
        app.listening.player.skip(by: SkipInterval.seconds(seconds.map(Double.init), default: AudiobookPlayer.skipForward))
        return .result()
    }
}

struct SkipBackwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Cofnij"
    static let description = IntentDescription("Cofa w bieżącej książce albo odcinku.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Sekundy", description: "Domyślnie 15 s.", inclusiveRange: (1, 3600))
    var seconds: Int?

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try await IntentBridge.ready(.listener)
        guard app.listening.player.book != nil else { throw IntentError.nothingPlaying }
        app.listening.player.skip(by: -SkipInterval.seconds(seconds.map(Double.init), default: AudiobookPlayer.skipBack))
        return .result()
    }
}

struct PlayBookIntent: AppIntent {
    static let title: LocalizedStringResource = "Odtwórz książkę"
    static let description = IntentDescription("Odtwarza książkę od miejsca zapisanego na serwerze.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Książka")
    var book: BookEntity

    static var parameterSummary: some ParameterSummary { Summary("Odtwórz \(\.$book)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = try await IntentBridge.ready(.listener)
        try await ResumeListening.play(app, itemID: book.id, episodeID: nil)
        return .result(dialog: "Odtwarzam „\(book.title)”.")
    }
}

struct PlayEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Odtwórz odcinek"
    static let description = IntentDescription("Odtwarza odcinek podcastu od miejsca zapisanego na serwerze.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Odcinek")
    var episode: EpisodeEntity

    static var parameterSummary: some ParameterSummary { Summary("Odtwórz \(\.$episode)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = try await IntentBridge.ready(.listener)
        try await ResumeListening.play(app, itemID: episode.itemID, episodeID: episode.episodeID)
        return .result(dialog: "Odtwarzam „\(episode.title)”.")
    }
}

// MARK: - Okno Biblioteka

struct OpenBookIntent: AppIntent {
    static let title: LocalizedStringResource = "Otwórz książkę"
    static let description = IntentDescription("Otwiera stronę książki w oknie Biblioteka.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Książka")
    var book: BookEntity

    static var parameterSummary: some ParameterSummary { Summary("Otwórz \(\.$book)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try await IntentBridge.ready(.listener)
        app.menuBar.openLibrary(.openItem(itemID: book.id, libraryID: book.libraryID))
        return .result()
    }
}

struct OpenPodcastIntent: AppIntent {
    static let title: LocalizedStringResource = "Otwórz podcast"
    static let description = IntentDescription("Otwiera stronę podcastu z listą odcinków w oknie Biblioteka.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Podcast")
    var podcast: PodcastEntity

    static var parameterSummary: some ParameterSummary { Summary("Otwórz \(\.$podcast)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try await IntentBridge.ready(.listener)
        app.menuBar.openLibrary(.openItem(itemID: podcast.id, libraryID: podcast.libraryID))
        return .result()
    }
}

// MARK: - Zadania serwera

struct ScanLibrariesIntent: AppIntent {
    static let title: LocalizedStringResource = "Skanuj biblioteki"
    static let description = IntentDescription("Zleca serwerowi skan bibliotek (nowe, zmienione i brakujące pozycje). Bez wyboru — wszystkie.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Biblioteki", description: "Puste — wszystkie biblioteki.")
    var libraries: [LibraryEntity]?

    static var parameterSummary: some ParameterSummary { Summary("Skanuj \(\.$libraries)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = try await IntentBridge.ready(.admin)
        let wanted = libraries.map { Set($0.map(\.id)) }
        let targets = app.account.libraries.filter { wanted?.contains($0.id) ?? true }
        guard !targets.isEmpty else { throw IntentError.notFound }
        for library in targets { app.libraryTasks.scan(library, force: false) }
        let names = targets.map(\.name).joined(separator: ", ")
        return .result(dialog: targets.count == 1 ? "Zlecono skan biblioteki „\(names)”." : "Zlecono skan bibliotek: \(names).")
    }
}

struct AddPodcastIntent: AppIntent {
    static let title: LocalizedStringResource = "Dodaj podcast z adresu RSS"
    static let description = IntentDescription("Dodaje podcast do biblioteki podcastów na serwerze z adresu kanału RSS.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Adres kanału RSS")
    var feedURL: URL

    @Parameter(title: "Biblioteka", description: "Puste — pierwsza biblioteka podcastów.")
    var library: LibraryEntity?

    @Parameter(title: "Pobieraj nowe odcinki automatycznie", default: false)
    var autoDownload: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Dodaj podcast z \(\.$feedURL)") {
            \.$library
            \.$autoDownload
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<PodcastEntity> & ProvidesDialog {
        let app = try await IntentBridge.ready(.admin)
        let podcastLibraries = app.account.libraries.filter { $0.mediaType == "podcast" }
        guard let target = library.flatMap({ chosen in podcastLibraries.first { $0.id == chosen.id } }) ?? podcastLibraries.first else {
            throw IntentError.noPodcastLibrary
        }
        let url = feedURL.absoluteString
        let feed: AudiobookshelfClient.PodcastFeed
        do {
            feed = try await app.account.withAdminToken { try await $0.podcastFeed(url: url, token: $1) }
        } catch {
            throw IntentError.failed(ItemManager.message(for: error, action: "Nie udało się wczytać kanału RSS"))
        }
        var draft = NewPodcastDraft(feed: feed, result: nil, feedURL: url, library: target)
        draft.autoDownload = autoDownload
        guard let payload = draft.payload else { throw IntentError.failed("Kanał nie ma tytułu albo biblioteka nie ma folderu.") }
        do {
            let id = try await app.account.withAdminToken { try await $0.createPodcast(payload, token: $1) }
            let entity = PodcastEntity(id: id, title: draft.title, author: draft.author.isEmpty ? nil : draft.author, libraryID: target.id)
            return .result(value: entity, dialog: "Dodano podcast „\(draft.title)” do biblioteki „\(target.name)”.")
        } catch AudiobookshelfClient.APIError.http(400, let body) where body.contains("already exists") {
            throw IntentError.podcastExists(draft.title)
        } catch {
            throw IntentError.failed(ItemManager.message(for: error, action: "Nie udało się dodać podcastu"))
        }
    }
}

struct UploadBookIntent: AppIntent {
    static let title: LocalizedStringResource = "Wgraj jako książkę"
    static let description = IntentDescription("Otwiera okno wgrywania z tymi plikami albo folderem: tytuł, autora i bibliotekę sprawdzasz przed wysłaniem.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Pliki lub folder", supportedContentTypes: [.audio, .folder, .epub, .pdf, .image])
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary { Summary("Wgraj \(\.$files) jako książkę") }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard !files.isEmpty else { throw IntentError.noFiles }
        let app = try await IntentBridge.ready(.admin)
        let urls = try Self.stage(files)
        app.menuBar.openLibrary(.upload(urls))
        return .result()
    }

    /// Kopie plików w folderze tymczasowym: adres z Skrótów bywa pusty albo ważny tylko w trakcie akcji,
    /// a arkusz wgrywania czyta pliki później.
    static func stage(_ files: [IntentFile]) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Skróty-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try files.enumerated().map { index, file in
            let name = file.filename.isEmpty ? "plik-\(index + 1)" : file.filename
            let target = folder.appending(path: name)
            if let source = file.fileURL {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: source, to: target)
            } else {
                try file.data.write(to: target)
            }
            return target
        }
    }
}
