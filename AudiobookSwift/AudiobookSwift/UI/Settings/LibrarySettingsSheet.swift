import AppKit
import AudiobookshelfKit
import SwiftUI

/// Arkusz „Ustawienia biblioteki” (etap 9g) — to, co web UI ma w oknie edycji biblioteki:
/// nazwa, ikona, domyślne źródło metadanych, opcje wyświetlania i dopasowania, źródła skanera
/// z kolejnością, harmonogram skanu, „oznacz jako ukończone”, sklep iTunes podcastów
/// i usuwanie plików metadanych. Zapis jednym przyciskiem, tokenem root.
struct LibrarySettingsSheet: View {
    @State private var model: LibrarySettingsModel
    @State private var confirmRemove: String?
    @State private var folderToRemove: AudiobookshelfClient.Library.Folder?
    @Environment(\.dismiss) private var dismiss

    init(account: ServerAccount, library: AudiobookshelfClient.Library) {
        _model = State(initialValue: LibrarySettingsModel(account: account, libraryID: library.id))
    }

    var body: some View {
        Form {
            // Komunikaty na górze — dół długiego arkusza jest zwykle schowany.
            if model.status.isBusy || model.status.error != nil || model.status.notice != nil {
                Section { AdminStatusRows(status: model.status) }
            }
            if model.settings != nil {
                general
                display
                if !model.isPodcast { scanner }
                schedule
                finished
                tools
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Zapisz") {
                    Task { if await model.save() { dismiss() } }
                }
                .disabled(model.settings == nil || model.status.isBusy)
            }
        }
        .task { await model.load() }
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
            Text("Serwer usunie pliki metadata.\(ext) z folderów wszystkich pozycji tej biblioteki. Metadane w bazie zostają; pliki powstaną znowu, jeśli w Ustawieniach serwera włączony jest zapis metadanych w folderach pozycji.")
        }
    }

    // MARK: Sekcje

    @ViewBuilder private var general: some View {
        Section("Biblioteka") {
            TextField("Nazwa", text: $model.name)
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
                Text("Biblioteka może obejmować kilka folderów; zmiany zapisują się od razu.").foregroundStyle(.secondary)
            }
        }
    }

    private var display: some View {
        Section {
            Toggle("Kwadratowe okładki", isOn: Binding(
                get: { (model.settings?.coverAspectRatio ?? 1) == 1 },
                set: { model.settings?.coverAspectRatio = $0 ? 1 : 0 }
            ))
            Toggle("Obserwuj zmiany w folderze biblioteki", isOn: Binding(
                get: { model.settings?.disableWatcher != true },
                set: { model.settings?.disableWatcher = !$0 }
            ))
            if !model.isPodcast {
                Toggle("Tylko audiobooki (pomijaj pozycje z samym e-bookiem)", isOn: bind(\.audiobooksOnly, default: false))
                Toggle("Ukryj serie z jedną książką", isOn: bind(\.hideSingleBookSeries, default: false))
                Toggle("„Kontynuuj serię”: tylko książki dalsze niż przeczytane", isOn: bind(\.onlyShowLaterBooksInContinueSeries, default: false))
                Toggle("Pomijaj przy dopasowaniu książki z ASIN", isOn: bind(\.skipMatchingMediaWithAsin, default: false))
                Toggle("Pomijaj przy dopasowaniu książki z ISBN", isOn: bind(\.skipMatchingMediaWithIsbn, default: false))
                Toggle("Zezwalaj na skrypty w e-bookach EPUB", isOn: bind(\.epubsAllowScriptedContent, default: false))
            }
        } header: {
            Text("Wyświetlanie i dopasowanie")
        } footer: {
            if !model.isPodcast {
                Text("Skrypty w EPUB dotyczą czytnika web UI i aplikacji na telefon; czytnik w tej aplikacji zawsze je blokuje.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scanner: some View {
        Section {
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
                    Button("Przesuń wyżej", systemImage: "chevron.up") { move(index, by: -1) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless).disabled(index == 0)
                    Button("Przesuń niżej", systemImage: "chevron.down") { move(index, by: 1) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless).disabled(index == model.sources.count - 1)
                }
            }
        } header: {
            Text("Źródła metadanych skanera")
        } footer: {
            Text("Wyższe na liście wygrywa, gdy dwa źródła podają to samo pole. Wyłączone źródło skaner pomija.")
                .foregroundStyle(.secondary)
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard model.sources.indices.contains(target) else { return }
        model.sources.swapAt(index, target)
    }

    private var schedule: some View {
        Section("Automatyczny skan") {
            ScheduleRows(choice: $model.schedule, defaultTime: (3, 0), saved: model.savedSchedule)
        }
    }

    private var finished: some View {
        Section {
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
        } header: {
            Text("Ukończone")
        }
    }

    private var tools: some View {
        Section {
            HStack {
                Button("Usuń pliki metadata.json…") { confirmRemove = "json" }
                Button("Usuń pliki metadata.abs…") { confirmRemove = "abs" }
            }
            .disabled(model.status.isBusy)
        } header: {
            Text("Narzędzia")
        } footer: {
            Text("Usunięcie plików metadanych przydaje się, gdy przestarzałe pliki w folderach nadpisują metadane przy skanie.")
                .foregroundStyle(.secondary)
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
