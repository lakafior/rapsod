import AudiobookshelfKit
import SwiftUI

/// Błąd, komunikat i postęp operacji podstrony administracyjnej.
struct AdminStatusRows: View {
    let status: AdminStatus

    var body: some View {
        if let error = status.error {
            Label(error, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        if let notice = status.notice {
            Label(notice, systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        }
        if let busy = status.busy {
            HStack {
                ProgressView().controlSize(.small)
                Text(busy).foregroundStyle(.secondary)
            }
        }
    }
}

/// Model podstrony administracyjnej tworzony, gdy konto root jest gotowe, i wczytywany przy wejściu.
struct AdminPage<Model: AnyObject, Content: View>: View {
    let account: ServerAccount
    let title: String
    let make: @MainActor () -> Model
    let load: @MainActor (Model) async -> Void
    @ViewBuilder let content: (Model) -> Content
    @State private var model: Model?

    var body: some View {
        SettingsForm {
            if account.state == .ready, let model {
                content(model)
            } else {
                Section(title) {
                    AdminUnavailableRow(account: account)
                }
            }
        }
        .task(id: account.state) {
            guard account.state == .ready else { return }
            let model = model ?? make()
            self.model = model
            await load(model)
        }
    }
}

/// Ustawienia serwera z `client/pages/config/index.vue`, które mają znaczenie przy serwerze
/// na tym Macu. Pominięte (dotyczą tylko web UI): Chromecast, iframe, CORS, widok półki,
/// format daty i godziny. Skaner, okładki, zapis w folderach, sortowanie i pamięć podręczna są
/// w Biblioteki › Zaawansowane (`LibraryServerSettingsSections`); tu został język serwera,
/// który w etapie 5 planu przejdzie do Ogólne › Zaawansowane.
struct ServerSettingsPage: View {
    let models: AppModels

    var body: some View {
        AdminPage(account: models.account, title: "Ustawienia serwera", make: { ServerSettingsModel(account: models.account) }, load: { await $0.load() }) { model in
            ServerLanguageSection(model: model)
        }
    }
}

/// Język serwera (S10).
struct ServerLanguageSection: View {
    let model: ServerSettingsModel

    var body: some View {
        Section {
            AdminStatusRows(status: model.status)
            if let settings = model.settings {
                Picker("Język serwera", selection: Binding(
                    get: { settings.language },
                    set: { value in Task { await model.update { $0.language = value } } }
                )) {
                    ForEach(ServerLanguage.options, id: \.code) { Text($0.label).tag($0.code) }
                    if !ServerLanguage.options.contains(where: { $0.code == settings.language }) {
                        Text(settings.language).tag(settings.language)
                    }
                }
                .disabled(model.status.isBusy)
            }
        } header: {
            Text("Język")
        } footer: {
            Text("Domyślny język web UI i tekstów, które serwer tworzy sam (np. nazwy półek). Aplikacja ma własny interfejs po polsku.")
        }
    }
}

/// Wspólne ustawienia serwera dla wszystkich bibliotek (Biblioteki › Zaawansowane): skaner i okładki,
/// zapis w folderach pozycji, sortowanie i pamięć podręczna. Każda zmiana idzie od razu na serwer.
struct LibraryServerSettingsSections: View {
    let model: ServerSettingsModel
    let supervisor: ServerSupervisor
    @State private var prefixes = ""
    @State private var confirmPurge = false

    var body: some View {
        if let settings = model.settings {
            Section {
                AdminStatusRows(status: model.status)
                toggle("Szukaj okładek, gdy pozycja ich nie ma", \.scannerFindCovers,
                       help: "Skaner pobiera okładkę od wybranego dostawcy, jeśli w folderze nie ma obrazu. Wydłuża skan.")
                if settings.scannerFindCovers {
                    Picker("Dostawca okładek", selection: binding(\.scannerCoverProvider)) {
                        ForEach(model.coverProviders) { Text($0.text).tag($0.value) }
                        if !model.coverProviders.contains(where: { $0.value == settings.scannerCoverProvider }) {
                            Text(settings.scannerCoverProvider).tag(settings.scannerCoverProvider)
                        }
                    }
                }
                toggle("Podtytuł z nazwy folderu", \.scannerParseSubtitle,
                       help: "Część nazwy folderu po „ - ” trafia do podtytułu, np. „Tytuł - Podtytuł”.")
                toggle("Dopasowane metadane mają pierwszeństwo", \.scannerPreferMatchedMetadata,
                       help: "Szybkie dopasowanie nadpisuje szczegóły pozycji danymi źródła (i okładkę, gdy ta jest z dopasowania).")
                Toggle(isOn: Binding(get: { !settings.scannerDisableWatcher }, set: { value in Task { await model.update { $0.scannerDisableWatcher = !value } } })) {
                    Text("Obserwuj foldery we wszystkich bibliotekach")
                    Text("Nowe i zmienione pliki są skanowane same. Bez obserwatora trzeba skanować biblioteki ręcznie; pojedynczą bibliotekę można wyłączyć na jej stronie.")
                }
                .disabled(model.status.isBusy)
                if model.watcherChangedSinceStart {
                    HStack {
                        Text("Zmiana obserwatora zadziała po ponownym uruchomieniu serwera.").foregroundStyle(.orange)
                        Spacer()
                        Button("Uruchom ponownie") {
                            Task {
                                await supervisor.restart()
                                model.serverRestarted()
                            }
                        }
                    }
                }
            } header: {
                Text("Skaner i okładki")
            }

            Section("Zapis w folderach pozycji") {
                toggle("Okładki w folderach pozycji", \.storeCoverWithItem,
                       help: "Nowe okładki trafiają do folderu książki jako „cover.*” zamiast do folderu danych serwera.")
                toggle("Plik metadata.json w folderach pozycji", \.storeMetadataWithItem,
                       help: "Szczegóły pozycji są zapisywane obok plików, więc przetrwają przeniesienie biblioteki na inny serwer.")
            }

            Section {
                toggle("Pomijaj przedrostki przy sortowaniu", \.sortingIgnorePrefix,
                       help: "Sortowanie po tytule pomija przedrostki, np. „The Hobbit” trafia pod H.")
                if settings.sortingIgnorePrefix {
                    HStack {
                        TextField("Przedrostki", text: $prefixes, prompt: Text(verbatim: "the, a"))
                            .onSubmit(savePrefixes)
                        Button("Zapisz", action: savePrefixes)
                            .disabled(model.status.isBusy || normalized(prefixes) == settings.sortingPrefixes)
                    }
                }
            } header: {
                Text("Sortowanie")
            } footer: {
                Text("Przedrostki oddzielaj przecinkami; wielkość liter nie ma znaczenia. Zapis przelicza tytuły wszystkich pozycji.")
            }

            Section {
                LabeledContent("Okładki i pliki tymczasowe") {
                    Button("Wyczyść…") { confirmPurge = true }
                        .disabled(model.status.isBusy)
                }
            } header: {
                Text("Pamięć podręczna")
            } footer: {
                Text("Serwer trzyma przeskalowane okładki i pliki tymczasowe w folderze danych (`metadata/cache`). Wyczyszczenie zwalnia miejsce; okładki odtworzą się przy następnym wyświetleniu.")
            }
            .confirmationDialog("Co wyczyścić?", isPresented: $confirmPurge) {
                Button("Tylko okładki pozycji", role: .destructive) { Task { await model.purgeCache(itemsOnly: true) } }
                Button("Całą pamięć podręczną", role: .destructive) { Task { await model.purgeCache(itemsOnly: false) } }
                Button("Anuluj", role: .cancel) {}
            } message: {
                Text("„Tylko okładki” usuwa przeskalowane okładki wszystkich pozycji. „Całą” usuwa cały folder metadata/cache: okładki, pliki tymczasowe i pozostałości przerwanych zadań (np. scalania do M4B).")
            }
            .onAppear { prefixes = settings.sortingPrefixes.joined(separator: ", ") }
            .onChange(of: settings.sortingPrefixes) { prefixes = settings.sortingPrefixes.joined(separator: ", ") }
        } else {
            Section("Ustawienia wspólne") {
                AdminStatusRows(status: model.status)
            }
        }
    }

    private func savePrefixes() {
        guard model.settings?.sortingPrefixes != normalized(prefixes) else { return }
        Task { await model.saveSortingPrefixes(prefixes) }
    }

    private func normalized(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { $0.lowercased() }
    }

    private func binding<T: Equatable & Sendable>(_ path: WritableKeyPath<AudiobookshelfClient.ServerSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings?[keyPath: path] ?? AudiobookshelfClient.ServerSettings()[keyPath: path] },
            set: { value in Task { await model.update { $0[keyPath: path] = value } } }
        )
    }

    private func toggle(_ title: String, _ path: WritableKeyPath<AudiobookshelfClient.ServerSettings, Bool>, help: String) -> some View {
        Toggle(isOn: binding(path)) {
            Text(title)
            Text(help)
        }
        .disabled(model.status.isBusy)
    }
}

/// Poziom logowania serwera (`logLevel`) na podstronie „Log serwera”.
struct ServerLogLevelPicker: View {
    let account: ServerAccount
    @State private var model: ServerSettingsModel?

    var body: some View {
        Group {
            if let model, let settings = model.settings {
                Picker("Poziom logu serwera", selection: Binding(
                    get: { settings.logLevel },
                    set: { value in Task { await model.update { $0.logLevel = value } } }
                )) {
                    Text("Śledzenie (trace)").tag(0)
                    Text("Diagnostyka (debug)").tag(1)
                    Text("Informacje").tag(2)
                    Text("Ostrzeżenia").tag(3)
                    Text("Błędy").tag(4)
                }
                .fixedSize()
                .disabled(model.status.isBusy)
                .help(model.status.error ?? "Ile szczegółów serwer wypisuje do logu. Zmiana działa od razu i zostaje po ponownym uruchomieniu.")
            }
        }
        .task(id: account.state) {
            guard account.state == .ready else { return }
            let model = model ?? ServerSettingsModel(account: account)
            self.model = model
            await model.load()
        }
    }
}

extension Formats {
    /// Data z godziną po polsku (listy kluczy, sesji i kanałów).
    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: "pl_PL")))
    }
}
