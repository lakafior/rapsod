import AppKit
import AudiobookshelfKit
import SwiftUI

/// Podstrona biblioteki (Biblioteki › biblioteka; etap 4 planu, dawny arkusz „Ustawienia biblioteki”):
/// nazwa, ikona i źródło, foldery, wyświetlanie, skan z harmonogramem, „oznacz jako ukończone”,
/// pod „Zaawansowane” dopasowanie, e-booki, źródła skanera, pliki metadanych i kolejność, na dole
/// usunięcie biblioteki. Zmiany zapisują się same (`LibrarySettingsModel.draftChanged()`).
struct LibraryPage: View {
    let models: AppModels
    let libraryID: String
    @Environment(SettingsNavigation.self) private var navigation
    @State private var model: LibrarySettingsModel
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var confirmRemove: String?
    @State private var folderToRemove: AudiobookshelfClient.Library.Folder?
    @State private var confirmMatchAll = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var reordering = false

    init(models: AppModels, libraryID: String) {
        self.models = models
        self.libraryID = libraryID
        _model = State(initialValue: LibrarySettingsModel(account: models.account, libraryID: libraryID))
    }

    private var account: ServerAccount { models.account }
    private var tasks: LibraryTasks { models.libraryTasks }
    private var library: AudiobookshelfClient.Library? { account.libraries.first { $0.id == libraryID } }

    var body: some View {
        SettingsForm {
            if account.state != .ready {
                Section { AdminUnavailableRow(account: account) }
            } else {
                // Komunikaty na górze — dół długiej strony jest zwykle schowany.
                if model.status.isBusy || model.status.error != nil || model.status.notice != nil {
                    Section { AdminStatusRows(status: model.status) }
                }
                if model.settings != nil, let library {
                    general
                    folders
                    display
                    scanning(library)
                    finished
                    AdvancedSection(summary: advancedSummary) {
                        advanced(library)
                    }
                    removal(library)
                }
            }
        }
        .navigationSubtitle(library?.name ?? "Biblioteka")
        .task(id: account.state) {
            guard account.state == .ready else { return }
            tasks.resume()
            await model.load()
            name = model.name
        }
        .onChange(of: model.draft) { model.draftChanged() }
        // Postęp skanu: odpytywanie zadań trwa, dopóki jest otwarta lista albo ta podstrona.
        .onAppear { tasks.appear() }
        .onDisappear {
            tasks.disappear()
            commitName()
            Task { await model.saveNow() }
        }
        // Biblioteka zniknęła (usunięta tutaj albo w web UI) — wracamy do listy.
        .onChange(of: account.libraries.map(\.id)) {
            guard account.state == .ready, library == nil, !deleting else { return }
            tasks.forget(libraryID)
            navigation.path = []
        }
        .confirmationDialog("Usunąć folder z biblioteki?", item: $folderToRemove) { folder in
            Button("Usuń folder z biblioteki", role: .destructive) { Task { await model.removeFolder(folder) } }
            Button("Anuluj", role: .cancel) {}
        } message: { folder in
            Text("Pozycje z „\(folder.fullPath)” znikną z biblioteki razem z postępem słuchania, także na telefonie. Pliki zostaną na dysku nietknięte.")
        }
        .confirmationDialog("Usunąć wszystkie pliki metadata.\(confirmRemove ?? "")?", item: $confirmRemove) { ext in
            Button("Usuń pliki", role: .destructive) { Task { await model.removeMetadataFiles(ext: ext) } }
            Button("Anuluj", role: .cancel) {}
        } message: { ext in
            Text("Serwer usunie pliki metadata.\(ext) z folderów wszystkich pozycji tej biblioteki. Metadane w bazie zostają; pliki powstaną znowu, jeśli w Biblioteki › Zaawansowane włączony jest zapis metadanych w folderach pozycji.")
        }
    }

    private var advancedSummary: String {
        model.isPodcast
            ? "Pliki metadanych, kolejność bibliotek"
            : "Dopasowanie, e-booki, źródła metadanych skanera, pliki metadanych, kolejność bibliotek"
    }

    // MARK: Biblioteka

    @ViewBuilder private var general: some View {
        Section("Biblioteka") {
            TextField("Nazwa", text: $name)
                .focused($nameFocused)
                .onSubmit(commitName)
                .onChange(of: nameFocused) { if !nameFocused { commitName() } }
            Picker("Ikona", selection: $model.icon) {
                ForEach(LibrarySettingsModel.icons, id: \.id) { icon in
                    Label(icon.id, systemImage: icon.symbol).tag(icon.id)
                }
            }
            Picker(model.isPodcast ? "Źródło podcastów" : "Domyślne źródło metadanych", selection: $model.provider) {
                ForEach(model.providers, id: \.value) { Text($0.text).tag($0.value) }
            }
            if model.isPodcast {
                Picker("Sklep iTunes do wyszukiwania", selection: bind(\.podcastSearchRegion, default: "us")) {
                    ForEach(regions, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
        }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard model.settings != nil, trimmed != model.name else { return }
        if trimmed.isEmpty {
            // Pustej nazwy serwer nie przyjmie — wracamy do zapisanej.
            name = model.name
            return
        }
        model.name = trimmed
    }

    @ViewBuilder private var folders: some View {
        if let folders = model.loaded?.folders {
            Section {
                ForEach(folders, id: \.id) { folder in
                    HStack {
                        Label(folder.fullPath, systemImage: "folder").textSelection(.enabled)
                        Spacer()
                        Button("Pokaż w Finderze", systemImage: "magnifyingglass") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: folder.fullPath)])
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        Button("Usuń folder z biblioteki", systemImage: "minus.circle", role: .destructive) { folderToRemove = folder }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .disabled(folders.count < 2 || model.status.isBusy)
                            .help(folders.count < 2 ? "Biblioteka musi mieć co najmniej jeden folder" : "Usuń folder z biblioteki (pliki zostają)")
                    }
                }
                HStack {
                    Spacer()
                    Button("Dodaj folder…") {
                        Task {
                            guard let folder = await chooseLibraryFolder(for: model.isPodcast ? .podcasts : .audiobooks) else { return }
                            await model.addFolder(folder)
                        }
                    }
                    .disabled(model.status.isBusy)
                }
            } header: {
                Text("Foldery")
            } footer: {
                Text("Biblioteka może obejmować kilka folderów. Usunięcie folderu usuwa jego pozycje z biblioteki; pliki zostają na dysku.")
            }
        }
    }

    private var display: some View {
        Section("Wyświetlanie") {
            Toggle("Kwadratowe okładki", isOn: Binding(
                get: { (model.settings?.coverAspectRatio ?? 1) == 1 },
                set: { model.settings?.coverAspectRatio = $0 ? 1 : 0 }
            ))
            if !model.isPodcast {
                Toggle("Ukryj serie z jedną książką", isOn: bind(\.hideSingleBookSeries, default: false))
                Toggle("„Kontynuuj serię”: tylko książki dalsze niż przeczytane", isOn: bind(\.onlyShowLaterBooksInContinueSeries, default: false))
            }
        }
    }

    // MARK: Skanowanie

    private func scanning(_ library: AudiobookshelfClient.Library) -> some View {
        Section {
            if let activity = tasks.activities[libraryID] {
                LibraryActivityRow(activity: activity)
            }
            HStack {
                Spacer()
                Button("Skanuj") { tasks.scan(library, force: false) }
                Button("Wymuś pełny skan") { tasks.scan(library, force: true) }
                if !model.isPodcast {
                    Button("Dopasuj wszystkie…") { confirmMatchAll = true }
                }
            }
            .disabled(tasks.isRunning(libraryID) || account.isScanning || deleting)
            .confirmationDialog("Dopasować wszystkie książki w „\(library.name)”?", isPresented: $confirmMatchAll) {
                Button("Dopasuj wszystkie") { tasks.matchAll(library) }
                Button("Anuluj", role: .cancel) {}
            } message: {
                Text("Serwer wyszuka każdą książkę w domyślnym źródle metadanych tej biblioteki i uzupełni brakujące metadane i okładki. Przy wielu książkach trwa to długo; pojedyncze pozycje wygodniej dopasować w oknie „Biblioteka”.")
            }
            Toggle(isOn: Binding(
                get: { model.settings?.disableWatcher != true },
                set: { model.settings?.disableWatcher = !$0 }
            )) {
                Text("Obserwuj zmiany w folderze tej biblioteki")
                Text("Działa tylko, gdy obserwator jest włączony dla wszystkich bibliotek (Biblioteki › Zaawansowane).")
            }
            ScheduleRows(choice: $model.schedule, defaultTime: (3, 0), saved: model.savedSchedule)
        } header: {
            Text("Skanowanie")
        } footer: {
            Text("„Skanuj” dodaje nowe pliki i zauważa zmienione lub usunięte; „Wymuś pełny skan” czyta od nowa wszystkie pozycje. „Dopasuj wszystkie” uzupełnia metadane książek z domyślnego źródła biblioteki. Harmonogram to automatyczny skan o wybranej porze.")
        }
    }

    private var finished: some View {
        Section("Słuchanie") {
            Picker("Oznacz jako ukończone, gdy", selection: $model.finishedRule) {
                Text("zostało do końca (sekundy)").tag(LibrarySettingsModel.FinishedRule.timeRemaining)
                Text("przesłuchano procent").tag(LibrarySettingsModel.FinishedRule.percentComplete)
            }
            LabeledContent(finishedValueLabel) {
                TextField(finishedValueLabel, value: $model.finishedValue, format: .number.precision(.fractionLength(0)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
        }
    }

    // MARK: Zaawansowane

    @ViewBuilder
    private func advanced(_ library: AudiobookshelfClient.Library) -> some View {
        if !model.isPodcast {
            Toggle("Tylko audiobooki (pomijaj pozycje z samym e-bookiem)", isOn: bind(\.audiobooksOnly, default: false))
            Toggle("Pomijaj przy dopasowaniu książki z ASIN", isOn: bind(\.skipMatchingMediaWithAsin, default: false))
            Toggle("Pomijaj przy dopasowaniu książki z ISBN", isOn: bind(\.skipMatchingMediaWithIsbn, default: false))
            Toggle(isOn: bind(\.epubsAllowScriptedContent, default: false)) {
                Text("Zezwalaj na skrypty w e-bookach EPUB")
                Text("Dotyczy czytnika web UI i aplikacji na telefon; czytnik w tej aplikacji zawsze je blokuje.")
            }
            LabeledContent("Źródła metadanych skanera") {
                Text("wyższe wygrywa; wyłączone skaner pomija").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(model.sources.enumerated()), id: \.element.id) { index, source in
                let info = LibrarySettingsModel.metadataSources.first { $0.id == source.id }
                HStack {
                    Toggle(isOn: Binding(get: { model.sources[index].enabled }, set: { model.sources[index].enabled = $0 })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info?.title ?? source.id)
                            if let detail = info?.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    Button("Przesuń wyżej", systemImage: "chevron.up") { moveSource(index, by: -1) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless).disabled(index == 0)
                    Button("Przesuń niżej", systemImage: "chevron.down") { moveSource(index, by: 1) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless).disabled(index == model.sources.count - 1)
                }
            }
        }
        LabeledContent("Pliki metadanych w folderach pozycji") {
            HStack {
                Button("Usuń metadata.json…") { confirmRemove = "json" }
                Button("Usuń metadata.abs…") { confirmRemove = "abs" }
            }
            .disabled(model.status.isBusy)
        }
        Text("Przydaje się, gdy przestarzałe pliki w folderach nadpisują metadane przy skanie.")
            .font(.caption).foregroundStyle(.secondary)
        if account.libraries.count > 1, let index = account.libraries.firstIndex(of: library) {
            LabeledContent("Kolejność bibliotek") {
                ControlGroup {
                    Button("Wyżej", systemImage: "chevron.up") { moveLibrary(library, by: -1) }
                        .disabled(index == 0)
                    Button("Niżej", systemImage: "chevron.down") { moveLibrary(library, by: 1) }
                        .disabled(index == account.libraries.count - 1)
                }
                .fixedSize()
                .disabled(reordering)
            }
            .help("Kolejność bibliotek — ta sama w oknie „Biblioteka”, w telefonie i w web UI. Na liście bibliotek można też przeciągać wiersze.")
        }
    }

    private func moveSource(_ index: Int, by offset: Int) {
        let target = index + offset
        guard model.sources.indices.contains(target) else { return }
        model.sources.swapAt(index, target)
    }

    private func moveLibrary(_ library: AudiobookshelfClient.Library, by offset: Int) {
        reordering = true
        Task {
            defer { reordering = false }
            do {
                try await account.moveLibrary(library, by: offset)
            } catch {
                model.status.error = "Nie udało się zmienić kolejności bibliotek: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Usuwanie

    private func removal(_ library: AudiobookshelfClient.Library) -> some View {
        Section {
            HStack {
                Spacer()
                Button("Usuń bibliotekę…", role: .destructive) { confirmDelete = true }
                    .disabled(account.isScanning || deleting || tasks.isRunning(libraryID))
            }
        } footer: {
            Text("Biblioteka zniknie z serwera razem z postępem słuchania, kolekcjami i metadanymi jej pozycji. Pliki w folderze zostaną na dysku nietknięte.")
        }
        .confirmationDialog("Usunąć bibliotekę „\(library.name)”?", isPresented: $confirmDelete) {
            Button("Usuń bibliotekę", role: .destructive) { delete(library) }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Biblioteka zniknie z serwera razem z postępem słuchania, kolekcjami i metadanymi jej pozycji. Pliki w folderze zostaną na dysku nietknięte.")
        }
    }

    private func delete(_ library: AudiobookshelfClient.Library) {
        deleting = true
        Task {
            defer { deleting = false }
            do {
                try await account.removeLibrary(library)
                tasks.forget(libraryID)
                navigation.path = []
            } catch {
                model.status.error = "Nie udało się usunąć biblioteki „\(library.name)”: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Pomocnicze

    private var finishedValueLabel: String {
        model.finishedRule == .timeRemaining ? "Sekundy do końca" : "Procent"
    }

    private func bind(_ key: WritableKeyPath<AudiobookshelfClient.LibrarySettings, Bool?>, default value: Bool) -> Binding<Bool> {
        Binding(get: { model.settings?[keyPath: key] ?? value }, set: { model.settings?[keyPath: key] = $0 })
    }

    private func bind(_ key: WritableKeyPath<AudiobookshelfClient.LibrarySettings, String?>, default value: String) -> Binding<String> {
        Binding(get: { model.settings?[keyPath: key] ?? value }, set: { model.settings?[keyPath: key] = $0 })
    }

    private var regions: [(String, String)] {
        AddPodcastSheet.countries(including: model.settings?.podcastSearchRegion ?? "us")
    }
}
