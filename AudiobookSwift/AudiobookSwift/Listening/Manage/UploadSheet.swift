import AppKit
import AudiobookshelfKit
import SwiftUI
import UniformTypeIdentifiers

/// Wgrywanie książek do biblioteki (etap 9e, jak strona `upload` web UI): każdy upuszczony
/// folder to osobna książka, luźne pliki razem — jedna (decyzja użytkownika). Serwer kładzie
/// pliki w `<folder biblioteki>/<autor>/<seria>/<tytuł>` (podcast: `<tytuł>`) i niczego nie
/// skanuje; książkę dodaje obserwator plików, a gdy jest wyłączony — aplikacja zleca skan biblioteki.
@MainActor
@Observable
final class UploadModel {
    enum Status: Equatable, Sendable {
        case ready
        case checking
        case uploading(Double)
        case done
        case failed(String)
    }

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let files: [URL]
        var title: String
        var author: String
        var series: String
        var status: Status = .ready
        /// Liczony raz — postęp całej wysyłki odświeża się przy każdym kawałku.
        let size: Int64
        /// Nazwy plików na serwerze (lista w karcie) — też liczone raz, nie przy każdym kawałku postępu.
        let uploadNames: [String]

        init(files: [URL], title: String, author: String = "", series: String = "") {
            self.files = files
            self.title = title
            self.author = author
            self.series = series
            size = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0) }
            uploadNames = UploadGrouping.uploadNames(for: files)
        }
    }

    /// Rozszerzenia jak `SupportedFileTypes` w `client/plugins/constants.js`.
    nonisolated static let audio: Set<String> = ["m4b", "mp3", "m4a", "flac", "opus", "ogg", "oga", "mp4", "aac", "wma", "aiff", "aif", "wav", "webm", "webma", "mka", "awb", "caf", "mpeg", "mpg"]
    nonisolated static let supported: Set<String> = audio.union(["png", "jpg", "jpeg", "webp", "epub", "pdf", "mobi", "azw3", "cbr", "cbz", "nfo", "txt", "opf", "abs", "xml", "json"])

    // Bez odwołania do `LibraryBrowser` (to on trzyma ten model — nie robimy cyklu).
    private let manager: ItemManager
    private let listening: ListeningController
    var libraryID: String?
    var folderID: String?
    var entries: [Entry] = []
    /// Pominięte pliki (nieobsługiwany typ, ukryte).
    private(set) var skipped: [String] = []
    private(set) var isRunning = false
    private(set) var summary: String?
    /// Ile upuszczeń jeszcze się przegląda (foldery czytane poza głównym wątkiem).
    private(set) var scanning = 0
    var isScanning: Bool { scanning > 0 }
    @ObservationIgnored private var work: Task<Void, Never>?
    /// Ostatnie przeglądanie — następne czeka na nie, żeby pozycje trafiały na listę po kolei.
    @ObservationIgnored private var scan: Task<Void, Never>?

    init(browser: LibraryBrowser, urls: [URL]) {
        manager = browser.manager
        listening = browser.listening
        let current = browser.library
        libraryID = current?.id ?? libraries.first?.id
        folderID = library?.folders.first?.id
        add(urls)
    }

    /// Biblioteki dostępne do wgrania (te, które widzi okno).
    var libraries: [AudiobookshelfClient.Library] { listening.libraries }
    var library: AudiobookshelfClient.Library? { libraries.first { $0.id == libraryID } }
    var folder: AudiobookshelfClient.Library.Folder? { library?.folders.first { $0.id == folderID } ?? library?.folders.first }
    var isPodcast: Bool { library?.mediaType == "podcast" }
    var pending: [Entry] { entries.filter { $0.status != .done } }
    var isFinished: Bool { !entries.isEmpty && entries.allSatisfy { $0.status == .done } }

    /// Postęp całej wysyłki (bajty wysłane z bieżącej i zakończonych pozycji) — do paska narzędzi.
    var overallProgress: Double {
        let sizes = entries.map(\.size)
        let total = sizes.reduce(0, +)
        guard total > 0 else { return 0 }
        var sent: Int64 = 0
        for (entry, size) in zip(entries, sizes) {
            switch entry.status {
            case .done: sent += size
            case .uploading(let fraction): sent += Int64(Double(size) * fraction)
            default: break
            }
        }
        return Double(sent) / Double(total)
    }

    func libraryChanged() {
        folderID = library?.folders.first?.id
    }

    // MARK: Grupowanie

    /// Dokłada upuszczone albo wybrane pliki i foldery. Przeglądanie folderów (rekurencyjne,
    /// z rozmiarami plików) idzie poza głównym wątkiem; w tym czasie `isScanning`.
    /// W trakcie wysyłania też wolno dokładać — `start()` weźmie nowe pozycje na końcu.
    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let isPodcast = isPodcast
        let previous = scan
        scanning += 1
        scan = Task { [weak self] in
            await previous?.value
            let found = await UploadModel.entries(from: urls, isPodcast: isPodcast)
            guard let self else { return }
            entries += found.entries
            skipped += found.skipped
            scanning -= 1
        }
    }

    func remove(_ id: Entry.ID) {
        entries.removeAll { $0.id == id }
    }

    /// Pozycje z upuszczonych adresów: każdy folder to książka (albo kilka — `UploadGrouping`),
    /// luźne pliki razem jedna; podcast — cały folder to jeden podcast.
    @concurrent
    nonisolated private static func entries(from urls: [URL], isPodcast: Bool) async -> (entries: [Entry], skipped: [String]) {
        var entries: [Entry] = []
        var skipped: [String] = []
        var loose: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                var ignored: [String] = []
                let found: [Entry]
                if isPodcast {
                    let files = UploadGrouping.collect(in: url, supported: supported, ignored: &ignored)
                    found = files.isEmpty ? [] : [Entry(files: files, title: url.lastPathComponent)]
                } else {
                    found = UploadGrouping.books(in: url, path: [url.lastPathComponent], supported: supported, audio: audio, ignored: &ignored)
                        .map { Entry(files: $0.files, title: $0.title, author: $0.author, series: $0.series) }
                }
                skipped += ignored
                if found.isEmpty {
                    skipped.append(url.lastPathComponent + "/ (brak obsługiwanych plików)")
                } else {
                    entries += found
                }
            } else if supported.contains(url.pathExtension.lowercased()) {
                loose.append(url)
            } else {
                skipped.append(url.lastPathComponent)
            }
        }
        if !loose.isEmpty {
            let sorted = loose.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let first = sorted.first { audio.contains($0.pathExtension.lowercased()) } ?? sorted[0]
            entries.append(Entry(files: sorted, title: first.deletingPathExtension().lastPathComponent))
        }
        return (entries, skipped)
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
        !isRunning && !isScanning && library != nil && folder != nil && !pending.isEmpty
            && pending.allSatisfy { !Self.sanitize($0.title).isEmpty }
    }

    // MARK: Wysyłanie

    func begin() {
        guard work == nil else { return }
        work = Task { [weak self] in
            await self?.start()
            self?.work = nil
        }
    }

    /// Przerywa wysyłanie: zapytanie jest zrywane, serwer niczego nie przenosi (pliki trafiają
    /// do folderu biblioteki dopiero po odebraniu całości). Już wgrane książki zostają.
    func cancel() {
        work?.cancel()
    }

    private func start() async {
        guard canStart, let library, let folder else { return }
        isRunning = true
        summary = nil
        defer { isRunning = false }
        var uploaded = 0
        // Pętla po identyfikatorach, nie po zakresie indeksów z początku: pozycje dołożone
        // w trakcie wysyłania (`add`) też idą. W trakcie nie da się usuwać, więc indeksy się nie przesuwają.
        var attempted: Set<Entry.ID> = []
        while let index = entries.firstIndex(where: { $0.status != .done && !attempted.contains($0.id) }) {
            let entry = entries[index]
            attempted.insert(entry.id)
            // Dołożona w trakcie bez tytułu — zostaje na liście do poprawienia i ponownego „Wgraj”.
            guard !Self.sanitize(entry.title).isEmpty else { continue }
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
                let canceled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                entries[index].status = .failed(canceled ? "Anulowano — nic nie trafiło do biblioteki." : ItemManager.message(for: error, action: "Wysyłanie"))
            }
            if Task.isCancelled { break }
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
        let watching = try? await manager.run { try await $0.isWatcherActive(libraryID: library.id, token: $1) }
        if watching == true {
            return "\(what) Serwer doda ją do biblioteki „\(library.name)”, gdy obserwator plików ją wykryje (zwykle kilka sekund)."
        }
        do {
            try await manager.run { try await $0.scanLibrary(id: library.id, force: false, token: $1) }
            return "\(what) Obserwator plików jest wyłączony, więc zlecono skan biblioteki „\(library.name)”."
        } catch {
            return "\(what) " + ItemManager.message(for: error, action: "Nie udało się zlecić skanu — zeskanuj bibliotekę w ustawieniach")
        }
    }
}

/// Arkusz „Wgraj do biblioteki”.
struct UploadSheet: View {
    @Bindable var model: UploadModel
    @State private var isTargeted = false
    @State private var choosing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            destination
                .padding(16)
            Divider()
            if model.entries.isEmpty, model.isScanning {
                ProgressView("Przeglądanie folderów…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.entries.isEmpty {
                ContentUnavailableView {
                    Label("Upuść foldery albo pliki", systemImage: "square.and.arrow.down")
                } description: {
                    Text("Każdy folder to osobna książka, luźne pliki trafią do jednej.")
                } actions: {
                    Button("Wybierz…") { choosing = true }
                        .disabled(model.isScanning)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
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
            model.add(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        // Foldery i pliki naraz, kilka — jak dawny `NSOpenPanel` (pliki i foldery, wielokrotny wybór).
        // Aplikacja nie jest w piaskownicy, więc adresy czyta się wprost.
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder, .item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
        .fileDialogConfirmationLabel("Wybierz")
        .fileDialogMessage("Foldery z książkami albo pliki jednej książki")
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
                Button("Dodaj…") { choosing = true }.disabled(model.isRunning || model.isScanning)
            }
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("Przeglądanie folderów…").foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRunning {
                Button("Przerwij wysyłanie") { model.cancel() }
                    .accessibilityIdentifier("upload.cancel")
                // Wysyłanie trwa dalej, a postęp widać w pasku narzędzi okna.
                Button("Schowaj") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Wysyłanie będzie trwało dalej — postęp w pasku narzędzi okna")
                    .accessibilityIdentifier("upload.hide")
            } else {
                Button(model.isFinished ? "Zamknij" : "Anuluj") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if !model.isFinished {
                Button(model.pending.count > 1 ? "Wgraj \(model.pending.count)" : "Wgraj") {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    model.begin()
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
            DisclosureGroup("\(Formats.files(entry.files.count)) · \(Formats.size(Double(entry.size)))") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(zip(entry.files, entry.uploadNames)), id: \.0) { Text($0.1).font(.caption).lineLimit(1) }
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
