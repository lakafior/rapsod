import AppKit
import AudiobookshelfKit
import SwiftUI
import UniformTypeIdentifiers

/// Karta „Tekst książki” na stronie audiobooka (etap 11a): dodanie e-booka do folderu książki
/// i synchronizacja tekstu z nagraniem, z postępem w krokach.
struct TextSyncSection: View {
    let browser: LibraryBrowser
    let item: AudiobookshelfClient.ItemDetail

    @State private var map: TextSyncMap?
    @State private var importing = false
    @State private var replaceSource: URL?
    @State private var adding = false
    @State private var message: Message?
    @State private var audiobooksOnly = false

    private struct Message: Identifiable {
        let title: String
        let text: String
        var id: String { title + text }
    }

    private var sync: TextSyncController { browser.listening.textSync }
    private var hasAudio: Bool { !(item.media.tracks?.elements.isEmpty ?? true) }

    var body: some View {
        if !item.isPodcast, hasAudio {
            card
                .frame(maxWidth: 760, alignment: .leading)
                .task(id: "\(item.media.ebookFile?.ino ?? "-")/\(sync.mapRevision[item.id] ?? 0)") {
                    map = await TextSyncController.loadMap(for: item)
                }
                .task(id: item.libraryId) { await loadLibrarySettings() }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.epub]) { result in
                    if case .success(let url) = result { add(url, replace: false) }
                }
                .confirmationDialog("W folderze książki jest już „\(AddEbook.targetName(for: item)).epub”", isPresented: Binding(get: { replaceSource != nil }, set: { if !$0 { replaceSource = nil } })) {
                    Button("Zastąp (stary plik do Kosza)") { if let url = replaceSource { add(url, replace: true) } }
                    Button("Anuluj", role: .cancel) {}
                } message: {
                    Text("Serwer nie pokazuje go jako e-booka książki — może jeszcze nie był zeskanowany. Zastąpienie przenosi obecny plik do Kosza.")
                }
                .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                    Button("OK") {}
                } message: {
                    Text(message?.text ?? "")
                }
        }
    }

    // MARK: - Karta

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Tekst książki", systemImage: "text.book.closed")
                .font(.headline)
            if let job = sync.job(item.id) {
                JobView(job: job, sync: sync, retry: startSync)
            } else if item.media.ebookFile == nil {
                addPrompt
            } else if let map {
                summary(map)
            } else {
                syncPrompt
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("book.textsync")
    }

    @ViewBuilder private var addPrompt: some View {
        Text("Dodaj e-book (EPUB) tej książki, żeby czytać go w aplikacji i zsynchronizować tekst z nagraniem. Plik trafi do folderu książki jako „\(AddEbook.targetName(for: item)).epub”.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        let reason = addUnavailableReason
        HStack(spacing: 10) {
            Button {
                importing = true
            } label: {
                if adding {
                    Label { Text("Dodawanie…") } icon: { ProgressView().controlSize(.small) }
                } else {
                    Label("Dodaj e-book…", systemImage: "plus")
                }
            }
            .disabled(reason != nil || adding)
            .accessibilityIdentifier("textsync.addEbook")
            if let reason {
                Text(reason).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var addUnavailableReason: String? {
        if item.isFile == true || item.path == nil { return "Ta pozycja to pojedynczy plik bez własnego folderu." }
        if audiobooksOnly { return "Biblioteka ma włączone „tylko audiobooki”, więc serwer pominie e-book. Zmień to w ustawieniach biblioteki." }
        return nil
    }

    @ViewBuilder private var syncPrompt: some View {
        let reason = TextSyncController.unavailableReason(item)
        let minutes = max(1, Int(((item.media.duration ?? 0) / 80 / 60).rounded(.up)))
        Text(reason ?? "Tekst e-booka nie jest jeszcze zsynchronizowany z nagraniem. Rozpoznawanie mowy działa na tym Macu, bez internetu — ta książka zajmie około \(minutes) min. Aplikacja może w tym czasie działać w tle.")
            .foregroundStyle(reason == nil ? .secondary : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
        syncButton(title: "Synchronizuj e-book", prominent: true)
    }

    private func syncButton(title: String, prominent: Bool) -> some View {
        let reason = TextSyncController.unavailableReason(item)
        let busyOther = sync.activeJob.map { $0.itemID != item.id } ?? false
        return Button(action: startSync) {
            Label(title, systemImage: "waveform.and.magnifyingglass")
        }
        .modifier(ProminentIf(prominent))
        .disabled(reason != nil || busyOther)
        .help(busyOther ? "Trwa synchronizacja „\(sync.activeJob?.title ?? "")” — jedna naraz." : (reason ?? "Rozpoznaj mowę i dopasuj ją do zdań e-booka"))
        .accessibilityIdentifier("textsync.start")
    }

    @ViewBuilder private func summary(_ map: TextSyncMap) -> some View {
        let stats = map.stats
        Label("Tekst zsynchronizowany z nagraniem", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        Text("\(stats.timedFraction.formatted(.percent.precision(.fractionLength(0)))) zdań ma swoje miejsce w nagraniu · \(languageName(map.locale)) · \(map.createdAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: "pl_PL")))))")
            .font(.callout)
            .foregroundStyle(.secondary)
        if stats.timedFraction < 0.8 {
            Label("Mało zdań znalazło się w nagraniu — e-book może być innym wydaniem niż audiobook.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
        }
        if TextSyncController.isStale(map, item: item) {
            Label("Pliki książki zmieniły się od synchronizacji.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
        }
        syncButton(title: "Synchronizuj ponownie", prominent: TextSyncController.isStale(map, item: item))
            .controlSize(.small)
    }

    private func languageName(_ bcp47: String) -> String {
        SpeechTranscription.displayName(Locale(identifier: bcp47))
    }

    // MARK: - Akcje

    private func startSync() {
        let manager = browser.manager
        let listening = browser.listening
        let item = item
        sync.clear(itemID: item.id)
        sync.start(item: item) {
            guard manager.isAvailable else {
                return "Mapa jest w folderze książki; serwer doda ją przy najbliższym skanie."
            }
            do {
                _ = try await manager.run { try await $0.scanItem(id: item.id, token: $1) }
                listening.libraryChanged(item.libraryId)
                return nil
            } catch {
                return "Mapa jest zapisana w folderze książki, ale skan pozycji się nie udał: \(error.localizedDescription)"
            }
        }
    }

    private func add(_ source: URL, replace: Bool) {
        replaceSource = nil
        adding = true
        Task {
            defer { adding = false }
            do {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                try AddEbook.copy(source, into: item, replace: replace)
            } catch AddEbook.Problem.exists {
                replaceSource = source
                return
            } catch {
                message = Message(title: "Nie udało się dodać e-booka", text: error.localizedDescription)
                return
            }
            let manager = browser.manager
            guard manager.isAvailable else {
                message = Message(title: "E-book dodany", text: "Plik jest w folderze książki. Serwer pokaże go po najbliższym skanie.")
                return
            }
            do {
                _ = try await manager.run { try await $0.scanItem(id: item.id, token: $1) }
                browser.listening.libraryChanged(item.libraryId)
            } catch {
                message = Message(title: "E-book dodany", text: "Plik jest w folderze książki, ale skan pozycji się nie udał: \(ItemManager.message(for: error, action: "Ponowny skan"))")
            }
        }
    }

    private func loadLibrarySettings() async {
        let id = item.libraryId
        if let details = try? await browser.listening.api({ try await $0.libraryDetails(id: id, token: $1) }) {
            audiobooksOnly = details.settings.audiobooksOnly == true
        }
    }
}

private struct ProminentIf: ViewModifier {
    let prominent: Bool
    init(_ prominent: Bool) { self.prominent = prominent }
    func body(content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}

// MARK: - Postęp

private struct JobView: View {
    let job: TextSyncController.Job
    let sync: TextSyncController
    let retry: () -> Void

    var body: some View {
        switch job.phase {
        case .running(let step):
            running(step)
        case .finished(let stats):
            VStack(alignment: .leading, spacing: 6) {
                Label("Gotowe: \(stats.timedFraction.formatted(.percent.precision(.fractionLength(0)))) zdań ma swoje miejsce w nagraniu", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(stats.direct.formatted()) zdań z dopasowanych słów, \(stats.interpolated.formatted()) z interpolacji, \(stats.untimed.formatted()) bez czasu (przypisy, strony redakcyjne — lektor ich nie czyta). Rozpoznawanie i dopasowanie trwało \(Formats.duration(Date.now.timeIntervalSince(job.startedAt))).")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if stats.timedFraction < 0.8 {
                    Label("Mało zdań znalazło się w nagraniu — e-book może być innym wydaniem niż audiobook.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let note = job.note { Text(note).font(.callout).foregroundStyle(.orange) }
                Button("OK") { sync.clear(itemID: job.itemID) }
                    .controlSize(.small)
                    .accessibilityIdentifier("textsync.done")
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Spróbuj ponownie", action: retry)
                    Button("Zamknij") { sync.clear(itemID: job.itemID) }
                }
                .controlSize(.small)
            }
        case .canceled:
            HStack {
                Text("Przerwano — w folderze książki nic się nie zmieniło.").foregroundStyle(.secondary)
                Button("Zamknij") { sync.clear(itemID: job.itemID) }.controlSize(.small)
            }
        }
    }

    private func running(_ current: TextSyncController.Step) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ForEach(TextSyncController.Step.allCases, id: \.self) { step in
                    HStack(spacing: 5) {
                        Group {
                            if step < current {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else if step == current {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "circle").foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 14, height: 14)
                        Text(step.title)
                            .foregroundStyle(step == current ? .primary : .secondary)
                            .fontWeight(step == current ? .semibold : .regular)
                    }
                    .font(.callout)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Krok: \(current.title)")

            HStack(spacing: 10) {
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .animation(.easeOut(duration: 0.4), value: job.progress)
                Text(job.progress.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .frame(minWidth: 40, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Postęp synchronizacji")
            .accessibilityValue(job.progress.formatted(.percent.precision(.fractionLength(0))))

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if let detail = job.detail { Text(detail) }
                    HStack(spacing: 6) {
                        if let language = job.language { Text("Język: \(language)") }
                        if let remaining = job.remaining, current == .transcribe {
                            Text("· zostało ok. \(Self.remaining(remaining))")
                        }
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Przerwij", role: .cancel) { sync.cancel(itemID: job.itemID) }
                    .controlSize(.small)
                    .accessibilityIdentifier("textsync.cancel")
            }
        }
    }

    private static func remaining(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(max(5, Int(seconds / 5) * 5)) s" }
        return "\(Int((seconds / 60).rounded(.up))) min"
    }
}

// MARK: - Dodanie e-booka

/// Kopiowanie EPUB-a do folderu książki pod nazwą książki: nazwa jedynego pliku audio
/// (np. „Autor - Tytuł.m4b” → „Autor - Tytuł.epub”), a przy wielu plikach — tytuł.
enum AddEbook {
    enum Problem: LocalizedError {
        case exists
        case noFolder
        var errorDescription: String? {
            switch self {
            case .exists: "Plik o tej nazwie już jest w folderze książki."
            case .noFolder: "Pozycja nie ma własnego folderu."
            }
        }
    }

    static func targetName(for item: AudiobookshelfClient.ItemDetail) -> String {
        let audio = (item.media.audioFiles?.elements ?? []).filter { $0.exclude != true }
        if audio.count == 1, let name = audio[0].metadata?.filename {
            return (name as NSString).deletingPathExtension
        }
        let name = item.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return name.isEmpty ? "E-book" : name
    }

    static func copy(_ source: URL, into item: AudiobookshelfClient.ItemDetail, replace: Bool) throws {
        guard item.isFile != true, let path = item.path else { throw Problem.noFolder }
        let target = URL(filePath: path, directoryHint: .isDirectory).appending(path: targetName(for: item) + ".epub")
        let fm = FileManager.default
        // Wskazany plik już leży w folderze książki pod tą nazwą — wystarczy skan.
        if source.standardizedFileURL.resolvingSymlinksInPath() == target.standardizedFileURL.resolvingSymlinksInPath() { return }
        if fm.fileExists(atPath: target.path) {
            guard replace else { throw Problem.exists }
            try fm.trashItem(at: target, resultingItemURL: nil)
        }
        try fm.copyItem(at: source, to: target)
    }
}
