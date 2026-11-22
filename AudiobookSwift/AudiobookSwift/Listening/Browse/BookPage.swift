import AppKit
import SwiftUI

/// Strona książki: to, co słuchacz widzi w web UI (okładka, metadane z linkami, postęp, opis,
/// zakładki, rozdziały, pliki) i akcje słuchacza. „Edytuj” (i wpisy w „Więcej”) otwiera arkusz
/// zarządzania pozycją (etap 9b2: szczegóły, okładka, rozdziały, dopasowanie) na koncie root.
struct BookPage: View {
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
                    if hasAudio { Button("Publiczny link…") { itemAction = .shareLink } }
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
