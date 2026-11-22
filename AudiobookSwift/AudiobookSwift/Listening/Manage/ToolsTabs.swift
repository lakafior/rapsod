import AudiobookshelfKit
import SwiftUI

/// Plik audio w edycji kolejności (zakładka „Pliki”). Kolejność = kolejność w tablicy.
struct FileDraft: Identifiable, Equatable {
    let ino: String
    let name: String
    let relPath: String?
    let duration: Double?
    let size: Double?
    let codec: String?
    let track: Int?
    let disc: Int?
    var exclude: Bool
    var id: String { ino }

    /// Jak w `TracksTable` upstreamu: najpierw pliki w książce według indeksu, potem wykluczone.
    static func list(_ item: AudiobookshelfClient.ItemDetail) -> [FileDraft] {
        let files = item.media.audioFiles?.elements ?? []
        return files
            .sorted { a, b in
                let ai = (a.exclude == true ? Int.max : (a.index ?? Int.max))
                let bi = (b.exclude == true ? Int.max : (b.index ?? Int.max))
                return ai != bi ? ai < bi : (a.metadata?.filename ?? "").localizedStandardCompare(b.metadata?.filename ?? "") == .orderedAscending
            }
            .map { file in
                FileDraft(
                    ino: file.ino,
                    name: file.metadata?.filename ?? file.ino,
                    relPath: file.metadata?.relPath,
                    duration: file.duration,
                    size: file.metadata?.size,
                    codec: file.codec,
                    track: file.trackNumFromMeta ?? file.trackNumFromFilename,
                    disc: file.discNumFromMeta ?? file.discNumFromFilename,
                    exclude: file.exclude == true
                )
            }
    }
}

/// Kolejność i wykluczanie plików audio (`PATCH /api/items/:id/tracks`, modal „Pliki” w web UI).
struct FilesTab: View {
    @Bindable var model: ItemEditorModel
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Przeciągnij, żeby zmienić kolejność. Odznaczone pliki zostają na dysku, ale nie należą do książki.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Menu("Sortuj") {
                    Button("Według nazwy pliku") { sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
                    Button("Według numeru ścieżki") {
                        sort { a, b in
                            let ka = (a.disc ?? 0, a.track ?? Int.max)
                            let kb = (b.disc ?? 0, b.track ?? Int.max)
                            return ka != kb ? ka < kb : a.name.localizedStandardCompare(b.name) == .orderedAscending
                        }
                    }
                }
                .fixedSize()
                .disabled(model.isBusy)
            }
            List(selection: $selection) {
                ForEach($model.files) { $file in
                    FileRow(file: $file, number: number(of: file))
                        .tag(file.id)
                }
                .onMove { model.files.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .accessibilityIdentifier("files.list")
            HStack(spacing: 6) {
                Button("W górę", systemImage: "arrow.up") { moveSelection(by: -1) }
                    .disabled(selection.isEmpty || model.isBusy)
                Button("W dół", systemImage: "arrow.down") { moveSelection(by: 1) }
                    .disabled(selection.isEmpty || model.isBusy)
                Spacer()
                let included = model.files.filter { !$0.exclude }
                Text("W książce: \(included.count) z \(model.files.count) · \(Formats.duration(included.compactMap(\.duration).reduce(0, +)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .labelStyle(.iconOnly)
            if model.listening.isLoaded(itemID: model.item.id) {
                Label("Ta książka jest w odtwarzaczu — zapis ją zatrzyma.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SaveBar(dirty: model.filesDirty, busy: model.isBusy, reset: model.resetFiles) {
                Task { await model.saveFiles() }
            }
        }
        .padding(.top, 8)
    }

    /// Numer w książce (wykluczone nie mają).
    private func number(of file: FileDraft) -> Int? {
        guard !file.exclude else { return nil }
        return (model.files.prefix { $0.id != file.id }.filter { !$0.exclude }.count) + 1
    }

    private func sort(_ order: (FileDraft, FileDraft) -> Bool) {
        let included = model.files.filter { !$0.exclude }.sorted(by: order)
        let excluded = model.files.filter(\.exclude).sorted(by: order)
        model.files = included + excluded
    }

    private func moveSelection(by step: Int) {
        var files = model.files
        let indices = files.indices.filter { selection.contains(files[$0].id) }
        for index in (step < 0 ? indices : indices.reversed()) {
            let target = index + step
            guard files.indices.contains(target), !selection.contains(files[target].id) else { continue }
            files.swapAt(index, target)
        }
        model.files = files
    }
}

private struct FileRow: View {
    @Binding var file: FileDraft
    let number: Int?

    var body: some View {
        HStack(spacing: 10) {
            Toggle("W książce", isOn: Binding(get: { !file.exclude }, set: { file.exclude = !$0 }))
                .labelsHidden()
                .help(file.exclude ? "Dołącz do książki" : "Wyklucz z książki")
            Text(number.map(String.init) ?? "—").monospacedDigit().foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).lineLimit(1).foregroundStyle(file.exclude ? .secondary : .primary)
                if let relPath = file.relPath, relPath != file.name {
                    Text(relPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .help(file.relPath ?? file.name)
            Spacer()
            if let track = file.track { Text("ścieżka \(track)").font(.caption).foregroundStyle(.tertiary) }
            Text(file.codec ?? "").font(.caption).foregroundStyle(.secondary).frame(width: 44)
            Text(Formats.size(file.size)).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            Text(ChapterScrubber.time(file.duration ?? 0)).monospacedDigit().frame(width: 70, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.name)\(file.exclude ? ", wykluczony" : "")")
    }
}

/// Osadzenie metadanych i scalenie do M4B (`manage.vue`). Zadania działają na serwerze;
/// postęp pokazuje `ItemTaskStatus` — tu i na stronie książki, więc arkusz można zamknąć.
struct ToolsTab: View {
    @Bindable var model: ItemEditorModel
    @AppStorage("tools.embedBackup") private var backup = true
    @State private var options = AudiobookshelfClient.EncodeOptions()
    @State private var confirm: Kind?
    @State private var error: String?
    @State private var optionsReady = false

    private enum Kind: Identifiable {
        case embed, encode
        var id: Self { self }
    }

    private var tasks: ItemTasks { model.manager.tasks }
    private var job: ItemTasks.Job? { tasks.job(model.item.id) }
    private var busy: Bool { job?.isActive == true }
    private var audioFiles: [AudiobookshelfClient.AudioFileEntry] {
        (model.item.media.audioFiles?.elements ?? []).filter { $0.exclude != true }
    }
    /// Jak w `EncoderOptionsCard.vue`: same pliki AAC → „copy” bez ponownego kodowania.
    private var allAAC: Bool { !audioFiles.isEmpty && audioFiles.allSatisfy { $0.codec == "aac" } }
    private var isPlaying: Bool { model.listening.isLoaded(itemID: model.item.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.item.isMissing == true {
                    Label("Pliki tej pozycji zniknęły z dysku — narzędzia są niedostępne.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let job {
                    ItemTaskStatus(tasks: tasks, itemID: model.item.id, job: job, fileName: fileName)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Zapisuje tytuł, autora, opis, okładkę i inne metadane z biblioteki w tagach każdego pliku audio. Przy jednym pliku zapisuje też rozdziały. Pliki zostają przepisane na miejscu.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Zrób kopię zapasową plików", isOn: $backup)
                            .accessibilityIdentifier("tools.backup")
                        Text(backup
                             ? "Kopie trafią do folderu podręcznego serwera (metadata/cache/items/\(model.item.id))."
                             : "Bez kopii: oryginalnych tagów nie da się przywrócić.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button("Osadź metadane…") { confirm = .embed }
                                .disabled(!canRun)
                                .accessibilityIdentifier("tools.embed")
                        }
                    }
                    .padding(6)
                } label: {
                    Text("Osadzenie metadanych w plikach").font(.headline)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Łączy \(Formats.files(audioFiles.count)) audio w jeden plik M4B z rozdziałami, okładką i metadanymi. Oryginały serwer przenosi do folderu podręcznego (metadata/cache/items/\(model.item.id)) — nie są kasowane, ale znikają z folderu książki.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                            GridRow {
                                Text("Kodek").foregroundStyle(.secondary)
                                Picker("Kodek", selection: $options.codec) {
                                    Text("Kopiuj (bez kodowania)").tag("copy")
                                    Text("AAC").tag("aac")
                                    Text("Opus").tag("opus")
                                }
                                .labelsHidden().fixedSize()
                                .accessibilityIdentifier("tools.codec")
                            }
                            GridRow {
                                Text("Bitrate").foregroundStyle(.secondary)
                                Picker("Bitrate", selection: $options.bitrate) {
                                    ForEach(["32k", "64k", "128k", "192k"], id: \.self) { Text($0.replacingOccurrences(of: "k", with: " kb/s")).tag($0) }
                                }
                                .labelsHidden().fixedSize()
                                .disabled(options.codec == "copy")
                            }
                            GridRow {
                                Text("Kanały").foregroundStyle(.secondary)
                                Picker("Kanały", selection: $options.channels) {
                                    Text("1 (mono)").tag(1)
                                    Text("2 (stereo)").tag(2)
                                }
                                .labelsHidden().fixedSize()
                                .disabled(options.codec == "copy")
                            }
                        }
                        if options.codec == "copy", !allAAC {
                            Label("„Kopiuj” działa tylko, gdy wszystkie pliki są już w AAC — tu nie są, wybierz AAC.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Spacer()
                            Button("Scal do M4B…") { confirm = .encode }
                                .disabled(!canRun || (options.codec == "copy" && !allAAC))
                                .accessibilityIdentifier("tools.encode")
                        }
                    }
                    .padding(6)
                } label: {
                    Text("Scalenie do M4B").font(.headline)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            tasks.appear()
            guard !optionsReady else { return }
            optionsReady = true
            if allAAC { options.codec = "copy" }
            if let channels = audioFiles.compactMap(\.channels).max(), channels == 1 { options.channels = 1 }
        }
        .onDisappear { tasks.disappear() }
        .confirmationDialog(confirmTitle, item: $confirm) { kind in
            Button(kind == .embed ? "Osadź metadane" : "Scal do M4B") { run(kind) }
            Button("Anuluj", role: .cancel) {}
        } message: { kind in
            Text(confirmMessage(kind))
        }
    }

    private var canRun: Bool {
        model.manager.isAvailable && !busy && model.item.isMissing != true && !audioFiles.isEmpty && !model.filesDirty
    }

    private var confirmTitle: String {
        confirm == .encode ? "Scalić „\(model.item.title)” do M4B?" : "Osadzić metadane w plikach „\(model.item.title)”?"
    }

    private func confirmMessage(_ kind: Kind) -> String {
        var text = kind == .encode
            ? "Powstanie jeden plik M4B w folderze książki, a oryginały (\(Formats.files(audioFiles.count))) serwer przeniesie do folderu podręcznego. Zadanie można anulować."
            : "Pliki audio zostaną przepisane" + (backup ? ", kopie trafią do folderu podręcznego serwera." : " bez kopii zapasowej.")
        if isPlaying { text += " Odtwarzanie tej książki zostanie zatrzymane." }
        return text
    }

    private func fileName(_ ino: String) -> String? {
        model.item.media.audioFiles?.elements.first { $0.ino == ino }?.metadata?.filename
    }

    private func run(_ kind: Kind) {
        error = nil
        let id = model.item.id
        let backup = backup
        let options = options
        Task {
            await model.listening.release(itemID: id)
            do {
                switch kind {
                case .embed: try await tasks.embed(itemID: id, backup: backup)
                case .encode: try await tasks.encode(itemID: id, options: options)
                }
            } catch {
                self.error = ItemManager.message(for: error, action: kind == .embed ? "Nie udało się zlecić osadzenia" : "Nie udało się zlecić scalenia")
            }
        }
    }
}

/// Stan zadania pozycji: postęp, przetwarzany plik, anulowanie scalania, wynik.
struct ItemTaskStatus: View {
    let tasks: ItemTasks
    let itemID: String
    let job: ItemTasks.Job
    var fileName: (String) -> String? = { _ in nil }
    @State private var canceling = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                icon
                Text(title).font(.callout.weight(.medium))
                Spacer()
                if job.kind == .encode, job.isActive {
                    Button("Anuluj") { cancel() }
                        .disabled(canceling)
                        .accessibilityIdentifier("tools.cancel")
                } else if !job.isActive {
                    Button("OK") { tasks.dismiss(itemID) }
                        .accessibilityIdentifier("tools.dismiss")
                }
            }
            if job.isActive {
                if let progress = job.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .padding(10)
        .frame(maxWidth: 760, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tools.status")
    }

    @ViewBuilder private var icon: some View {
        switch job.phase {
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .ended: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        case .canceled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default: ProgressView().controlSize(.small)
        }
    }

    private var title: String {
        switch job.phase {
        case .requested: "\(job.kind.title): zlecanie…"
        case .queued: "\(job.kind.title): w kolejce serwera"
        case .running:
            "\(job.kind.title)" + (job.progress.map { " — \($0.formatted(.percent.precision(.fractionLength(0))))" } ?? "…")
        case .finished: job.kind == .encode ? "Scalono do M4B. Oryginały są w folderze podręcznym serwera." : "Metadane osadzone w plikach."
        case .ended: "\(job.kind.title): zakończone, ale serwer nie podał wyniku. Sprawdź pliki książki (i log serwera)."
        case .canceled: "\(job.kind.title) anulowane."
        case .failed(let message): "\(job.kind.title) nie powiodło się. \(message)"
        }
    }

    private var detail: String? {
        guard let ino = job.currentFile, let name = fileName(ino) else { return nil }
        return "Plik: \(name)"
    }

    private func cancel() {
        canceling = true
        Task {
            defer { canceling = false }
            do {
                try await tasks.cancelEncode(itemID: itemID)
            } catch {
                self.error = ItemManager.message(for: error, action: "Nie udało się anulować")
            }
        }
    }
}
