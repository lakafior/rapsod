import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Prośba o arkusz wgrywania (z upuszczenia na okno albo przycisku w pasku narzędzi).
struct UploadRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Wgrywanie książek do biblioteki (etap 9e, jak strona `upload` web UI): każdy upuszczony
/// folder to osobna książka, luźne pliki razem — jedna (decyzja użytkownika). Serwer kładzie
/// pliki w `<folder biblioteki>/<autor>/<seria>/<tytuł>` (podcast: `<tytuł>`) i niczego nie
/// skanuje; książkę dodaje obserwator plików, a gdy jest wyłączony — aplikacja zleca skan biblioteki.
@MainActor
@Observable
final class UploadModel {
    enum Status: Equatable {
        case ready
        case checking
        case uploading(Double)
        case done
        case failed(String)
    }

    struct Entry: Identifiable {
        let id = UUID()
        var files: [URL]
        var title: String
        var author: String
        var series: String
        var status: Status = .ready
        var size: Int64 { files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0) } }
    }

    /// Rozszerzenia jak `SupportedFileTypes` w `client/plugins/constants.js`.
    static let audio: Set<String> = ["m4b", "mp3", "m4a", "flac", "opus", "ogg", "oga", "mp4", "aac", "wma", "aiff", "aif", "wav", "webm", "webma", "mka", "awb", "caf", "mpeg", "mpg"]
    static let supported: Set<String> = audio.union(["png", "jpg", "jpeg", "webp", "epub", "pdf", "mobi", "azw3", "cbr", "cbz", "nfo", "txt", "opf", "abs", "xml", "json"])

    let browser: LibraryBrowser
    var libraryID: String?
    var folderID: String?
    var entries: [Entry] = []
    /// Pominięte pliki (nieobsługiwany typ, ukryte).
    private(set) var skipped: [String] = []
    private(set) var isRunning = false
    private(set) var summary: String?

    init(browser: LibraryBrowser, urls: [URL]) {
        self.browser = browser
        let current = browser.library
        libraryID = current?.id ?? libraries.first?.id
        folderID = library?.folders.first?.id
        add(urls)
    }

    /// Biblioteki dostępne do wgrania (te, które widzi okno).
    var libraries: [AudiobookshelfClient.Library] { browser.listening.libraries }
    var library: AudiobookshelfClient.Library? { libraries.first { $0.id == libraryID } }
    var folder: AudiobookshelfClient.Library.Folder? { library?.folders.first { $0.id == folderID } ?? library?.folders.first }
    var isPodcast: Bool { library?.mediaType == "podcast" }
    var pending: [Entry] { entries.filter { $0.status != .done } }
    var isFinished: Bool { !entries.isEmpty && entries.allSatisfy { $0.status == .done } }

    func libraryChanged() {
        folderID = library?.folders.first?.id
    }

    // MARK: Grupowanie

    func add(_ urls: [URL]) {
        var loose: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let files = collect(in: url)
                if files.isEmpty {
                    skipped.append(url.lastPathComponent + "/ (brak obsługiwanych plików)")
                } else {
                    entries.append(Entry(files: files, title: url.lastPathComponent, author: "", series: ""))
                }
            } else if accept(url) {
                loose.append(url)
            }
        }
        if !loose.isEmpty {
            let sorted = loose.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let first = sorted.first { Self.audio.contains($0.pathExtension.lowercased()) } ?? sorted[0]
            entries.append(Entry(files: sorted, title: first.deletingPathExtension().lastPathComponent, author: "", series: ""))
        }
    }

    func remove(_ id: Entry.ID) {
        entries.removeAll { $0.id == id }
    }

    /// Pliki folderu razem z podfolderami (serwer i tak kładzie je płasko w folderze książki).
    private func collect(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if accept(url) { files.append(url) }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func accept(_ url: URL) -> Bool {
        if Self.supported.contains(url.pathExtension.lowercased()) { return true }
        skipped.append(url.lastPathComponent)
        return false
    }

    // MARK: Ścieżka docelowa

    /// `sanitizeFilename` z `server/utils/fileUtils.js` (bez przycinania do 255 bajtów).
    static func sanitize(_ part: String) -> String {
        var text = part.precomposedStringWithCanonicalMapping
        if let colon = text.firstIndex(of: ":") { text.replaceSubrange(colon...colon, with: " - ") }
        text = text.replacingOccurrences(of: "[/?<>\\\\:*|\"]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\\x00-\\x1f\\x80-\\x9f\\n\\r]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^\\.+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[. ]+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    func directory(for entry: Entry) -> String {
        let parts = isPodcast ? [entry.title] : [entry.author, entry.series, entry.title]
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map(Self.sanitize).joined(separator: "/")
    }

    func problem(of entry: Entry) -> String? {
        if Self.sanitize(entry.title).isEmpty { return "Podaj tytuł." }
        if !entry.files.contains(where: { Self.audio.contains($0.pathExtension.lowercased()) }) {
            return isPodcast ? nil : "Brak plików audio — serwer doda co najwyżej e-book."
        }
        return nil
    }

    var canStart: Bool {
        !isRunning && library != nil && folder != nil && !pending.isEmpty
            && pending.allSatisfy { !Self.sanitize($0.title).isEmpty }
    }

    // MARK: Wysyłanie

    func start() async {
        guard canStart, let library, let folder else { return }
        isRunning = true
        summary = nil
        defer { isRunning = false }
        let manager = browser.manager
        var uploaded = 0
        for index in entries.indices where entries[index].status != .done {
            let entry = entries[index]
            let directory = directory(for: entry)
            entries[index].status = .checking
            do {
                let check = try await manager.run { try await $0.pathExists(directory: directory, folderPath: folder.fullPath, token: $1) }
                if check.exists {
                    entries[index].status = .failed(check.itemTitle.map { "Ta ścieżka należy już do pozycji „\($0)”." }
                        ?? "Folder \(directory) już istnieje w bibliotece — zmień tytuł, autora albo serię.")
                    continue
                }
                let id = entry.id
                let title = entry.title.trimmingCharacters(in: .whitespaces)
                let author = isPodcast ? nil : entry.author.trimmingCharacters(in: .whitespaces)
                let series = isPodcast ? nil : entry.series.trimmingCharacters(in: .whitespaces)
                entries[index].status = .uploading(0)
                let report: @Sendable (Double) -> Void = { [weak self] fraction in
                    Task { @MainActor in self?.setProgress(id, fraction) }
                }
                try await manager.run { client, token in
                    try await client.upload(files: entry.files, title: title, author: author, series: series, libraryID: library.id, folderID: folder.id, token: token, progress: report)
                }
                if let current = entries.firstIndex(where: { $0.id == id }) { entries[current].status = .done }
                uploaded += 1
            } catch {
                entries[index].status = .failed(ItemManager.message(for: error, action: "Wysyłanie"))
            }
        }
        guard uploaded > 0 else { return }
        summary = await afterUpload(library: library, count: uploaded)
    }

    private func setProgress(_ id: Entry.ID, _ fraction: Double) {
        guard let index = entries.firstIndex(where: { $0.id == id }), case .uploading = entries[index].status else { return }
        entries[index].status = .uploading(fraction)
    }

    /// Obserwator plików doda książkę sam; gdy jest wyłączony (dla serwera albo biblioteki), zlecamy skan.
    private func afterUpload(library: AudiobookshelfClient.Library, count: Int) async -> String {
        let what = count == 1 ? "Wgrano książkę." : "Wgrano \(count) książki."
        let watching = try? await browser.manager.run { try await $0.isWatcherActive(libraryID: library.id, token: $1) }
        if watching == true {
            return "\(what) Serwer doda ją do biblioteki „\(library.name)”, gdy obserwator plików ją wykryje (zwykle kilka sekund)."
        }
        do {
            try await browser.manager.run { try await $0.scanLibrary(id: library.id, force: false, token: $1) }
            return "\(what) Obserwator plików jest wyłączony, więc zlecono skan biblioteki „\(library.name)”."
        } catch {
            return "\(what) " + ItemManager.message(for: error, action: "Nie udało się zlecić skanu — zeskanuj bibliotekę w ustawieniach")
        }
    }
}

extension AudiobookshelfClient {
    /// Czy obserwator plików pilnuje biblioteki (`scannerDisableWatcher` serwera i `disableWatcher` biblioteki).
    func isWatcherActive(libraryID: String, token: String) async throws -> Bool {
        struct Authorize: Decodable {
            struct Settings: Decodable { let scannerDisableWatcher: Bool? }
            let serverSettings: Settings
        }
        struct Library: Decodable {
            struct Settings: Decodable { let disableWatcher: Bool? }
            let settings: Settings?
        }
        let server = try decode(Authorize.self, from: await send("POST", "api/authorize", token: token))
        if server.serverSettings.scannerDisableWatcher == true { return false }
        let library = try decode(Library.self, from: await send("GET", "api/libraries/\(libraryID)", token: token))
        return library.settings?.disableWatcher != true
    }
}

/// Arkusz „Wgraj do biblioteki”.
struct UploadSheet: View {
    @State private var model: UploadModel
    @State private var isTargeted = false
    @Environment(\.dismiss) private var dismiss

    init(browser: LibraryBrowser, request: UploadRequest) {
        _model = State(initialValue: UploadModel(browser: browser, urls: request.urls))
    }

    var body: some View {
        VStack(spacing: 0) {
            destination
                .padding(16)
            Divider()
            if model.entries.isEmpty {
                ContentUnavailableView {
                    Label("Upuść foldery albo pliki", systemImage: "square.and.arrow.down")
                } description: {
                    Text("Każdy folder to osobna książka, luźne pliki trafią do jednej.")
                } actions: {
                    Button("Wybierz…") { choose() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach($model.entries) { $entry in
                            UploadEntryCard(model: model, entry: $entry)
                        }
                        if !model.skipped.isEmpty {
                            Text("Pominięte (nieobsługiwany typ): \(model.skipped.prefix(8).joined(separator: ", "))\(model.skipped.count > 8 ? " i \(model.skipped.count - 8) innych" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 700, minHeight: 480, idealHeight: 560)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, lineWidth: 3).padding(4).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isRunning else { return false }
            model.add(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .interactiveDismissDisabled(model.isRunning)
    }

    private var destination: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Biblioteka").foregroundStyle(.secondary)
                Picker("Biblioteka", selection: $model.libraryID) {
                    ForEach(model.libraries) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(model.isRunning)
                .onChange(of: model.libraryID) { model.libraryChanged() }
                .accessibilityIdentifier("upload.library")
            }
            if let library = model.library, library.folders.count > 1 {
                GridRow {
                    Text("Folder").foregroundStyle(.secondary)
                    Picker("Folder", selection: $model.folderID) {
                        ForEach(library.folders, id: \.id) { Text($0.fullPath).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(model.isRunning)
                }
            } else if let folder = model.folder {
                GridRow {
                    Text("Folder").foregroundStyle(.secondary)
                    Text(folder.fullPath).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let summary = model.summary {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(summary).foregroundStyle(.secondary).lineLimit(3).accessibilityIdentifier("upload.summary")
            } else if !model.entries.isEmpty {
                Button("Dodaj…") { choose() }.disabled(model.isRunning)
            }
            Spacer()
            Button(model.isFinished ? "Zamknij" : "Anuluj") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isRunning)
            if !model.isFinished {
                Button(model.pending.count > 1 ? "Wgraj \(model.pending.count)" : "Wgraj") {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    Task { await model.start() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart)
                .accessibilityIdentifier("upload.start")
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Wybierz"
        panel.message = "Foldery z książkami albo pliki jednej książki"
        guard panel.runModal() == .OK else { return }
        model.add(panel.urls)
    }
}

private struct UploadEntryCard: View {
    let model: UploadModel
    @Binding var entry: UploadModel.Entry

    var body: some View {
        let locked = model.isRunning || entry.status == .done
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title.isEmpty ? "Bez tytułu" : entry.title).font(.headline).lineLimit(1)
                Spacer()
                status
                if !locked {
                    Button("Usuń z listy", systemImage: "xmark") { model.remove(entry.id) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Tytuł").foregroundStyle(.secondary)
                    TextField("Tytuł", text: $entry.title).accessibilityIdentifier("upload.title")
                }
                if !model.isPodcast {
                    GridRow {
                        Text("Autor").foregroundStyle(.secondary)
                        TextField("Autor (opcjonalnie)", text: $entry.author).accessibilityIdentifier("upload.author")
                    }
                    GridRow {
                        Text("Seria").foregroundStyle(.secondary)
                        TextField("Seria (opcjonalnie)", text: $entry.series).accessibilityIdentifier("upload.series")
                    }
                }
                GridRow {
                    Text("Trafi do").foregroundStyle(.secondary)
                    Text((model.folder?.fullPath ?? "…") + "/" + model.directory(for: entry))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.head)
                        .textSelection(.enabled)
                }
            }
            .disabled(locked)
            DisclosureGroup("\(entry.files.count == 1 ? "1 plik" : "\(entry.files.count) plików") · \(Formats.size(Double(entry.size)))") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entry.files, id: \.self) { Text($0.lastPathComponent).font(.caption).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
            if let problem = model.problem(of: entry), entry.status == .ready {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var status: some View {
        switch entry.status {
        case .ready: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .uploading(let fraction):
            HStack(spacing: 6) {
                ProgressView(value: fraction).frame(width: 120)
                Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().font(.caption)
            }
            .accessibilityIdentifier("upload.progress")
        case .done: Label("Wgrano", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption).lineLimit(3)
                .accessibilityIdentifier("upload.error")
        }
    }
}
