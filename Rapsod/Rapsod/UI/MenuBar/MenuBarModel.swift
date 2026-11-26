import AppKit
import AudiobookshelfKit
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Rapsod", category: "MenuBar")

/// Stan panelu na pasku menu i prośby do okien (etap 14d). Żyje w `AppDelegate` przez cały czas
/// działania aplikacji; panel czyta go tylko wtedy, gdy jest otwarty.
///
/// Okna otwiera `MenuBarLabel` (jedyny widok, który żyje stale i ma `openWindow`) w odpowiedzi na
/// liczniki `dropRequest`; okno „Biblioteka” odbiera `libraryRequest`, gdy jego treść istnieje.
@MainActor
@Observable
final class MenuBarModel {
    /// Pozycja „Słuchaj dalej” w panelu.
    struct ResumeEntry: Identifiable, Equatable {
        let id: String
        let itemID: String
        let episodeID: String?
        let title: String
        let subtitle: String?
        let coverPath: String?
        /// 0…1, gdy znany.
        let progress: Double?
    }

    /// Prośba do okna „Biblioteka” z panelu albo po upuszczeniu na ikonę.
    enum LibraryRequest: Equatable {
        /// Arkusz wgrywania z tymi plikami (pusta lista — arkusz z wyborem plików).
        case upload([URL])
        /// Arkusz „Dodaj podcast” w pierwszej bibliotece podcastów.
        case addPodcast
        /// Arkusz trwającego wgrywania.
        case showUpload
    }

    private(set) var recent: [ResumeEntry] = []
    private(set) var recentLoaded = false
    /// Pliki przeciągane właśnie nad ikoną — ikona się podświetla.
    var isDropTargeted = false
    /// Upuszczone na ikonę, czekają na wybór w oknie „Dodaj do Rapsodu”.
    private(set) var dropped: [URL] = []
    /// Rośnie przy każdym upuszczeniu — `MenuBarLabel` otwiera wtedy okno wyboru.
    private(set) var dropRequest = 0
    var libraryRequest: LibraryRequest?
    /// Przeglądarka otwartego okna „Biblioteka” (stan wgrywania). Okno samo się tu wpisuje.
    weak var browser: LibraryBrowser?

    @ObservationIgnored private let listening: ListeningController
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(listening: ListeningController) {
        self.listening = listening
    }

    // MARK: Upuszczenie na ikonę

    func drop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        dropped = urls
        dropRequest += 1
    }

    func clearDrop() { dropped = [] }

    /// Czy upuszczone to jeden lub więcej folderów (można je dodać jako foldery biblioteki).
    var droppedFolders: [URL] {
        dropped.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    // MARK: Odświeżenie przy otwarciu panelu

    /// Zdarzenia serwera (postęp z telefonu, pobieranie odcinków) płyną tylko przy otwartym oknie
    /// „Biblioteka”, więc panel przy każdym otwarciu pyta serwer sam.
    func panelOpened() {
        loading?.cancel()
        loading = Task { await refresh() }
    }

    private func refresh() async {
        guard listening.availability == .ready else {
            recent = []
            recentLoaded = true
            return
        }
        await listening.refreshMe()
        do {
            let items = try await listening.api { try await $0.itemsInProgress(token: $1) }
            guard !Task.isCancelled else { return }
            let progress = listening.progress
            recent = ContinueListening.recent(inProgress: items, progress: progress).compactMap { entry in
                Self.resumeEntry(entry, progress: progress[entry.id])
            }
        } catch {
            logger.notice("Słuchaj dalej w menu: \(error.localizedDescription, privacy: .public)")
        }
        recentLoaded = true
        for library in listening.libraries where library.mediaType == "podcast" {
            guard !Task.isCancelled else { return }
            if let state = try? await listening.api({ try await $0.episodeDownloadQueue(libraryID: library.id, token: $1) }) {
                listening.episodeDownloads.replace(with: state, libraryID: library.id)
            }
        }
    }

    private static func resumeEntry(_ entry: ContinueListening.Entry, progress: AudiobookshelfClient.MediaProgress?) -> ResumeEntry? {
        switch entry.kind {
        case .book(let item):
            ResumeEntry(id: entry.id, itemID: item.id, episodeID: nil, title: item.title,
                        subtitle: item.media.metadata.authorName, coverPath: item.media.coverPath, progress: progress?.progress)
        case .serverEpisode(let item, let episode, _):
            ResumeEntry(id: entry.id, itemID: item.id, episodeID: episode.id, title: episode.title ?? "Odcinek",
                        subtitle: item.title, coverPath: item.media.coverPath, progress: progress?.progress)
        case .localEpisode:
            nil
        }
    }

    /// Wznowienie pozycji z „Słuchaj dalej” (od miejsca zapisanego na serwerze).
    func resume(_ entry: ResumeEntry) {
        Task { await listening.play(itemID: entry.itemID, episodeID: entry.episodeID) }
    }
}
