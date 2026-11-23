import AppKit
import AudiobookshelfKit
import AudiobookshelfPlayback
import SwiftUI

/// Stan arkusza zarządzania pozycją. Szkice (szczegóły, rozdziały) są brane z pozycji raz,
/// przy otwarciu arkusza i po własnym zapisie — przeładowanie strony książki po zdarzeniu
/// serwera ich nie nadpisuje, więc zapis okładki nie kasuje niezapisanych zmian w szczegółach.
@MainActor
@Observable
final class ItemEditorModel {
    enum Tab: Hashable {
        case details, cover, chapters, match
        /// Tylko podcast: automatyczne pobieranie.
        case schedule
        /// Tylko książka (etap 9e): kolejność i wykluczanie plików audio, narzędzia ffmpeg.
        case files, tools
    }

    struct Message: Equatable {
        let text: String
        let isError: Bool
    }

    let browser: LibraryBrowser
    private(set) var item: AudiobookshelfClient.ItemDetail
    var tab: Tab
    var details: DetailsDraft
    private(set) var detailsBase: DetailsDraft
    var chapters: [ChapterDraft]
    private(set) var chaptersBase: [ChapterDraft]
    var files: [FileDraft]
    private(set) var filesBase: [FileDraft]
    /// Trwająca operacja (opis w stopce).
    private(set) var busy: String?
    var message: Message?
    let match = MatchSearch()
    let covers = CoverSearch()
    // Podcast (etap 9d): szczegóły i harmonogram mają własne szkice.
    var podcast: PodcastDraft
    private(set) var podcastBase: PodcastDraft
    var schedule: ScheduleDraft
    private(set) var scheduleBase: ScheduleDraft
    let podcastMatch = PodcastMatchSearch()

    init(browser: LibraryBrowser, item: AudiobookshelfClient.ItemDetail, tab: Tab) {
        self.browser = browser
        self.item = item
        self.tab = tab
        let details = DetailsDraft(item)
        self.details = details
        detailsBase = details
        let chapters = ChapterDraft.list(item)
        self.chapters = chapters
        chaptersBase = chapters
        let files = FileDraft.list(item)
        self.files = files
        filesBase = files
        let podcast = PodcastDraft(item)
        self.podcast = podcast
        podcastBase = podcast
        let schedule = ScheduleDraft(item)
        self.schedule = schedule
        scheduleBase = schedule
    }

    var manager: ItemManager { browser.manager }
    var listening: ListeningController { browser.listening }
    var duration: Double { item.media.duration ?? 0 }
    var hasAudio: Bool { !(item.media.tracks?.elements.isEmpty ?? true) }
    var detailsDirty: Bool { !details.isSame(as: detailsBase) }
    var chaptersDirty: Bool { chapters != chaptersBase }
    var filesDirty: Bool { files != filesBase }
    var hasAudioFiles: Bool { !(item.media.audioFiles?.elements.isEmpty ?? true) }
    var isPodcast: Bool { item.isPodcast }
    var podcastDirty: Bool { isPodcast && !podcast.update(from: podcastBase).isEmpty }
    var scheduleDirty: Bool { isPodcast && !schedule.isSame(as: scheduleBase) }
    /// Niezapisane zmiany w którejkolwiek zakładce (blokuje zamknięcie arkusza).
    var anyDirty: Bool { isPodcast ? (podcastDirty || scheduleDirty) : (detailsDirty || chaptersDirty || filesDirty) }
    var isBusy: Bool { busy != nil }

    /// Wykonuje operację z opisem w stopce; błąd trafia do stopki zamiast alertu.
    func perform(_ label: String, failure: String, _ work: () async throws -> String?) async {
        guard busy == nil else { return }
        busy = label
        message = nil
        defer { busy = nil }
        do {
            if let done = try await work() { message = Message(text: done, isError: false) }
        } catch is CancellationError {
        } catch let reported as Reported {
            message = Message(text: reported.text, isError: true)
        } catch {
            message = Message(text: ItemManager.message(for: error, action: failure), isError: true)
        }
    }

    /// Tokenem root: po oznaczeniu „dla dorosłych” konto słuchacza może już nie widzieć pozycji.
    func reload() async throws {
        let id = item.id
        item = try await manager.run { try await $0.item(id: id, token: $1) }
    }

    /// `false`, gdy konto słuchacza nie widzi treści dla dorosłych (ostrzeżenie przy przełączniku).
    private(set) var listenerSeesExplicit: Bool?

    func loadListenerPermissions() async {
        guard listenerSeesExplicit == nil else { return }
        listenerSeesExplicit = try? await listening.api { try await $0.canAccessExplicitContent(token: $1) }
    }

    /// Przy otwarciu: strona książki bywa chwilę nieaktualna po zapisie (albo wcale, gdy słuchacz
    /// stracił dostęp), więc arkusz bierze świeży stan tokenem root. Szkiców z niezapisanymi zmianami nie rusza.
    func refreshOnOpen() async {
        guard (try? await reload()) != nil else { return }
        if !detailsDirty { resetDetails() }
        if !chaptersDirty { resetChapters() }
        if !filesDirty { resetFiles() }
        if !podcastDirty { resetPodcast() }
        if !scheduleDirty { resetSchedule() }
    }

    func resetPodcast() {
        podcast = PodcastDraft(item)
        podcastBase = podcast
    }

    func resetSchedule() {
        schedule = ScheduleDraft(item)
        scheduleBase = schedule
    }

    // MARK: Podcast

    func savePodcast() async {
        if let problem = podcast.problem {
            message = Message(text: problem, isError: true)
            return
        }
        let update = podcast.update(from: podcastBase)
        guard !update.isEmpty else { return }
        await perform("Zapisywanie szczegółów…", failure: "Nie udało się zapisać szczegółów") {
            let id = item.id
            let updated = try await manager.run { try await $0.updatePodcast(itemID: id, update, token: $1) }
            try await reload()
            resetPodcast()
            browser.invalidateFilterData()
            if updated, update.metadata?.explicit == true, listenerSeesExplicit == false {
                return "Zapisano szczegóły. Konto słuchacza nie ma dostępu do treści dla dorosłych — ten podcast zniknął z jego biblioteki (także na telefonie)."
            }
            return updated ? "Zapisano szczegóły." : "Nic się nie zmieniło."
        }
    }

    func saveSchedule() async {
        if let problem = schedule.problem {
            message = Message(text: problem, isError: true)
            return
        }
        let update = schedule.update(from: scheduleBase)
        guard !update.isEmpty else { return }
        await perform("Zapisywanie harmonogramu…", failure: "Nie udało się zapisać harmonogramu") {
            let id = item.id
            do {
                _ = try await manager.run { try await $0.updatePodcast(itemID: id, update, token: $1) }
            } catch AudiobookshelfClient.APIError.http(400, let body) where body.contains("cron") {
                throw Reported(text: "Serwer nie przyjął wyrażenia „\(update.autoDownloadSchedule ?? "")” — to nie jest poprawny cron.")
            }
            try await reload()
            resetSchedule()
            return schedule.enabled ? "Zapisano. Serwer będzie sprawdzał kanał według harmonogramu." : "Zapisano. Automatyczne pobieranie wyłączone."
        }
    }

    /// Jak `applyMatch`, tylko pola podcastu; okładka osobno, żeby jej błąd nie kasował reszty.
    func applyPodcastMatch(_ update: AudiobookshelfClient.PodcastUpdate, coverURL: String?) async {
        guard !update.isEmpty || coverURL != nil else { return }
        await perform("Zapisywanie dopasowania…", failure: "Nie udało się zapisać dopasowania") {
            let id = item.id
            var notes: [String] = []
            if !update.isEmpty {
                let updated = try await manager.run { try await $0.updatePodcast(itemID: id, update, token: $1) }
                notes.append(updated ? "Zapisano dane z iTunes." : "Dane bez zmian.")
            }
            if let coverURL {
                do {
                    try await manager.run { try await $0.setCover(itemID: id, url: coverURL, token: $1) }
                    notes.append("Okładka zmieniona.")
                } catch {
                    notes.append(ItemManager.message(for: error, action: "Okładki nie udało się pobrać"))
                }
            }
            try await reload()
            resetPodcast()
            browser.invalidateFilterData()
            if coverURL != nil { listening.coverChanged(itemID: id, path: item.media.coverPath) }
            podcastMatch.selected = nil
            tab = .details
            return notes.joined(separator: " ")
        }
    }

    func resetDetails() {
        details = DetailsDraft(item)
        detailsBase = details
    }

    func resetChapters() {
        chapters = ChapterDraft.list(item)
        chaptersBase = chapters
    }

    func resetFiles() {
        files = FileDraft.list(item)
        filesBase = files
    }

    // MARK: Pliki (etap 9e)

    func saveFiles() async {
        guard files.contains(where: { !$0.exclude }) else {
            message = Message(text: "Książka musi mieć przynajmniej jeden plik audio.", isError: true)
            return
        }
        // Zawsze cała lista: serwer zapisuje tylko przysłane pliki.
        let payload = files.map { (ino: $0.ino, exclude: $0.exclude) }
        await perform("Zapisywanie kolejności plików…", failure: "Nie udało się zapisać plików") {
            let id = item.id
            await listening.release(itemID: id)
            try await manager.run { try await $0.updateTracks(itemID: id, payload, token: $1) }
            try await reload()
            resetFiles()
            let included = payload.filter { !$0.exclude }.count
            return "Zapisano: \(included) z \(payload.count) plików w książce. Rozdziały z plików nie zmieniają się same — popraw je w zakładce „Rozdziały”, jeśli trzeba."
        }
    }

    // MARK: Szczegóły

    func saveDetails() async {
        if let problem = details.problem {
            message = Message(text: problem, isError: true)
            return
        }
        let update = details.update(from: detailsBase)
        guard !update.isEmpty else { return }
        await perform("Zapisywanie szczegółów…", failure: "Nie udało się zapisać szczegółów") {
            let id = item.id
            let updated = try await manager.run { try await $0.updateMedia(itemID: id, update, token: $1) }
            try await reload()
            resetDetails()
            browser.invalidateFilterData()
            if updated, update.metadata.explicit == true, listenerSeesExplicit == false {
                return "Zapisano szczegóły. Konto słuchacza nie ma dostępu do treści dla dorosłych — ta książka zniknęła z jego biblioteki (także na telefonie)."
            }
            return updated ? "Zapisano szczegóły." : "Nic się nie zmieniło."
        }
    }

    // MARK: Dopasowanie

    /// Zapis wybranych pól wyniku. Okładka idzie osobnym zapytaniem po metadanych, żeby błąd
    /// pobrania obrazka nie przekreślał reszty (w upstreamie `url` w PATCH przerywa cały zapis).
    func applyMatch(_ update: AudiobookshelfClient.MediaUpdate, coverURL: String?) async {
        guard !update.isEmpty || coverURL != nil else { return }
        await perform("Zapisywanie dopasowania…", failure: "Nie udało się zapisać dopasowania") {
            let id = item.id
            var notes: [String] = []
            if !update.isEmpty {
                let updated = try await manager.run { try await $0.updateMedia(itemID: id, update, token: $1) }
                notes.append(updated ? "Zapisano dane z dopasowania." : "Dane bez zmian.")
            }
            if let coverURL {
                do {
                    try await manager.run { try await $0.setCover(itemID: id, url: coverURL, token: $1) }
                    notes.append("Okładka zmieniona.")
                } catch {
                    // Metadane już zapisane — pokaż je i powiedz, czego brakuje.
                    try? await reload()
                    resetDetails()
                    browser.invalidateFilterData()
                    match.selected = nil
                    let text = (notes + [ItemManager.message(for: error, action: "Okładki nie udało się pobrać")]).joined(separator: " ")
                    throw Reported(text: text)
                }
            }
            try await reload()
            resetDetails()
            browser.invalidateFilterData()
            if coverURL != nil { listening.coverChanged(itemID: id, path: item.media.coverPath) }
            match.selected = nil
            tab = .details
            return notes.joined(separator: " ")
        }
    }

    /// Błąd z gotowym komunikatem (np. częściowy sukces).
    private struct Reported: Error {
        let text: String
    }

    // MARK: Okładka

    func changeCover(_ label: String, failure: String, _ operation: @escaping @Sendable (AudiobookshelfClient, String, String) async throws -> Void) async {
        await perform(label, failure: failure) {
            let id = item.id
            try await manager.run { try await operation($0, id, $1) }
            try await reload()
            listening.coverChanged(itemID: id, path: item.media.coverPath)
            return item.media.coverPath == nil ? "Okładka usunięta." : "Okładka zmieniona."
        }
    }

    // MARK: Rozdziały

    func saveChapters() async {
        if let problem = ChapterDraft.problem(in: chapters, duration: duration) {
            message = Message(text: problem, isError: true)
            return
        }
        let payload = ChapterDraft.payload(chapters, duration: duration)
        await perform("Zapisywanie rozdziałów…", failure: "Nie udało się zapisać rozdziałów") {
            let id = item.id
            let updated = try await manager.run { try await $0.updateChapters(itemID: id, payload, token: $1) }
            try await reload()
            resetChapters()
            let chapters = (item.media.chapters ?? []).map { PlaybackChapter(id: $0.id, start: $0.start, end: $0.end, title: $0.title) }
            listening.chaptersChanged(itemID: id, chapters: chapters)
            return updated ? "Zapisano rozdziały (\(payload.count))." : "Nic się nie zmieniło."
        }
    }
}

/// Arkusz „Edycja pozycji” nad oknem biblioteki: zakładki jak w modalu web UI.
struct ItemEditorSheet: View {
    @State private var model: ItemEditorModel
    @State private var confirmClose = false
    @Environment(\.dismiss) private var dismiss

    init(browser: LibraryBrowser, item: AudiobookshelfClient.ItemDetail, tab: ItemEditorModel.Tab) {
        _model = State(initialValue: ItemEditorModel(browser: browser, item: item, tab: tab))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Przełącznik zamiast `TabView`: w `TabView` arkusza etykiety zakładek rysowały się ucięte
            // („S… O… P… N…”) przy sześciu zakładkach książki i czterech podcastu (macOS 27),
            // choć AX podawał pełne szerokości.
            VStack(spacing: 0) {
                Picker("Zakładka", selection: $model.tab) {
                    ForEach(tabs, id: \.tab) { Text($0.title).tag($0.tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.bottom, 4)
                .accessibilityIdentifier("editor.tabs")
                Group {
                    if model.isPodcast {
                        switch model.tab {
                        case .cover: CoverTab(model: model)
                        case .schedule: ScheduleTab(model: model)
                        case .match: PodcastMatchTab(model: model)
                        default: PodcastDetailsTab(model: model)
                        }
                    } else {
                        switch model.tab {
                        case .cover: CoverTab(model: model)
                        case .chapters: ChaptersTab(model: model)
                        case .match: MatchTab(model: model)
                        case .files: FilesTab(model: model)
                        case .tools: ToolsTab(model: model)
                        default: DetailsTab(model: model)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding([.horizontal, .bottom], 16)
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 880, minHeight: 640, idealHeight: 720)
        .interactiveDismissDisabled(model.anyDirty)
        // Zmiana pozycji na serwerze (np. po scaleniu do M4B albo osadzeniu) — świeży stan
        // w zakładkach; szkice z niezapisanymi zmianami zostają.
        .onChange(of: model.browser.revision) { Task { await model.refreshOnOpen() } }
        .task {
            await model.refreshOnOpen()
            await model.loadListenerPermissions()
            await model.browser.loadFilterData()
        }
        .confirmationDialog("Odrzucić niezapisane zmiany?", isPresented: $confirmClose) {
            Button("Odrzuć zmiany", role: .destructive) { dismiss() }
            Button("Wróć do edycji", role: .cancel) {}
        } message: {
            Text(unsavedSummary)
        }
    }

    private var tabs: [(tab: ItemEditorModel.Tab, title: String)] {
        if model.isPodcast {
            return [(.details, "Szczegóły"), (.cover, "Okładka"), (.schedule, "Harmonogram"), (.match, "Dopasuj")]
        }
        var tabs: [(tab: ItemEditorModel.Tab, title: String)] = [(.details, "Szczegóły"), (.cover, "Okładka")]
        if model.hasAudio { tabs.append((.chapters, "Rozdziały")) }
        tabs.append((.match, "Dopasuj"))
        if model.hasAudioFiles {
            tabs.append((.files, "Pliki"))
            tabs.append((.tools, "Narzędzia"))
        }
        return tabs
    }

    private var header: some View {
        HStack(spacing: 12) {
            AsyncCover(listening: model.listening, itemID: model.item.id, path: model.item.media.coverPath, size: 44)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.item.title).font(.headline).lineLimit(1)
                let authors = model.isPodcast ? (model.item.media.metadata.author ?? "") : (model.item.media.metadata.authors ?? []).map(\.name).joined(separator: ", ")
                if !authors.isEmpty { Text(authors).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).foregroundStyle(.secondary)
            } else if let message = model.message {
                Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(message.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.green))
                Text(message.text)
                    .foregroundStyle(message.isError ? .primary : .secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .accessibilityIdentifier("editor.message")
            }
            Spacer()
            Button("Zamknij") {
                // Najpierw kończy edycję pola, żeby niezatwierdzony tekst (np. żeton bez przecinka) też się liczył.
                NSApp.keyWindow?.makeFirstResponder(nil)
                if model.anyDirty { confirmClose = true } else { dismiss() }
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("editor.close")
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var unsavedSummary: String {
        var parts: [String] = []
        if model.detailsDirty { parts.append("szczegóły") }
        if model.chaptersDirty { parts.append("rozdziały") }
        if model.filesDirty { parts.append("kolejność plików") }
        if model.podcastDirty { parts.append("szczegóły") }
        if model.scheduleDirty { parts.append("harmonogram") }
        return "Niezapisane: \(parts.joined(separator: " i ")). Zamknięcie je odrzuci."
    }
}
