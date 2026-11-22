import SwiftUI

/// Stan dopasowania (żyje z arkuszem).
@MainActor
@Observable
final class MatchSearch {
    var provider = ""
    var title = ""
    var author = ""
    var results: [AudiobookshelfClient.BookMatch] = []
    var hasSearched = false
    var selected: AudiobookshelfClient.BookMatch?
    /// Pola do nadpisania przy wybranym wyniku.
    var chosen: Set<MatchField> = []
}

/// Pola, które dopasowanie może nadpisać (jak `selectedMatchUsage` w `Match.vue`).
enum MatchField: String, CaseIterable, Hashable {
    case cover, title, subtitle, author, narrator, series, publisher, publishedYear, language, genres, tags, isbn, asin, description, explicit, abridged

    var label: String {
        switch self {
        case .cover: "Okładka"
        case .title: "Tytuł"
        case .subtitle: "Podtytuł"
        case .author: "Autorzy"
        case .narrator: "Lektorzy"
        case .series: "Seria"
        case .publisher: "Wydawca"
        case .publishedYear: "Rok wydania"
        case .language: "Język"
        case .genres: "Gatunki"
        case .tags: "Tagi"
        case .isbn: "ISBN"
        case .asin: "ASIN"
        case .description: "Opis"
        case .explicit: "Dla dorosłych"
        case .abridged: "Skrócona"
        }
    }

    /// Pola odznaczone przez użytkownika zostają odznaczone przy następnym dopasowaniu (jak w web UI).
    static var unchecked: Set<MatchField> {
        get { Set((UserDefaults.standard.stringArray(forKey: "itemEditor.matchUnchecked") ?? []).compactMap(MatchField.init)) }
        set { UserDefaults.standard.set(newValue.map(\.rawValue).sorted(), forKey: "itemEditor.matchUnchecked") }
    }
}

/// Dopasowanie: wyszukiwanie u dostawcy (domyślnie dostawca biblioteki — zwykle wbudowane
/// „Źródła metadanych”), potem porównanie pole po polu i zapis zaznaczonych.
struct MatchTab: View {
    @Bindable var model: ItemEditorModel
    @State private var providers: [AudiobookshelfClient.SearchProvider] = []

    private var search: MatchSearch { model.match }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selected = search.selected {
                MatchComparison(model: model, match: selected, providerName: providerName(search.provider))
            } else {
                searchBar
                results
            }
        }
        .padding(.top, 12)
        .task { await prepare() }
    }

    private var searchBar: some View {
        HStack {
            Picker("Źródło", selection: Bindable(search).provider) {
                ForEach(providers) { Text($0.text).tag($0.value) }
            }
            .frame(maxWidth: 260)
            .accessibilityIdentifier("match.provider")
            TextField("Tytuł", text: Bindable(search).title, prompt: Text(search.provider.hasPrefix("audible") ? "Tytuł albo ASIN" : "Tytuł"))
                .onSubmit(runSearch)
                .accessibilityIdentifier("match.title")
            TextField("Autor", text: Bindable(search).author)
                .onSubmit(runSearch)
                .frame(maxWidth: 220)
                .accessibilityIdentifier("match.author")
            Button(search.hasSearched ? "Szukaj ponownie" : "Szukaj", action: runSearch)
                .keyboardShortcut(.defaultAction)
                .disabled(search.title.trimmingCharacters(in: .whitespaces).isEmpty || search.provider.isEmpty || model.isBusy)
                .accessibilityIdentifier("match.search")
        }
    }

    @ViewBuilder private var results: some View {
        if search.results.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if search.hasSearched {
                    Text("Brak wyników.").font(.headline)
                    Text("Pierwsze zapytanie po dłuższej przerwie budzi źródła metadanych i może nie zdążyć w limicie serwera (10 s) — wtedy wystarczy szukać ponownie. Pomaga też krótszy tytuł albo inne źródło.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Wyszukaj książkę u dostawcy metadanych i wybierz wynik — przed zapisem zobaczysz porównanie pól.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            Spacer()
        } else {
            List(search.results) { match in
                Button {
                    select(match)
                } label: {
                    MatchRow(match: match, source: providerName(search.provider))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("match.result")
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds()
        }
    }

    private func providerName(_ value: String) -> String {
        providers.first { $0.value == value }?.text ?? value
    }

    private func prepare() async {
        if search.title.isEmpty {
            let base = model.detailsBase
            search.title = base.title
            search.author = base.authors.first ?? ""
        }
        guard providers.isEmpty else { return }
        do {
            providers = try await model.manager.loadProviders().books
        } catch {
            model.message = .init(text: ItemManager.message(for: error, action: "Nie udało się wczytać listy źródeł"), isError: true)
            return
        }
        if search.provider.isEmpty {
            let libraryProvider = model.browser.library?.provider
            search.provider = providers.first { $0.value == libraryProvider }?.value
                ?? providers.first { $0.value.hasPrefix("custom-") }?.value
                ?? providers.first?.value ?? "google"
            // Audible szuka najcelniej po ASIN (jak w web UI).
            if search.provider.hasPrefix("audible"), !model.detailsBase.asin.isEmpty { search.title = model.detailsBase.asin }
        }
    }

    private func runSearch() {
        let title = search.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !search.provider.isEmpty else { return }
        let provider = search.provider, author = search.author.trimmingCharacters(in: .whitespaces), id = model.item.id
        Task {
            await model.perform("Szukanie u „\(providerName(provider))”…", failure: "Wyszukiwanie nie powiodło się") {
                let found = try await model.manager.run { try await $0.searchBooks(provider: provider, title: title, author: author, itemID: id, token: $1) }
                search.results = found
                search.hasSearched = true
                return nil
            }
        }
    }

    private func select(_ match: AudiobookshelfClient.BookMatch) {
        let available = MatchComparison.fields(of: match)
        search.chosen = available.subtracting(MatchField.unchecked)
        search.selected = match
    }
}

private struct MatchRow: View {
    let match: AudiobookshelfClient.BookMatch
    let source: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteThumbnail(url: match.cover.flatMap(URL.init(string:)), size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(match.title ?? "").font(.headline)
                if let subtitle = match.subtitle { Text(subtitle).foregroundStyle(.secondary) }
                let people = [match.authors.joined(separator: ", "), match.narrators.isEmpty ? "" : "czyta: " + match.narrators.joined(separator: ", ")].filter { !$0.isEmpty }
                if !people.isEmpty { Text(people.joined(separator: " · ")).font(.callout) }
                let facts = [match.publishedYear, match.publisher, match.duration.map { Formats.duration($0 * 60) },
                             match.series.first.map { s in s.sequence.map { "\(s.name) #\($0)" } ?? s.name }].compactMap { $0 }
                if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary) }
                Text(source).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Porównanie obecnych wartości z wynikiem i wybór pól do nadpisania.
private struct MatchComparison: View {
    @Bindable var model: ItemEditorModel
    let match: AudiobookshelfClient.BookMatch
    let providerName: String
    @State private var confirmDiscard = false

    private var search: MatchSearch { model.match }
    private var current: DetailsDraft { model.detailsBase }

    /// Pola z niepustą wartością w wyniku (jak w `Match.vue` — puste się nie pojawiają).
    static func fields(of match: AudiobookshelfClient.BookMatch) -> Set<MatchField> {
        Set(MatchField.allCases.filter { field in
            switch field {
            case .explicit: match.explicit != nil
            case .abridged: match.abridged != nil
            default: !(newValue(field, match) ?? "").isEmpty
            }
        })
    }

    static func newValue(_ field: MatchField, _ m: AudiobookshelfClient.BookMatch) -> String? {
        switch field {
        case .cover: m.cover
        case .title: m.title
        case .subtitle: m.subtitle
        case .author: m.authors.joined(separator: ", ")
        case .narrator: m.narrators.joined(separator: ", ")
        case .series: m.series.map { s in s.sequence.map { "\(s.name) #\($0)" } ?? s.name }.joined(separator: ", ")
        case .publisher: m.publisher
        case .publishedYear: m.publishedYear
        case .language: m.language
        case .genres: m.genres.joined(separator: ", ")
        case .tags: m.tags.joined(separator: ", ")
        case .isbn: m.isbn
        case .asin: m.asin
        case .description: HTMLText.plain(m.description)
        case .explicit: m.explicit.map { $0 ? "tak" : "nie" }
        case .abridged: m.abridged.map { $0 ? "tak" : "nie" }
        }
    }

    private func currentValue(_ field: MatchField) -> String {
        switch field {
        case .cover: ""
        case .title: current.title
        case .subtitle: current.subtitle
        case .author: current.authors.joined(separator: ", ")
        case .narrator: current.narrators.joined(separator: ", ")
        case .series: current.series.map { $0.sequence.isEmpty ? $0.name : "\($0.name) #\($0.sequence)" }.joined(separator: ", ")
        case .publisher: current.publisher
        case .publishedYear: current.publishedYear
        case .language: current.language
        case .genres: current.genres.joined(separator: ", ")
        case .tags: current.tags.joined(separator: ", ")
        case .isbn: current.isbn
        case .asin: current.asin
        case .description: current.description
        case .explicit: current.explicit ? "tak" : "nie"
        case .abridged: current.abridged ? "tak" : "nie"
        }
    }

    var body: some View {
        let fields = MatchField.allCases.filter(Self.fields(of: match).contains)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Wróć do wyników", systemImage: "chevron.left") { search.selected = nil }
                    .accessibilityIdentifier("match.back")
                Spacer()
                Text("Wynik z: \(providerName)").font(.callout).foregroundStyle(.secondary)
                Toggle("Zaznacz wszystko", isOn: Binding(
                    get: { search.chosen.isSuperset(of: fields) },
                    set: { search.chosen = $0 ? Set(fields) : [] }
                ))
                .accessibilityIdentifier("match.all")
            }
            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("")
                        Text("Pole")
                        Text("Teraz")
                        Text("Z wyniku")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(fields, id: \.self) { field in
                        GridRow {
                            Toggle(field.label, isOn: Binding(
                                get: { search.chosen.contains(field) },
                                set: { if $0 { search.chosen.insert(field) } else { search.chosen.remove(field) } }
                            ))
                            .labelsHidden()
                            .accessibilityIdentifier("match.use.\(field.rawValue)")
                            Text(field.label).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                            if field == .cover {
                                AsyncCover(listening: model.listening, itemID: model.item.id, path: model.item.media.coverPath, size: 90)
                                    .frame(width: 90, height: 90).clipShape(RoundedRectangle(cornerRadius: 4))
                                RemoteThumbnail(url: match.cover.flatMap(URL.init(string:)), size: 90)
                            } else {
                                value(currentValue(field), dimmed: true)
                                value(Self.newValue(field, match) ?? "", dimmed: !search.chosen.contains(field))
                            }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                Text("Nadpisane zostaną tylko zaznaczone pola. Okładka jest pobierana po zapisie danych.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Zastosuj (\(search.chosen.intersection(fields).count))") {
                    if model.detailsDirty { confirmDiscard = true } else { apply() }
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(search.chosen.intersection(fields).isEmpty || model.isBusy)
                    .accessibilityIdentifier("match.apply")
            }
        }
        .confirmationDialog("Odrzucić niezapisane zmiany w szczegółach?", isPresented: $confirmDiscard) {
            Button("Zastosuj dopasowanie", role: .destructive) { apply() }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Po zastosowaniu dopasowania zakładka „Szczegóły” pokaże dane z serwera; zmiany wpisane tam i niezapisane przepadną.")
        }
    }

    private func value(_ text: String, dimmed: Bool) -> some View {
        Text(text.isEmpty ? "—" : text)
            .lineLimit(4)
            .foregroundStyle(dimmed ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private func apply() {
        let fields = Self.fields(of: match)
        let chosen = search.chosen.intersection(fields)
        MatchField.unchecked = fields.subtracting(chosen).union(MatchField.unchecked.subtracting(fields))
        var update = AudiobookshelfClient.MediaUpdate()
        var meta = AudiobookshelfClient.MediaUpdate.Metadata()
        for field in chosen {
            switch field {
            case .cover: break
            case .title: meta.title = match.title
            case .subtitle: meta.subtitle = match.subtitle
            case .author: meta.authors = match.authors.map { .init(name: $0) }
            case .narrator: meta.narrators = match.narrators
            case .series: meta.series = match.series.map { .init(name: $0.name, sequence: $0.sequence) }
            case .publisher: meta.publisher = match.publisher
            case .publishedYear: meta.publishedYear = match.publishedYear
            case .language: meta.language = match.language
            case .genres: meta.genres = match.genres
            case .tags: update.tags = match.tags
            case .isbn: meta.isbn = match.isbn
            case .asin: meta.asin = match.asin
            case .description: meta.description = match.description
            case .explicit: meta.explicit = match.explicit
            case .abridged: meta.abridged = match.abridged
            }
        }
        update.metadata = meta
        let cover = chosen.contains(.cover) ? match.cover : nil
        Task { await model.applyMatch(update, coverURL: cover) }
    }
}
