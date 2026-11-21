import AppKit
import SwiftUI

/// Strona pozycji (`GET /api/items/:id?expanded=1`): książka albo podcast.
struct ItemPage: View {
    let browser: LibraryBrowser
    let itemID: String
    @State private var item: AudiobookshelfClient.ItemDetail?
    @State private var error: String?

    var body: some View {
        Group {
            if let item {
                if item.isPodcast {
                    PodcastPage(browser: browser, item: item)
                } else {
                    BookPage(browser: browser, item: item)
                }
            } else {
                LoadingState(error: error) { await load() }
            }
        }
        .navigationTitle(item?.title ?? "")
        .task(id: itemID) { await load() }
        .onChange(of: browser.revision) { Task { await load() } }
    }

    private func load() async {
        do {
            item = try await browser.listening.api { try await $0.item(id: itemID, token: $1) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Strona książki: to, co słuchacz widzi w web UI (okładka, metadane z linkami, postęp, opis,
/// zakładki, rozdziały, pliki) i akcje słuchacza. „Edytuj” (i wpisy w „Więcej”) otwiera arkusz
/// zarządzania pozycją (etap 9b2: szczegóły, okładka, rozdziały, dopasowanie) na koncie root.
private struct BookPage: View {
    let browser: LibraryBrowser
    let item: AudiobookshelfClient.ItemDetail
    @State private var confirmReset = false
    @State private var editing: EditRequest?
    @State private var itemAction: ItemAction?
    @State private var fileRequest: LibraryFileRequest?

    private struct EditRequest: Identifiable {
        let tab: ItemEditorModel.Tab
        var id: ItemEditorModel.Tab { tab }
    }

    @Environment(\.openWindow) private var openWindow

    private var listening: ListeningController { browser.listening }
    private var metadata: AudiobookshelfClient.ItemDetail.Media.Metadata { item.media.metadata }
    private var tasks: ItemTasks { browser.manager.tasks }
    private var hasEbookProgress: Bool { (listening.progress[item.id]?.ebookProgress ?? 0) > 0 || listening.progress[item.id]?.ebookLocation != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Wąskie okno (panel odtwarzacza otwarty): okładka nad metadanymi zamiast obok.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        cover(240)
                        info.frame(minWidth: 380, maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        cover(180)
                        info
                    }
                }
                if item.isMissing == true {
                    Label("Plików tej książki nie ma na dysku. Przywróć je i zeskanuj pozycję ponownie albo usuń ją z biblioteki.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: 760, alignment: .leading)
                }
                if let job = tasks.job(item.id) {
                    ItemTaskStatus(tasks: tasks, itemID: item.id, job: job) { ino in
                        item.media.audioFiles?.elements.first { $0.ino == ino }?.metadata?.filename
                    }
                }
                if let description = HTMLText.plain(metadata.description) {
                    ExpandableText(text: description, lines: 8)
                        .frame(maxWidth: 760, alignment: .leading)
                        .accessibilityIdentifier("book.description")
                }
                BookmarksSection(browser: browser, itemID: item.id)
                ChaptersSection(browser: browser, item: item)
                TracksSection(item: item)
                FilesSection(browser: browser, item: item, request: $fileRequest)
            }
            .padding(24)
        }
        .modifier(LibraryFileActions(browser: browser, item: item, request: $fileRequest))
        .confirmationDialog("Wyzerować postęp „\(item.title)”?", isPresented: $confirmReset) {
            Button("Wyzeruj postęp", role: .destructive) { Task { await listening.resetProgress(itemID: item.id) } }
        } message: {
            Text("Pozycja w książce i data rozpoczęcia znikną z serwera — także na telefonie.")
        }
        .sheet(item: $editing) { request in
            ItemEditorSheet(browser: browser, item: item, tab: request.tab)
        }
        .itemActions(browser: browser, item: item, action: $itemAction)
        // Postęp zadań pozycji (osadzanie, M4B) — także tych zleconych wcześniej albo z web UI.
        .onAppear { tasks.appear() }
        .onDisappear { tasks.disappear() }
    }

    private func cover(_ size: CGFloat) -> some View {
        AsyncCover(listening: listening, itemID: item.id, path: item.media.coverPath, size: size)
            .frame(width: size, height: size)
            .shadow(radius: 6, y: 3)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            details
            progressBox
            actions
        }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title).font(.title.weight(.semibold)).textSelection(.enabled)
                if metadata.explicit == true { Badge(text: "Dla dorosłych") }
                if metadata.abridged == true { Badge(text: "Skrócona") }
            }
            if let subtitle = metadata.subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.title3).foregroundStyle(.secondary)
            }
            let series = metadata.series?.values ?? []
            if !series.isEmpty {
                LinkList(values: series.map { s in
                    (s.sequence.map { "\(s.name) #\($0)" } ?? s.name, { browser.open(.series(id: s.id, name: s.name)) })
                })
            }
            let authors = metadata.authors ?? []
            if !authors.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Autor:").foregroundStyle(.secondary)
                    LinkList(values: authors.map { a in (a.name, { browser.open(.author(id: a.id, name: a.name)) }) })
                }
            }
        }
    }

    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
            if let narrators = metadata.narrators, !narrators.isEmpty {
                row("Lektor") { LinkList(values: narrators.map { n in (n, { browser.open(.filtered(.narrator(n))) }) }) }
            }
            if let year = metadata.publishedYear, !year.isEmpty { row("Rok wydania") { Text(year) } }
            if let date = metadata.publishedDate, !date.isEmpty { row("Data wydania") { Text(date) } }
            if let publisher = metadata.publisher, !publisher.isEmpty {
                row("Wydawca") { LinkList(values: [(publisher, { browser.open(.filtered(.publisher(publisher))) })]) }
            }
            if let genres = metadata.genres, !genres.isEmpty {
                row("Gatunki") { LinkList(values: genres.map { g in (g, { browser.open(.filtered(.genre(g))) }) }) }
            }
            if let tags = item.media.tags, !tags.isEmpty {
                row("Tagi") { LinkList(values: tags.map { t in (t, { browser.open(.filtered(.tag(t))) }) }) }
            }
            if let language = metadata.language, !language.isEmpty {
                row("Język") { LinkList(values: [(language, { browser.open(.filtered(.language(language))) })]) }
            }
            if let isbn = metadata.isbn, !isbn.isEmpty { row("ISBN") { Text(isbn).textSelection(.enabled) } }
            if let asin = metadata.asin, !asin.isEmpty { row("ASIN") { Text(asin).textSelection(.enabled) } }
            row("Czas trwania") { Text(Formats.duration(item.media.duration)) }
            row("Rozmiar") { Text(Formats.size(item.media.size ?? item.size)) }
            if let added = Formats.date(ms: item.addedAt) { row("Dodano") { Text(added) } }
        }
        .font(.callout)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            content()
        }
    }

    @ViewBuilder private var progressBox: some View {
        let progress = listening.progress[item.id]
        if let progress, progress.isFinished || (progress.currentTime ?? 0) > 0 || ((progress.ebookProgress ?? 0) > 0 && item.media.ebookFile != nil) {
            VStack(alignment: .leading, spacing: 4) {
                if progress.isFinished {
                    Label("Ukończone" + (Formats.date(ms: progress.finishedAt).map { " \($0)" } ?? ""), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if (progress.currentTime ?? 0) > 0 {
                    let duration = progress.duration ?? item.media.duration ?? 0
                    let value = progress.progress ?? 0
                    HStack {
                        ProgressView(value: min(1, value)).frame(maxWidth: 220)
                        Text(value.formatted(.percent.precision(.fractionLength(0))))
                    }
                    Text("Zostało \(Formats.duration(duration - (progress.currentTime ?? 0)))")
                        .foregroundStyle(.secondary)
                }
                if let read = progress.ebookProgress, read > 0, item.media.ebookFile != nil {
                    Label("Przeczytano \(read.formatted(.percent.precision(.fractionLength(0))))", systemImage: "book")
                        .foregroundStyle(.secondary)
                }
                if let started = Formats.date(ms: progress.startedAt) {
                    Text("Rozpoczęto \(started)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("book.progress")
        }
    }

    private var readButton: some View {
        Button {
            openWindow(id: ReaderWindow.windowID, value: ReaderTarget(itemID: item.id, fileIno: nil, title: item.title))
        } label: {
            Label(hasEbookProgress ? "Czytaj dalej" : "Czytaj", systemImage: "book")
        }
        .controlSize(.large)
        .fixedSize()
        .accessibilityIdentifier("book.read")
    }

    private var actions: some View {
        let progress = listening.progress[item.id]
        let isCurrent = listening.player.book?.key == item.id
        let hasAudio = !(item.media.tracks?.elements.isEmpty ?? true)
        return HStack(spacing: 10) {
            // Sam e-book (bez audio): zamiast wyszarzonego „Odtwarzaj” główny przycisk to „Czytaj”.
            if hasAudio || item.media.ebookFile == nil {
                Button {
                    Task { await listening.play(itemID: item.id) }
                } label: {
                    if isCurrent, listening.player.isPlaying {
                        Label("Pauza", systemImage: "pause.fill")
                    } else if listening.startingKey == item.id {
                        Label { Text("Wczytywanie…") } icon: { ProgressView().controlSize(.small) }
                    } else {
                        Label((progress?.currentTime ?? 0) > 0 && progress?.isFinished != true ? "Kontynuuj" : "Odtwarzaj", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .fixedSize()
                .disabled(!hasAudio)
                .accessibilityIdentifier("book.play")
            }

            if item.media.ebookFile != nil {
                // Sam e-book (bez audio): „Czytaj” jest głównym przyciskiem.
                if hasAudio {
                    readButton.buttonStyle(.bordered)
                } else {
                    readButton.buttonStyle(.borderedProminent)
                }
            }

            // Jak w web UI: przełącznik z ikoną, pełna nazwa w podpowiedzi i dla VoiceOver.
            let finishedTitle = progress?.isFinished == true ? "Oznacz jako nieukończone" : "Oznacz jako ukończone"
            Button {
                Task { await listening.setFinished(itemID: item.id, !(progress?.isFinished ?? false)) }
            } label: {
                Label(finishedTitle, systemImage: progress?.isFinished == true ? "checkmark.circle.fill" : "checkmark.circle")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(progress?.isFinished == true ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
            }
            .controlSize(.large)
            .help(finishedTitle)
            .accessibilityLabel(finishedTitle)
            .accessibilityIdentifier("book.finished")

            Button {
                editing = EditRequest(tab: .details)
            } label: {
                Label("Edytuj", systemImage: "pencil").labelStyle(.iconOnly)
            }
            .controlSize(.large)
            .disabled(!browser.manager.isAvailable)
            .help(browser.manager.isAvailable ? "Edytuj szczegóły, okładkę i rozdziały" : browser.manager.unavailableReason)
            .accessibilityLabel("Edytuj")
            .accessibilityIdentifier("book.edit")

            Menu {
                if browser.manager.isAvailable {
                    Button("Dopasuj…") { editing = EditRequest(tab: .match) }
                    Button("Edytuj szczegóły…") { editing = EditRequest(tab: .details) }
                    Button("Okładka…") { editing = EditRequest(tab: .cover) }
                    if hasAudio { Button("Rozdziały…") { editing = EditRequest(tab: .chapters) } }
                    if !(item.media.audioFiles?.elements.isEmpty ?? true) {
                        Button("Pliki audio…") { editing = EditRequest(tab: .files) }
                        Button("Narzędzia (metadane w plikach, M4B)…") { editing = EditRequest(tab: .tools) }
                    }
                    Button("Skanuj ponownie") { itemAction = .scan }
                    Divider()
                    if hasAudio { Button("Kanał RSS…") { itemAction = .rssFeed } }
                    if item.media.ebookFile != nil { Button("Wyślij e-book na czytnik…") { itemAction = .sendEbook } }
                    if hasAudio || item.media.ebookFile != nil { Divider() }
                }
                if progress != nil {
                    Button("Wyzeruj postęp…", role: .destructive) { confirmReset = true }
                    if progress?.hideFromContinueListening != true, progress?.isFinished != true {
                        Button("Usuń ze „Słuchaj dalej”") { Task { await listening.removeFromContinueListening(itemID: item.id) } }
                    }
                    Divider()
                }
                AddToPlaylistMenu(browser: browser, entry: .init(libraryItemId: item.id, episodeId: nil), libraryID: item.libraryId)
                if let path = item.path {
                    Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
                }
                if browser.manager.isAvailable {
                    Divider()
                    Button("Usuń…", role: .destructive) { itemAction = .delete }
                }
            } label: {
                Label("Więcej", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .controlSize(.large)
            .help("Więcej")
            .accessibilityIdentifier("book.more")
        }
        .padding(.top, 4)
    }
}

private struct Badge: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

/// Zakładki książki: przejście do miejsca, zmiana nazwy, usunięcie.
struct BookmarksSection: View {
    let browser: LibraryBrowser
    let itemID: String
    @State private var renaming: AudiobookshelfClient.Bookmark?
    @State private var newTitle = ""

    var body: some View {
        let bookmarks = browser.listening.bookmarks[itemID] ?? []
        if !bookmarks.isEmpty {
            DisclosureGroup("Zakładki (\(bookmarks.count))") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(bookmarks) { bookmark in
                        HStack {
                            Button {
                                Task { await browser.listening.play(itemID: itemID, at: bookmark.time) }
                            } label: {
                                HStack {
                                    Image(systemName: "bookmark.fill").foregroundStyle(.tint)
                                    Text(bookmark.title).lineLimit(1)
                                    Spacer()
                                    Text(ChapterScrubber.time(bookmark.time)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Menu {
                                Button("Zmień nazwę…") { newTitle = bookmark.title; renaming = bookmark }
                                Button("Usuń", role: .destructive) { Task { await browser.listening.deleteBookmark(bookmark) } }
                            } label: { Image(systemName: "ellipsis") }
                                .menuIndicator(.hidden).fixedSize().buttonStyle(.borderless)
                                .accessibilityLabel("Zakładka „\(bookmark.title)” — więcej")
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: 760)
            .alert("Nazwa zakładki", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { bookmark in
                TextField("Nazwa", text: $newTitle)
                Button("Zapisz") {
                    let title = newTitle
                    Task { await browser.listening.renameBookmark(bookmark, to: title) }
                }
                Button("Anuluj", role: .cancel) {}
            }
        }
    }
}

/// Rozdziały z przejściem: bieżąca książka przewija, inna zaczyna grać od rozdziału.
private struct ChaptersSection: View {
    let browser: LibraryBrowser
    let item: AudiobookshelfClient.ItemDetail

    var body: some View {
        let chapters = item.media.chapters ?? []
        if !chapters.isEmpty {
            let titles = Dictionary(zip(chapters.map(\.id), ChapterTitles.display(chapters.map(\.title))), uniquingKeysWith: { first, _ in first })
            DisclosureGroup("Rozdziały (\(chapters.count))") {
                Table(chapters) {
                    TableColumn("#") { Text("\($0.id + 1)").monospacedDigit() }.width(36)
                    TableColumn("Tytuł") { chapter in
                        Button(titles[chapter.id] ?? chapter.title) { Task { await browser.listening.play(itemID: item.id, at: chapter.start) } }
                            .buttonStyle(.link)
                            .help("Odtwarzaj od tego rozdziału")
                    }
                    TableColumn("Początek") { Text(ChapterScrubber.time($0.start)).monospacedDigit() }.width(80)
                    TableColumn("Czas") { Text(ChapterScrubber.time($0.end - $0.start)).monospacedDigit() }.width(80)
                }
                .frame(height: min(CGFloat(chapters.count) * 24 + 32, 360))
                .accessibilityIdentifier("book.chapters")
            }
            .frame(maxWidth: 760)
        }
    }
}

private struct TracksSection: View {
    let item: AudiobookshelfClient.ItemDetail

    var body: some View {
        let tracks = item.media.tracks?.elements ?? []
        if !tracks.isEmpty {
            DisclosureGroup("Ścieżki audio (\(tracks.count))") {
                Table(tracks) {
                    TableColumn("#") { Text("\($0.index)").monospacedDigit() }.width(36)
                    TableColumn("Plik") { Text($0.metadata?.filename ?? "—").lineLimit(1).help($0.metadata?.relPath ?? "") }
                    TableColumn("Kodek") { Text($0.codec ?? "—") }.width(60)
                    TableColumn("Bitrate") { Text($0.bitRate.map { "\(Int($0 / 1000)) kb/s" } ?? "—") }.width(70)
                    TableColumn("Rozmiar") { Text(Formats.size($0.metadata?.size)) }.width(80)
                    TableColumn("Czas") { Text(ChapterScrubber.time($0.duration ?? 0)).monospacedDigit() }.width(80)
                }
                .frame(height: min(CGFloat(tracks.count) * 24 + 32, 300))
            }
            .frame(maxWidth: 760)
        }
    }
}

/// Pliki pozycji z menu „…” w wierszu (etap 9g): e-book podstawowy/dodatkowy, czytanie,
/// informacje o pliku audio z ffprobe, usunięcie pliku.
private struct FilesSection: View {
    let browser: LibraryBrowser
    let item: AudiobookshelfClient.ItemDetail
    @Binding var request: LibraryFileRequest?

    var body: some View {
        let files = item.libraryFiles?.elements ?? []
        if !files.isEmpty {
            DisclosureGroup("Pliki (\(files.count))") {
                Table(files) {
                    TableColumn("Ścieżka") { file in
                        Button(file.metadata.relPath ?? file.metadata.filename ?? "—") {
                            if let path = file.metadata.path { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
                        }
                        .buttonStyle(.link)
                        .help("Pokaż w Finderze")
                    }
                    TableColumn("Rozmiar") { Text(Formats.size($0.metadata.size)) }.width(80)
                    TableColumn("Typ") { Text(typeName($0)) }.width(130)
                    TableColumn("") { file in
                        LibraryFileMenu(browser: browser, item: item, file: file, request: $request)
                    }
                    .width(28)
                }
                .frame(height: min(CGFloat(files.count) * 24 + 32, 300))
            }
            .frame(maxWidth: 760)
        }
    }

    private func typeName(_ file: AudiobookshelfClient.ItemDetail.LibraryFile) -> String {
        guard file.isEbook else { return Self.typeName(file.fileType) }
        return item.media.ebookFile?.ino == file.ino ? "e-book podstawowy" : "e-book dodatkowy"
    }

    static func typeName(_ type: String?) -> String {
        switch type {
        case "audio": "audio"
        case "image": "obraz"
        case "ebook": "e-book"
        case "text": "tekst"
        case "metadata": "metadane"
        default: "inny"
        }
    }
}

/// Strona podcastu: opis i odcinki z postępem, opisem, filtrem i sortowaniem. Zarządzanie
/// (etap 9d, konto root): „Edytuj” (szczegóły, okładka, harmonogram, dopasowanie), odcinki
/// z kanału do pobrania, sprawdzanie nowych, dopasowanie opisów odcinków; w wierszu odcinka
/// edycja i usunięcie.
private struct PodcastPage: View {
    let browser: LibraryBrowser
    let item: AudiobookshelfClient.ItemDetail
    @State private var filter = EpisodeFilter.incomplete
    @State private var sort = "publishedAt"
    @State private var query = ""
    @State private var shown: AudiobookshelfClient.PodcastEpisode?
    @State private var editing: EditRequest?
    @State private var showsFeed = false
    @State private var checksNew = false
    @State private var confirmMatch = false
    @State private var notice: String?
    @State private var itemAction: ItemAction?

    private struct EditRequest: Identifiable {
        let tab: ItemEditorModel.Tab
        var id: ItemEditorModel.Tab { tab }
    }

    enum EpisodeFilter: String, CaseIterable {
        case incomplete = "Nieukończone", inProgress = "W trakcie", complete = "Ukończone", all = "Wszystkie"
    }

    private var listening: ListeningController { browser.listening }

    var body: some View {
        let metadata = item.media.metadata
        let episodes = visibleEpisodes
        List {
            Section {
                HStack(alignment: .top, spacing: 20) {
                    AsyncCover(listening: listening, itemID: item.id, path: item.media.coverPath, size: 180, symbol: "mic")
                        .frame(width: 180, height: 180)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.title.weight(.semibold))
                        if let author = metadata.author { Text(author).foregroundStyle(.secondary) }
                        if let genres = metadata.genres, !genres.isEmpty {
                            LinkList(values: genres.map { g in (g, { browser.open(.filtered(.genre(g))) }) })
                        }
                        if let description = HTMLText.plain(metadata.description) { ExpandableText(text: description, lines: 5) }
                        actions
                        if let notice {
                            Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                                .accessibilityIdentifier("podcast.notice")
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            Section {
                ForEach(episodes) { episode in
                    EpisodeRow(browser: browser, itemID: item.id, libraryID: item.libraryId, episode: episode) { shown = episode }
                }
            } header: {
                HStack {
                    Text("Odcinki (\(episodes.count))")
                    Spacer()
                    TextField("Szukaj odcinka", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                    Picker("Pokaż", selection: $filter) { ForEach(EpisodeFilter.allCases, id: \.self) { Text($0.rawValue) } }
                        .labelsHidden().fixedSize()
                    Picker("Sortuj", selection: $sort) {
                        Text("Data publikacji").tag("publishedAt")
                        Text("Tytuł").tag("title")
                        Text("Sezon").tag("season")
                        Text("Numer odcinka").tag("episode")
                    }
                    .labelsHidden().fixedSize()
                    .help("Sortowanie odcinków")
                }
            }
        }
        .sheet(item: $shown) { episode in EpisodeDetails(podcast: item.title, author: metadata.author, episode: episode) }
        .sheet(item: $editing) { request in ItemEditorSheet(browser: browser, item: item, tab: request.tab) }
        .sheet(isPresented: $showsFeed) { EpisodeFeedSheet(browser: browser, item: item) }
        .sheet(isPresented: $checksNew) { CheckNewEpisodesSheet(browser: browser, item: item) }
        .itemActions(browser: browser, item: item, action: $itemAction)
        .confirmationDialog("Dopasować opisy odcinków do kanału?", isPresented: $confirmMatch) {
            Button("Uzupełnij puste pola") { matchEpisodes(override: false) }
            Button("Nadpisz wszystkie z kanału", role: .destructive) { matchEpisodes(override: true) }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Serwer porówna pobrane odcinki z kanałem RSS i przepisze z niego tytuły, opisy, daty i numery. Pliki audio się nie zmieniają.")
        }
    }

    private var actions: some View {
        let manager = browser.manager
        let hasFeed = !(item.media.metadata.feedUrl ?? "").isEmpty
        return HStack(spacing: 8) {
            Button("Odcinki z kanału…", systemImage: "arrow.down.circle") { showsFeed = true }
                .disabled(!manager.isAvailable || !hasFeed)
                .help(!manager.isAvailable ? manager.unavailableReason : hasFeed ? "Wybierz odcinki z kanału RSS do pobrania" : "Podcast nie ma adresu kanału RSS")
                .accessibilityIdentifier("podcast.feed")
            Button {
                editing = EditRequest(tab: .details)
            } label: {
                Label("Edytuj", systemImage: "pencil").labelStyle(.iconOnly)
            }
            .disabled(!manager.isAvailable)
            .help(manager.isAvailable ? "Edytuj szczegóły, okładkę i harmonogram pobierania" : manager.unavailableReason)
            .accessibilityLabel("Edytuj")
            .accessibilityIdentifier("podcast.edit")
            Menu {
                if manager.isAvailable {
                    Button("Sprawdź nowe odcinki…") { checksNew = true }.disabled(!hasFeed)
                    Button("Dopasuj opisy odcinków…") { confirmMatch = true }.disabled(!hasFeed)
                    Divider()
                    Button("Edytuj szczegóły…") { editing = EditRequest(tab: .details) }
                    Button("Okładka…") { editing = EditRequest(tab: .cover) }
                    Button("Harmonogram pobierania…") { editing = EditRequest(tab: .schedule) }
                    Button("Dopasuj w iTunes…") { editing = EditRequest(tab: .match) }
                    Button("Skanuj ponownie") { itemAction = .scan }
                    Divider()
                }
                Button("Oznacz wszystkie jako ukończone") { markAll(true) }
                Button("Oznacz wszystkie jako nieukończone") { markAll(false) }
                if let path = item.path {
                    Divider()
                    Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
                }
                if manager.isAvailable {
                    Divider()
                    Button("Usuń podcast…", role: .destructive) { itemAction = .delete }
                }
            } label: {
                Label("Więcej", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Więcej")
            .accessibilityIdentifier("podcast.more")
            if item.media.autoDownloadEpisodes == true {
                Label("Pobiera nowe automatycznie", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary)
            }
        }
        .controlSize(.regular)
        .padding(.top, 4)
    }

    private func matchEpisodes(override: Bool) {
        let id = item.id
        notice = "Dopasowywanie odcinków…"
        Task {
            do {
                let count = try await browser.manager.run { try await $0.quickMatchEpisodes(itemID: id, override: override, token: $1) }
                notice = count == 0 ? "Żaden odcinek nie wymagał zmian." : "Zaktualizowano odcinki: \(count)."
            } catch {
                notice = ItemManager.message(for: error, action: "Nie udało się dopasować odcinków")
            }
        }
    }

    private var visibleEpisodes: [AudiobookshelfClient.PodcastEpisode] {
        var list = item.media.episodes?.elements ?? []
        list = list.filter { episode in
            let p = listening.progress[ListeningController.key(item.id, episode.id)]
            switch filter {
            case .all: return true
            case .complete: return p?.isFinished == true
            case .incomplete: return p?.isFinished != true
            case .inProgress: return p?.isFinished != true && (p?.currentTime ?? 0) > 0
            }
        }
        let text = query.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { list = list.filter { ($0.title ?? "").localizedCaseInsensitiveContains(text) } }
        switch sort {
        case "title": list.sort { ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending }
        case "season": list.sort { ($0.season ?? "").localizedStandardCompare($1.season ?? "") == .orderedDescending }
        case "episode": list.sort { ($0.episode ?? "").localizedStandardCompare($1.episode ?? "") == .orderedDescending }
        default: list.sort { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) }
        }
        return list
    }

    private func markAll(_ finished: Bool) {
        let entries = (item.media.episodes?.elements ?? []).map { AudiobookshelfClient.BatchProgress(libraryItemId: item.id, episodeId: $0.id, isFinished: finished) }
        Task { await listening.setFinished(entries) }
    }
}

/// Wiersz odcinka (strona podcastu, „Najnowsze odcinki”).
struct EpisodeRow: View {
    let browser: LibraryBrowser
    let itemID: String
    let libraryID: String
    let episode: AudiobookshelfClient.PodcastEpisode
    var podcastTitle: String?
    let showDetails: () -> Void
    @State private var editing = false
    @State private var removing = false

    var body: some View {
        let listening = browser.listening
        let key = ListeningController.key(itemID, episode.id)
        let progress = listening.progress[key]
        let isCurrent = listening.player.book?.key == key
        HStack(alignment: .top, spacing: 12) {
            Button {
                Task { await listening.play(itemID: itemID, episodeID: episode.id) }
            } label: {
                Image(systemName: isCurrent && listening.player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title)
            }
            .buttonStyle(.borderless)
            .help("Odtwarzaj")
            .accessibilityLabel(isCurrent && listening.player.isPlaying ? "Pauza" : "Odtwarzaj")
            VStack(alignment: .leading, spacing: 3) {
                if let podcastTitle { Text(podcastTitle).font(.caption).foregroundStyle(.secondary) }
                Text(episode.title ?? "Odcinek").font(.headline).lineLimit(2)
                if let text = HTMLText.plain(episode.subtitle ?? episode.description) {
                    Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 10) {
                    if let date = episode.published { Text(Formats.day(date)) }
                    if let season = episode.season, !season.isEmpty { Text("Sezon \(season)") }
                    if let number = episode.episode, !number.isEmpty { Text("Odcinek \(number)") }
                    if progress?.isFinished == true {
                        Label("Ukończony", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if let progress, let current = progress.currentTime, current > 0 {
                        Text("Zostało \(Formats.duration((progress.duration ?? episode.length ?? 0) - current))").foregroundStyle(.orange)
                    } else {
                        Text(Formats.duration(episode.length))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await listening.play(itemID: itemID, episodeID: episode.id) } }
        .contextMenu {
            Button("Odtwarzaj") { Task { await listening.play(itemID: itemID, episodeID: episode.id) } }
            Button("Opis odcinka…", action: showDetails)
            Divider()
            if progress?.isFinished == true {
                Button("Oznacz jako nieukończony") { Task { await listening.setFinished(itemID: itemID, episodeID: episode.id, false) } }
            } else {
                Button("Oznacz jako ukończony") { Task { await listening.setFinished(itemID: itemID, episodeID: episode.id, true) } }
            }
            if progress != nil {
                Button("Wyzeruj postęp") { Task { await listening.resetProgress(itemID: itemID, episodeID: episode.id) } }
            }
            AddToPlaylistMenu(browser: browser, entry: .init(libraryItemId: itemID, episodeId: episode.id), libraryID: libraryID)
            EpisodeManageMenu(browser: browser, episode: episode, editing: $editing, removing: $removing)
        }
        .episodeManagement(browser: browser, itemID: itemID, episode: episode, editing: $editing, removing: $removing)
        .accessibilityIdentifier("episode.\(episode.id)")
    }
}

private struct EpisodeDetails: View {
    let podcast: String
    let author: String?
    let episode: AudiobookshelfClient.PodcastEpisode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(podcast + (author.map { " — \($0)" } ?? "")).font(.callout).foregroundStyle(.secondary)
            Text(episode.title ?? "Odcinek").font(.title2.weight(.semibold))
            ScrollView {
                Text(HTMLText.plain(episode.description) ?? "Brak opisu.").textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let file = episode.audioFile?.metadata?.filename { GridRow { Text("Plik").foregroundStyle(.secondary); Text(file) } }
                GridRow { Text("Rozmiar").foregroundStyle(.secondary); Text(Formats.size(episode.size ?? episode.audioFile?.metadata?.size)) }
                GridRow { Text("Czas").foregroundStyle(.secondary); Text(Formats.duration(episode.length)) }
                if let date = episode.published { GridRow { Text("Opublikowano").foregroundStyle(.secondary); Text(Formats.day(date, long: true)) } }
            }
            .font(.callout)
            HStack { Spacer(); Button("Zamknij") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }
}
