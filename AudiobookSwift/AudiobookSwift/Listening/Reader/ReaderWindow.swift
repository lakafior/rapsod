import AppKit
import SwiftUI

/// Co otworzyć w czytniku: podstawowy e-book pozycji (`fileIno == nil`) albo konkretny plik
/// (dodatkowy). Jak w web UI postęp zapisuje tylko podstawowy e-book.
struct ReaderTarget: Codable, Hashable, Sendable {
    let itemID: String
    let fileIno: String?
    let title: String
}

/// Formaty czytnika (MOBI/AZW3 od etapu 9h, parserem z web UI).
enum EbookFormat: String {
    case epub, pdf, comic, mobi, other

    init(format: String?, filename: String?) {
        let value = (format ?? (filename as NSString?)?.pathExtension ?? "").lowercased()
        switch value {
        case "epub": self = .epub
        case "pdf": self = .pdf
        case "cbz", "cbr", "cb7", "cbt": self = .comic
        case "mobi", "azw3", "azw": self = .mobi
        default: self = .other
        }
    }
}

/// Stan jednej sesji czytania: plik, pozycja startowa z serwera i zapis postępu.
@MainActor
@Observable
final class ReaderSession {
    enum Phase {
        case loading
        case ready(Content)
        case failed(String)
    }

    enum Content {
        case epub(EpubController)
        case pdf(URL, start: Int)
        case comic
        case unsupported(EbookFormat, URL)
    }

    let target: ReaderTarget
    let listening: ListeningController
    private(set) var phase: Phase = .loading
    private(set) var title: String
    /// Postęp zapisywany na serwerze (tylko podstawowy e-book).
    private(set) var keepsProgress = false
    private(set) var saveError: String?
    let pages = PageController()

    @ObservationIgnored private var pending: (location: String, progress: Double?)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Rozpakowany komiks (sprzątany przy zamknięciu okna).
    @ObservationIgnored private var temporary: URL?
    @ObservationIgnored private var isClosed = false

    init(target: ReaderTarget, listening: ListeningController) {
        self.target = target
        self.listening = listening
        title = target.title
    }

    func load() async {
        do {
            let item = try await listening.api { try await $0.item(id: target.itemID, token: $1) }
            title = item.title
            let primary = item.media.ebookFile
            let files = item.libraryFiles?.elements ?? []
            let ino = target.fileIno ?? primary?.ino
            let file = files.first { $0.ino == ino }
            let path = file?.metadata.path ?? primary?.metadata?.path
            let filename = file?.metadata.filename ?? primary?.metadata?.filename
            guard let ino, let path else { throw ReaderError.noEbook }
            keepsProgress = target.fileIno == nil || target.fileIno == primary?.ino
            let format = EbookFormat(format: target.fileIno == nil ? primary?.ebookFormat : nil, filename: filename)
            // Serwer działa na tym Macu — e-book czytamy z dysku jak pliki audio odtwarzacza.
            let url = URL(filePath: path)
            guard FileManager.default.isReadableFile(atPath: path) else { throw ReaderError.missingFile(path) }

            var saved: String?
            if keepsProgress {
                let progress = try? await listening.api { try await $0.progress(itemID: target.itemID, episodeID: nil, token: $1) }
                saved = progress?.ebookLocation?.value
            }
            // Jak web UI: pozycja z innego formatu (np. CFI przy PDF) jest ignorowana.
            // `Int(exactly:)`: zapis „inf”, „nan” albo ogromna liczba nie może wywrócić aplikacji.
            let startPage = saved.flatMap { Double($0) }.flatMap { Int(exactly: $0.rounded(.down)) }.map { max(1, $0) } ?? 1
            pages.onPageChange = { [weak self] page, count in
                self?.record(location: String(page), progress: count > 0 ? Double(page - 1) / Double(count) : nil)
            }

            switch format {
            case .epub:
                let controller = EpubController(fileURL: url, cacheKey: "\(target.itemID)-\(ino)", startLocation: saved?.hasPrefix("epubcfi") == true ? saved : nil)
                controller.onRelocated = { [weak self] position in self?.record(location: position.cfi, progress: position.percentage) }
                phase = .ready(.epub(controller))
            case .pdf:
                phase = .ready(.pdf(url, start: startPage))
            case .comic:
                let (folder, images) = try await ComicArchive.extract(url)
                // Okno zamknięte w trakcie rozpakowywania: `close()` już było, folder trzeba posprzątać tutaj.
                guard !isClosed else {
                    try? FileManager.default.removeItem(at: folder)
                    return
                }
                temporary = folder
                pages.loadComic(pages: images, start: startPage)
                phase = .ready(.comic)
            case .mobi:
                let controller = EpubController(fileURL: url, cacheKey: "\(target.itemID)-\(ino)", startLocation: saved?.hasPrefix("mobi:") == true ? saved : nil, kind: .mobi)
                controller.onRelocated = { [weak self] position in self?.record(location: position.cfi, progress: position.percentage) }
                phase = .ready(.epub(controller))
            case .other:
                phase = .ready(.unsupported(format, url))
            }
        } catch {
            phase = .failed((error as? ReaderError)?.errorDescription ?? ItemManager.message(for: error, action: "Nie udało się otworzyć e-booka"))
        }
    }

    /// Zapis po sekundzie spokoju — przewracanie kartek nie wysyła żądania przy każdej stronie.
    private func record(location: String, progress: Double?) {
        guard keepsProgress else { return }
        pending = (location, progress)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    func flush() async {
        guard let pending else { return }
        self.pending = nil
        do {
            try await listening.api { try await $0.updateEbookProgress(itemID: target.itemID, location: pending.location, progress: pending.progress, token: $1) }
            saveError = nil
        } catch {
            saveError = ItemManager.message(for: error, action: "Nie udało się zapisać postępu czytania")
            // Nieudany zapis czeka na następną okazję (kolejna strona albo zamknięcie okna).
            if self.pending == nil { self.pending = pending }
        }
    }

    func close() {
        isClosed = true
        saveTask?.cancel()
        Task { await flush() }
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
            self.temporary = nil
        }
    }

    enum ReaderError: LocalizedError {
        case noEbook
        case missingFile(String)

        var errorDescription: String? {
            switch self {
            case .noEbook: "Ta pozycja nie ma e-booka."
            case .missingFile(let path): "Pliku e-booka nie ma na dysku albo nie można go odczytać: \(path)"
            }
        }
    }
}

/// Okno czytnika (osobne dla każdego e-booka): spis treści w pasku bocznym, ustawienia
/// w pasku narzędzi, na dole miejsce w książce. Strzałki i spacja przewracają strony.
struct ReaderWindow: View {
    static let windowID = "reader"

    let listening: ListeningController
    @State private var session: ReaderSession
    @State private var sidebar = NavigationSplitViewVisibility.detailOnly
    @State private var showsSettings = false
    /// Okno dość szerokie na dwie strony obok siebie (układ „auto”).
    @State private var fitsTwoPages = true
    @FocusState private var comicFocused: Bool
    @AppStorage("reader.settings") private var settings = ReaderSettings()

    init(listening: ListeningController, target: ReaderTarget) {
        self.listening = listening
        _session = State(initialValue: ReaderSession(target: target, listening: listening))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebar) {
            contents
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 380)
        } detail: {
            reader
        }
        .navigationTitle(session.title)
        .toolbar { toolbar }
        .frame(minWidth: 520, minHeight: 420)
        .task { await session.load() }
        .onDisappear { session.close() }
    }

    // MARK: Treść

    @ViewBuilder private var reader: some View {
        switch session.phase {
        case .loading:
            ProgressView("Otwieranie…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("Nie można otworzyć e-booka", systemImage: "book.closed", description: Text(message))
        case .ready(let content):
            VStack(spacing: 0) {
                switch content {
                case .epub(let controller):
                    if let error = controller.error {
                        ContentUnavailableView("Nie można otworzyć e-booka", systemImage: "book.closed", description: Text(error))
                    } else {
                        EpubReaderView(controller: controller, settings: settings)
                            .background(settings.theme.background)
                    }
                case .pdf(let url, let start):
                    PDFReaderView(controller: session.pages, fileURL: url, startPage: start, twoPages: settings.spread == "auto" && fitsTwoPages)
                        .onGeometryChange(for: Bool.self) { $0.size.width >= 820 } action: { fitsTwoPages = $0 }
                case .comic:
                    ComicReaderView(controller: session.pages)
                        .focusable()
                        .focused($comicFocused)
                        .focusEffectDisabled()
                        // Strzałki działają od razu po otwarciu, bez klikania w stronę.
                        .onAppear { comicFocused = true }
                        .onKeyPress(.leftArrow) { session.pages.previous(); return .handled }
                        .onKeyPress(.rightArrow) { session.pages.next(); return .handled }
                        .onKeyPress(.space) { session.pages.next(); return .handled }
                case .unsupported(let format, let url):
                    unsupported(format, url)
                }
                Divider()
                statusBar(content)
            }
        }
    }

    private func unsupported(_ format: EbookFormat, _ url: URL) -> some View {
        ContentUnavailableView {
            Label("Nieobsługiwany format", systemImage: "book.closed")
        } description: {
            Text("Czytnik obsługuje EPUB, MOBI, AZW3, PDF oraz komiksy CBZ i CBR.")
        } actions: {
            Button("Otwórz w innej aplikacji") { NSWorkspace.shared.open(url) }
            Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    @ViewBuilder private func statusBar(_ content: ReaderSession.Content) -> some View {
        HStack(spacing: 12) {
            switch content {
            case .epub(let controller):
                Text(controller.position?.chapter ?? " ").lineLimit(1).foregroundStyle(.secondary)
                Spacer()
                if controller.hasLocations, let fraction = controller.position?.percentage {
                    EpubPositionSlider(fraction: fraction) { controller.seek($0) }
                    Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().frame(width: 44, alignment: .trailing)
                } else if controller.isOpened {
                    ProgressView().controlSize(.mini)
                    Text("Liczenie stron…").foregroundStyle(.secondary)
                }
            case .pdf, .comic:
                Spacer()
                let pages = session.pages
                if pages.pageCount > 1 {
                    PageSlider(pages: pages)
                }
                Text("Strona \(pages.page) z \(pages.pageCount)").monospacedDigit()
            case .unsupported:
                Spacer()
            }
            if let error = session.saveError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(error)
            } else if !session.keepsProgress, !Self.isUnsupported(content) {
                Text("E-book dodatkowy — postęp nie jest zapisywany").font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private static func isUnsupported(_ content: ReaderSession.Content) -> Bool {
        if case .unsupported = content { return true }
        return false
    }

    // MARK: Spis treści

    @ViewBuilder private var contents: some View {
        switch session.phase {
        case .ready(.epub(let controller)):
            if controller.toc.isEmpty {
                ContentUnavailableView("Brak spisu treści", systemImage: "list.bullet")
            } else {
                List(controller.toc) { item in
                    Button { controller.go(to: item) } label: {
                        Text(item.label).lineLimit(2).padding(.leading, CGFloat(item.depth) * 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        case .ready(.pdf), .ready(.comic):
            let pages = session.pages
            if pages.outline.isEmpty {
                ContentUnavailableView("Brak spisu treści", systemImage: "list.bullet")
            } else {
                List(pages.outline) { item in
                    Button { pages.setPage(item.page) } label: {
                        HStack {
                            Text(item.label).lineLimit(2).padding(.leading, CGFloat(item.depth) * 12)
                            Spacer()
                            Text("\(item.page)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        default:
            Color.clear
        }
    }

    // MARK: Pasek narzędzi

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { previous() } label: { Label("Poprzednia strona", systemImage: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
            Button { next() } label: { Label("Następna strona", systemImage: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
        }
        ToolbarItem(placement: .primaryAction) {
            if hasAppearance {
                Button { showsSettings.toggle() } label: { Label("Wygląd", systemImage: "textformat.size") }
                    .help("Motyw, czcionka i układ stron")
                    .popover(isPresented: $showsSettings, arrowEdge: .bottom) { settingsForm }
            }
        }
    }

    private func previous() {
        if case .ready(.epub(let controller)) = session.phase { controller.previous() } else { session.pages.previous() }
    }

    private func next() {
        if case .ready(.epub(let controller)) = session.phase { controller.next() } else { session.pages.next() }
    }

    /// Komiksy nie mają ustawień wyglądu (strona to obraz).
    private var hasAppearance: Bool {
        switch session.phase {
        case .ready(.epub), .ready(.pdf): true
        default: false
        }
    }

    private var isEpub: Bool {
        if case .ready(.epub) = session.phase { return true }
        return false
    }

    private var settingsForm: some View {
        Form {
            if isEpub {
                Picker("Motyw", selection: $settings.theme) {
                    ForEach(ReaderSettings.Theme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Krój", selection: $settings.font) {
                    Text("Szeryfowy").tag("serif")
                    Text("Bezszeryfowy").tag("sans")
                }
                .pickerStyle(.segmented)
                LabeledContent("Czcionka") {
                    Stepper("\(settings.fontScale)%", value: $settings.fontScale, in: 50...300, step: 10).monospacedDigit()
                }
                LabeledContent("Interlinia") {
                    Stepper("\(settings.lineSpacing)%", value: $settings.lineSpacing, in: 80...240, step: 5).monospacedDigit()
                }
            }
            Picker("Układ", selection: $settings.spread) {
                Text("Dwie strony w szerokim oknie").tag("auto")
                Text("Zawsze jedna strona").tag("none")
            }
            Button("Przywróć domyślne") { settings = ReaderSettings() }
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Suwak miejsca w książce: przeciąganie tylko przesuwa gałkę, a książka przeskakuje raz,
/// po puszczeniu — bez przeliczania układu przy każdym ruchu myszy.
private struct EpubPositionSlider: View {
    let fraction: Double
    let seek: (Double) -> Void
    @State private var value = 0.0
    @State private var isDragging = false

    var body: some View {
        Slider(value: $value, in: 0...1) { editing in
            isDragging = editing
            if !editing { seek(value) }
        }
        .frame(maxWidth: 260)
        .accessibilityLabel("Miejsce w książce")
        .onChange(of: fraction, initial: true) {
            if !isDragging { value = fraction }
        }
    }
}

/// Suwak stron PDF i komiksu.
private struct PageSlider: View {
    let pages: PageController
    @State private var value = 1.0

    var body: some View {
        Slider(value: $value, in: 1...Double(max(2, pages.pageCount)), step: 1)
            .frame(maxWidth: 260)
            .accessibilityLabel("Strona")
            .onChange(of: value) { pages.setPage(Int(value.rounded())) }
            .onChange(of: pages.page, initial: true) { value = Double(pages.page) }
    }
}
