import SwiftUI

/// Arkusz „Ustawienia biblioteki” (etap 9g) — to, co web UI ma w oknie edycji biblioteki:
/// nazwa, ikona, domyślne źródło metadanych, opcje wyświetlania i dopasowania, źródła skanera
/// z kolejnością, harmonogram skanu, „oznacz jako ukończone”, sklep iTunes podcastów
/// i usuwanie plików metadanych. Zapis jednym przyciskiem, tokenem root.
struct LibrarySettingsSheet: View {
    @State private var model: LibrarySettingsModel
    @State private var confirmRemove: String?
    @Environment(\.dismiss) private var dismiss

    init(account: ServerAccount, library: AudiobookshelfClient.Library) {
        _model = State(initialValue: LibrarySettingsModel(account: account, libraryID: library.id))
    }

    private enum ScheduleMode: Hashable { case disabled, daily, weekly, custom }

    var body: some View {
        Form {
            if model.settings != nil {
                general
                display
                if !model.isPodcast { scanner }
                schedule
                finished
                tools
            }
            Section { AdminStatusRows(status: model.status) }
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
        .confirmationDialog("Usunąć wszystkie pliki metadata.\(confirmRemove ?? "")?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), presenting: confirmRemove) { ext in
            Button("Usuń pliki", role: .destructive) { Task { await model.removeMetadataFiles(ext: ext) } }
            Button("Anuluj", role: .cancel) {}
        } message: { ext in
            Text("Serwer usunie pliki metadata.\(ext) z folderów wszystkich pozycji tej biblioteki. Metadane w bazie zostają; pliki powstaną znowu, jeśli w Ustawieniach serwera włączony jest zapis metadanych w folderach pozycji.")
        }
    }

    // MARK: Sekcje

    private var general: some View {
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
            if let folders = model.loaded?.folders, !folders.isEmpty {
                LabeledContent("Foldery") {
                    VStack(alignment: .trailing) {
                        ForEach(folders, id: \.id) { Text($0.fullPath).font(.caption).textSelection(.enabled) }
                    }
                }
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
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(index == 0)
                        .accessibilityLabel("Przesuń wyżej")
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(index == model.sources.count - 1)
                        .accessibilityLabel("Przesuń niżej")
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
            Picker("Harmonogram", selection: scheduleMode) {
                Text("Wyłączony").tag(ScheduleMode.disabled)
                Text("Codziennie").tag(ScheduleMode.daily)
                Text("Co tydzień").tag(ScheduleMode.weekly)
                if case .custom = model.schedule { Text("Własny (cron)").tag(ScheduleMode.custom) }
            }
            if case .weekly(let weekday, let hour, let minute) = model.schedule {
                Picker("Dzień", selection: Binding(get: { weekday }, set: { model.schedule = .weekly(weekday: $0, hour: hour, minute: minute) })) {
                    ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { Text(Self.weekdayName($0)).tag($0) }
                }
            }
            if let time = timeBinding {
                DatePicker("Godzina", selection: time, displayedComponents: .hourAndMinute)
            }
            if case .custom(let expression) = model.schedule {
                LabeledContent("Wyrażenie cron", value: expression)
            }
        }
    }

    private var finished: some View {
        Section {
            Picker("Oznacz jako ukończone, gdy", selection: $model.finishedRule) {
                Text("zostało do końca (sekundy)").tag(LibrarySettingsModel.FinishedRule.timeRemaining)
                Text("przesłuchano procent").tag(LibrarySettingsModel.FinishedRule.percentComplete)
            }
            LabeledContent(model.finishedRule == .timeRemaining ? "Sekundy do końca" : "Procent") {
                TextField("", value: $model.finishedValue, format: .number.precision(.fractionLength(0)))
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

    private func bind(_ key: WritableKeyPath<AudiobookshelfClient.LibrarySettings, Bool?>, default value: Bool) -> Binding<Bool> {
        Binding(get: { model.settings?[keyPath: key] ?? value }, set: { model.settings?[keyPath: key] = $0 })
    }

    private func bind(_ key: WritableKeyPath<AudiobookshelfClient.LibrarySettings, String?>, default value: String) -> Binding<String> {
        Binding(get: { model.settings?[keyPath: key] ?? value }, set: { model.settings?[keyPath: key] = $0 })
    }

    private var regions: [(String, String)] {
        AddPodcastSheet.countries(including: model.settings?.podcastSearchRegion ?? "us")
    }

    private var scheduleMode: Binding<ScheduleMode> {
        Binding(
            get: {
                switch model.schedule {
                case .disabled: .disabled
                case .daily: .daily
                case .weekly: .weekly
                case .custom: .custom
                }
            },
            set: { mode in
                let (hour, minute): (Int, Int) = switch model.schedule {
                case .daily(let h, let m), .weekly(_, let h, let m): (h, m)
                default: (3, 0)
                }
                switch mode {
                case .disabled: model.schedule = .disabled
                case .daily: model.schedule = .daily(hour: hour, minute: minute)
                case .weekly: model.schedule = .weekly(weekday: 1, hour: hour, minute: minute)
                case .custom: break
                }
            }
        )
    }

    private var timeBinding: Binding<Date>? {
        let current: (Int, Int)? = switch model.schedule {
        case .daily(let h, let m), .weekly(_, let h, let m): (h, m)
        default: nil
        }
        guard let current else { return nil }
        return Binding(
            get: { Calendar.current.date(bySettingHour: current.0, minute: current.1, second: 0, of: .now) ?? .now },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                let hour = parts.hour ?? 0, minute = parts.minute ?? 0
                switch model.schedule {
                case .daily: model.schedule = .daily(hour: hour, minute: minute)
                case .weekly(let weekday, _, _): model.schedule = .weekly(weekday: weekday, hour: hour, minute: minute)
                default: break
                }
            }
        )
    }

    static func weekdayName(_ day: Int) -> String {
        ["niedziela", "poniedziałek", "wtorek", "środa", "czwartek", "piątek", "sobota"][day % 7]
    }
}
