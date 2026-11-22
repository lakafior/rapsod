import SwiftUI

/// Wynik arkusza wsadowego: tytuł i treść komunikatu albo `nil` (zamknięte bez zmian).
typealias BatchResult = (String, String)?

// MARK: - Edycja wsadowa

/// Edycja wielu książek naraz jak „Mapuj szczegóły” na stronie `batch` web UI: zaznaczone pola
/// trafiają do wszystkich pozycji; listy (autorzy, lektorzy, serie, gatunki, tagi) można
/// nadpisać albo dopisać do istniejących. Pozycję po pozycji edytuje zwykły arkusz książki.
struct BatchEditSheet: View {
    let browser: LibraryBrowser
    let items: [AudiobookshelfClient.LibraryItem]
    let done: (BatchResult) -> Void

    enum Field: String, CaseIterable, Identifiable {
        case subtitle, authors, narrators, series, genres, tags, publishedYear, publisher, language, explicit, abridged
        var id: String { rawValue }
        var isList: Bool { [.authors, .narrators, .series, .genres, .tags].contains(self) }
    }

    @State private var enabled: Set<Field> = []
    @State private var append = false
    @State private var subtitle = ""
    @State private var authors: [String] = []
    @State private var narrators: [String] = []
    @State private var series: [String] = []
    @State private var genres: [String] = []
    @State private var tags: [String] = []
    @State private var publishedYear = ""
    @State private var publisher = ""
    @State private var language = ""
    @State private var explicit = false
    @State private var abridged = false
    @State private var status = AdminStatus()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Picker("Listy", selection: $append) {
                    Text("Nadpisz").tag(false)
                    Text("Dopisz do istniejących").tag(true)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Zmień w zaznaczonych książkach (\(items.count))")
            } footer: {
                Text("Zmieniają się tylko pola z zaznaczonym polem wyboru. „Dopisz” dotyczy list: autorów, lektorów, serii, gatunków i tagów; pozostałe pola zawsze są nadpisywane.")
                    .foregroundStyle(.secondary)
            }
            Section {
                row(.subtitle, "Podtytuł") { TextField("", text: $subtitle).labelsHidden().accessibilityLabel("Podtytuł") }
                row(.authors, "Autorzy") { TokenInput(values: $authors, suggestions: (filterData?.authors ?? []).map(\.name), placeholder: "Imię i nazwisko") }
                row(.narrators, "Lektorzy") { TokenInput(values: $narrators, suggestions: filterData?.narrators ?? [], placeholder: "Lektor") }
                row(.series, "Serie") { TokenInput(values: $series, suggestions: (filterData?.series ?? []).map(\.name), placeholder: "Nazwa serii") }
                row(.genres, "Gatunki") { TokenInput(values: $genres, suggestions: filterData?.genres ?? [], placeholder: "Gatunek") }
                row(.tags, "Tagi") { TokenInput(values: $tags, suggestions: filterData?.tags ?? [], placeholder: "Tag") }
                row(.publishedYear, "Rok wydania") { TextField("", text: $publishedYear).labelsHidden().accessibilityLabel("Rok wydania") }
                row(.publisher, "Wydawca") { TextField("", text: $publisher).labelsHidden().accessibilityLabel("Wydawca") }
                row(.language, "Język") { TextField("", text: $language).labelsHidden().accessibilityLabel("Język") }
                row(.explicit, "Dla dorosłych") { Toggle("Dla dorosłych", isOn: $explicit).labelsHidden() }
                row(.abridged, "Skrócona") { Toggle("Skrócona", isOn: $abridged).labelsHidden() }
            } footer: {
                if enabled.contains(.series) {
                    Text("Numer tomu zostaje, jeśli książka już była w serii o tej nazwie.").foregroundStyle(.secondary)
                }
                if enabled.contains(.explicit), explicit {
                    Text("Konto słuchacza nie widzi treści dla dorosłych — te książki znikną z okna „Biblioteka” i z telefonu.")
                        .foregroundStyle(.orange)
                }
            }
            Section { AdminStatusRows(status: status) }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 640)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Zapisz") { Task { await save() } }
                    .disabled(enabled.isEmpty || status.isBusy)
            }
        }
        .task { await browser.loadFilterData() }
    }

    private var filterData: AudiobookshelfClient.FilterData? { browser.filterData }

    private func row<Content: View>(_ field: Field, _ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle(label, isOn: Binding(get: { enabled.contains(field) }, set: { if $0 { enabled.insert(field) } else { enabled.remove(field) } }))
                .toggleStyle(.checkbox)
                .frame(width: 130, alignment: .leading)
            content()
                .disabled(!enabled.contains(field))
                .opacity(enabled.contains(field) ? 1 : 0.5)
        }
    }

    /// Lista wynikowa: nadpisanie albo dopisanie bez powtórzeń (wielkość liter bez znaczenia).
    static func merge(_ existing: [String], _ new: [String], append: Bool) -> [String] {
        let new = new.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard append else { return new }
        var result = existing
        for value in new where !result.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { result.append(value) }
        return result
    }

    private func save() async {
        let ids = items.map(\.id)
        let ok = await status.run("Zapisywanie…", failure: "Nie udało się zapisać zmian") {
            let details = try await browser.manager.run { try await $0.batchItems(ids: ids, token: $1) }
            let updates = details.map { update(for: $0) }
            let changed = try await browser.manager.run { try await $0.batchUpdate(updates, token: $1) }
            status.notice = "Zmieniono \(changed) z \(updates.count)."
        }
        guard ok else { return }
        browser.invalidateFilterData()
        done(("Zapisano", status.notice ?? ""))
    }

    private func update(for item: AudiobookshelfClient.ItemDetail) -> AudiobookshelfClient.BatchUpdate {
        typealias M = AudiobookshelfClient.BatchMetadata
        let current = item.media.metadata
        var metadata = M()
        if enabled.contains(.subtitle) { metadata.subtitle = subtitle.trimmingCharacters(in: .whitespaces) }
        if enabled.contains(.authors) {
            metadata.authors = Self.merge((current.authors ?? []).map(\.name), authors, append: append).map(M.Named.init)
        }
        if enabled.contains(.narrators) { metadata.narrators = Self.merge(current.narrators ?? [], narrators, append: append) }
        if enabled.contains(.series) {
            let existing = current.series?.values ?? []
            let names = Self.merge(existing.map(\.name), series, append: append)
            metadata.series = names.map { name in
                M.SeriesEntry(name: name, sequence: existing.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.sequence)
            }
        }
        if enabled.contains(.genres) { metadata.genres = Self.merge(current.genres ?? [], genres, append: append) }
        if enabled.contains(.publishedYear) { metadata.publishedYear = publishedYear.trimmingCharacters(in: .whitespaces) }
        if enabled.contains(.publisher) { metadata.publisher = publisher.trimmingCharacters(in: .whitespaces) }
        if enabled.contains(.language) { metadata.language = language.trimmingCharacters(in: .whitespaces) }
        if enabled.contains(.explicit) { metadata.explicit = explicit }
        if enabled.contains(.abridged) { metadata.abridged = abridged }
        var payload = AudiobookshelfClient.BatchMediaPayload(metadata: metadata)
        if enabled.contains(.tags) { payload.tags = Self.merge(item.media.tags ?? [], tags, append: append) }
        return .init(id: item.id, mediaPayload: payload)
    }
}

// MARK: - Szybkie dopasowanie

/// `modals/BatchQuickMatchModel.vue`: dostawca i czy nadpisywać okładkę oraz szczegóły.
struct BatchQuickMatchSheet: View {
    let browser: LibraryBrowser
    let ids: [String]
    let done: (BatchResult) -> Void

    @State private var providers: [AudiobookshelfClient.SearchProvider] = []
    @State private var provider = ""
    @State private var overrideCover = false
    @State private var overrideDetails = false
    @State private var status = AdminStatus()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Picker("Źródło", selection: $provider) {
                    ForEach(providers) { Text($0.text).tag($0.value) }
                }
                Toggle("Zastąp istniejącą okładkę", isOn: $overrideCover)
                Toggle("Zastąp istniejące szczegóły", isOn: $overrideDetails)
                AdminStatusRows(status: status)
            } header: {
                Text("Szybkie dopasowanie (\(ids.count))")
            } footer: {
                Text("Serwer wyszuka każdą książkę po tytule i autorze (albo ASIN/ISBN) i weźmie pierwszy wynik. Bez „zastąp” uzupełnia tylko puste pola. Dopasowanie trwa w tle; zmienione pozycje odświeżą się same.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Dopasuj") { Task { await start() } }.disabled(provider.isEmpty || status.isBusy)
            }
        }
        .task {
            await status.run("Wczytywanie źródeł…", failure: "Nie udało się wczytać źródeł") {
                providers = try await browser.manager.loadProviders().books
            }
            provider = browser.library?.provider.flatMap { value in providers.contains { $0.value == value } ? value : nil } ?? providers.first?.value ?? ""
        }
    }

    private func start() async {
        let options = AudiobookshelfClient.QuickMatchOptions(provider: provider, overrideCover: overrideCover, overrideDetails: overrideDetails)
        let ids = ids
        let ok = await status.run("Zlecanie…", failure: "Nie udało się zlecić dopasowania") {
            try await browser.manager.run { try await $0.batchQuickMatch(ids: ids, options: options, token: $1) }
        }
        if ok { done(("Dopasowanie zlecone", "Serwer dopasowuje \(ids.count) poz. w tle.")) }
    }
}

// MARK: - Kolekcja

/// Dodanie zaznaczonych książek do istniejącej albo nowej kolekcji (`modals/collections/AddCreateModal.vue`).
struct BatchCollectionSheet: View {
    let browser: LibraryBrowser
    let ids: [String]
    let done: (BatchResult) -> Void

    @State private var collections: [AudiobookshelfClient.Collection] = []
    @State private var newName = ""
    @State private var status = AdminStatus()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Dodaj do kolekcji (\(ids.count))") {
                if collections.isEmpty, !status.isBusy {
                    Text("W tej bibliotece nie ma jeszcze kolekcji.").foregroundStyle(.secondary)
                }
                ForEach(collections) { collection in
                    HStack {
                        Text(collection.name)
                        Text("\(collection.books.elements.count)").foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Button("Dodaj") { Task { await add(to: collection) } }.disabled(status.isBusy)
                    }
                }
            }
            Section {
                HStack {
                    TextField("Nazwa nowej kolekcji", text: $newName)
                    Button("Utwórz") { Task { await create() } }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || status.isBusy)
                }
                AdminStatusRows(status: status)
            } footer: {
                Text("Kolekcje są wspólne dla wszystkich kont, które widzą tę bibliotekę.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } } }
        .task {
            guard let libraryID = browser.libraryID else { return }
            await status.run("Wczytywanie…", failure: "Nie udało się wczytać kolekcji") {
                collections = try await browser.listening.api { try await $0.collections(libraryID: libraryID, token: $1) }
            }
        }
    }

    private func add(to collection: AudiobookshelfClient.Collection) async {
        let ids = ids
        if await status.run("Dodawanie…", failure: "Nie udało się dodać do kolekcji", {
            try await browser.manager.run { try await $0.addToCollection(id: collection.id, books: ids, token: $1) }
        }) {
            done(("Dodano do kolekcji", "„\(collection.name)”: dodano \(ids.count) poz. (te, które już w niej były, zostają bez zmian)."))
        }
    }

    private func create() async {
        guard let libraryID = browser.libraryID else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        let ids = ids
        if await status.run("Tworzenie…", failure: "Nie udało się utworzyć kolekcji", {
            try await browser.manager.run { try await $0.createCollection(libraryID: libraryID, name: name, books: ids, token: $1) }
        }) {
            done(("Utworzono kolekcję", "„\(name)” z \(ids.count) poz."))
        }
    }
}

// MARK: - Playlista

/// Dodanie zaznaczonych do własnej playlisty konta słuchacza (istniejącej albo nowej).
struct BatchPlaylistSheet: View {
    let browser: LibraryBrowser
    let items: [AudiobookshelfClient.LibraryItem]
    let done: (BatchResult) -> Void

    @State private var newName = ""
    @State private var status = AdminStatus()
    @Environment(\.dismiss) private var dismiss

    private var entries: [AudiobookshelfClient.PlaylistEntry] { items.map { .init(libraryItemId: $0.id, episodeId: nil) } }

    var body: some View {
        Form {
            Section("Dodaj do playlisty (\(items.count))") {
                let playlists = browser.playlists ?? []
                if playlists.isEmpty, browser.playlists != nil {
                    Text("Nie masz jeszcze playlist w tej bibliotece.").foregroundStyle(.secondary)
                }
                ForEach(playlists) { playlist in
                    HStack {
                        Text(playlist.name)
                        Spacer()
                        Button("Dodaj") { Task { await add(to: playlist) } }.disabled(status.isBusy)
                    }
                }
            }
            Section {
                HStack {
                    TextField("Nazwa nowej playlisty", text: $newName)
                    Button("Utwórz") { Task { await create() } }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || status.isBusy)
                }
                AdminStatusRows(status: status)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } } }
        .task { if browser.playlists == nil { await browser.loadPlaylists() } }
    }

    private func add(to playlist: AudiobookshelfClient.Playlist) async {
        let entries = entries
        if await status.run("Dodawanie…", failure: "Nie udało się dodać do playlisty", {
            try await browser.listening.api { try await $0.addToPlaylist(id: playlist.id, entries: entries, token: $1) }
        }) {
            await browser.loadPlaylists()
            done(("Dodano do playlisty", "„\(playlist.name)”: dodano \(entries.count) poz."))
        }
    }

    private func create() async {
        guard let libraryID = browser.libraryID else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        let entries = entries
        if await status.run("Tworzenie…", failure: "Nie udało się utworzyć playlisty", {
            _ = try await browser.listening.api { try await $0.createPlaylist(libraryID: libraryID, name: name, items: entries, token: $1) }
        }) {
            await browser.loadPlaylists()
            done(("Utworzono playlistę", "„\(name)” z \(entries.count) poz."))
        }
    }
}
