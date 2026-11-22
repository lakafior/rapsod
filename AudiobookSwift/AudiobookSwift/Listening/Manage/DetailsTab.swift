import AppKit
import AudiobookshelfKit
import SwiftUI

/// Szkic szczegółów książki. Listy trzymają to, co wpisano (z ewentualnymi spacjami w trakcie
/// pisania), a porównanie i zapis biorą wersję oczyszczoną.
struct DetailsDraft {
    struct SeriesEntry: Identifiable {
        let id = UUID()
        var name: String
        var sequence: String
    }

    var title: String
    var subtitle: String
    var authors: [String]
    var narrators: [String]
    var series: [SeriesEntry]
    var publishedYear: String
    var publishedDate: String
    var publisher: String
    var language: String
    var isbn: String
    var asin: String
    var genres: [String]
    var tags: [String]
    /// Opis jako zwykły tekst (serwer trzyma HTML); wraca jako HTML tylko po zmianie.
    var description: String
    var explicit: Bool
    var abridged: Bool

    init(_ item: AudiobookshelfClient.ItemDetail) {
        let m = item.media.metadata
        title = m.title ?? ""
        subtitle = m.subtitle ?? ""
        authors = (m.authors ?? []).map(\.name)
        narrators = m.narrators ?? []
        series = (m.series?.values ?? []).map { SeriesEntry(name: $0.name, sequence: $0.sequence ?? "") }
        publishedYear = m.publishedYear ?? ""
        publishedDate = m.publishedDate ?? ""
        publisher = m.publisher ?? ""
        language = m.language ?? ""
        isbn = m.isbn ?? ""
        asin = m.asin ?? ""
        genres = m.genres ?? []
        tags = item.media.tags ?? []
        description = HTMLText.plain(m.description) ?? ""
        explicit = m.explicit ?? false
        abridged = m.abridged ?? false
    }

    static func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Bez pustych i bez powtórzeń (wielkość liter bez znaczenia — tak porównuje serwer autorów i serie).
    static func clean(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.map(clean).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private var cleanSeries: [AudiobookshelfClient.MediaUpdate.Metadata.Series] {
        var seen = Set<String>()
        return series.compactMap { entry in
            let name = Self.clean(entry.name)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            let sequence = Self.clean(entry.sequence)
            return .init(name: name, sequence: sequence.isEmpty ? nil : sequence)
        }
    }

    /// Powód, dla którego nie da się zapisać.
    var problem: String? {
        if Self.clean(title).isEmpty { return "Tytuł nie może być pusty." }
        if series.contains(where: { Self.clean($0.name).isEmpty && !Self.clean($0.sequence).isEmpty }) {
            return "Seria z numerem tomu musi mieć nazwę."
        }
        return nil
    }

    /// Tylko zmienione pola (zob. `MediaUpdate`).
    func update(from base: DetailsDraft) -> AudiobookshelfClient.MediaUpdate {
        var update = AudiobookshelfClient.MediaUpdate()
        func text(_ new: String, _ old: String) -> String? { Self.clean(new) == Self.clean(old) ? nil : Self.clean(new) }
        func list(_ new: [String], _ old: [String]) -> [String]? { Self.clean(new) == Self.clean(old) ? nil : Self.clean(new) }
        update.metadata.title = text(title, base.title)
        update.metadata.subtitle = text(subtitle, base.subtitle)
        update.metadata.authors = list(authors, base.authors).map { $0.map { .init(name: $0) } }
        update.metadata.narrators = list(narrators, base.narrators)
        let newSeries = cleanSeries, oldSeries = base.cleanSeries
        if newSeries.map(\.name) != oldSeries.map(\.name) || newSeries.map(\.sequence) != oldSeries.map(\.sequence) {
            update.metadata.series = newSeries
        }
        update.metadata.publishedYear = text(publishedYear, base.publishedYear)
        update.metadata.publishedDate = text(publishedDate, base.publishedDate)
        update.metadata.publisher = text(publisher, base.publisher)
        update.metadata.language = text(language, base.language)
        update.metadata.isbn = text(isbn, base.isbn)
        update.metadata.asin = text(asin, base.asin)
        update.metadata.genres = list(genres, base.genres)
        update.tags = list(tags, base.tags)
        if Self.clean(description) != Self.clean(base.description) {
            update.metadata.description = HTMLText.html(fromPlain: Self.clean(description))
        }
        if explicit != base.explicit { update.metadata.explicit = explicit }
        if abridged != base.abridged { update.metadata.abridged = abridged }
        return update
    }

    func isSame(as base: DetailsDraft) -> Bool { update(from: base).isEmpty }
}

extension HTMLText {
    /// Zwykły tekst → prosty HTML: akapity po pustej linii, `<br>` w akapicie.
    static func html(fromPlain text: String) -> String {
        guard !text.isEmpty else { return "" }
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return escaped.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "<p>" + $0.replacingOccurrences(of: "\n", with: "<br>") + "</p>" }
            .joined()
    }
}

/// Formularz szczegółów: wszystkie pola książki z podpowiedziami z danych filtrów biblioteki.
struct DetailsTab: View {
    @Bindable var model: ItemEditorModel

    private var filterData: AudiobookshelfClient.FilterData? { model.browser.filterData }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Tytuł", text: $model.details.title).accessibilityIdentifier("details.title")
                    TextField("Podtytuł", text: $model.details.subtitle).accessibilityIdentifier("details.subtitle")
                }
                Section {
                    LabeledContent("Autorzy") {
                        TokenInput(values: $model.details.authors, suggestions: (filterData?.authors ?? []).map(\.name), placeholder: "Imię i nazwisko, przecinek oddziela")
                            .accessibilityIdentifier("details.authors")
                    }
                    LabeledContent("Lektorzy") {
                        TokenInput(values: $model.details.narrators, suggestions: filterData?.narrators ?? [], placeholder: "Lektor")
                            .accessibilityIdentifier("details.narrators")
                    }
                }
                Section("Seria") {
                    ForEach($model.details.series) { $entry in
                        let id = entry.id
                        HStack {
                            TextField("Nazwa serii", text: $entry.name)
                                .accessibilityIdentifier("details.seriesName")
                                .textInputSuggestions {
                                    ForEach(Self.matches(entry.name, in: (filterData?.series ?? []).map(\.name)), id: \.self) { Text($0).textInputCompletion($0) }
                                }
                                .labelsHidden()
                            TextField("Tom", text: $entry.sequence, prompt: Text("Tom"))
                                .accessibilityIdentifier("details.seriesSequence")
                                .labelsHidden()
                                .frame(width: 70)
                            Button("Usuń serię", systemImage: "minus.circle") {
                                // `id` wzięte wcześniej: czytanie `entry` (wiązanie do tej tablicy) w trakcie jej zmiany to konflikt wyłączności.
                                model.details.series.removeAll { $0.id == id }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Dodaj serię", systemImage: "plus") {
                        model.details.series.append(.init(name: "", sequence: ""))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("details.addSeries")
                }
                Section {
                    TextField("Rok wydania", text: $model.details.publishedYear).accessibilityIdentifier("details.year")
                    TextField("Data wydania", text: $model.details.publishedDate, prompt: Text("RRRR-MM-DD"))
                        .accessibilityIdentifier("details.date")
                    TextField("Wydawca", text: $model.details.publisher)
                        .accessibilityIdentifier("details.publisher")
                        .textInputSuggestions {
                            ForEach(Self.matches(model.details.publisher, in: filterData?.publishers ?? []), id: \.self) { Text($0).textInputCompletion($0) }
                        }
                    TextField("Język", text: $model.details.language)
                        .accessibilityIdentifier("details.language")
                        .textInputSuggestions {
                            ForEach(Self.matches(model.details.language, in: filterData?.languages ?? []), id: \.self) { Text($0).textInputCompletion($0) }
                        }
                    TextField("ISBN", text: $model.details.isbn).accessibilityIdentifier("details.isbn")
                    TextField("ASIN", text: $model.details.asin).accessibilityIdentifier("details.asin")
                }
                Section {
                    LabeledContent("Gatunki") {
                        TokenInput(values: $model.details.genres, suggestions: filterData?.genres ?? [], placeholder: "Gatunek")
                            .accessibilityIdentifier("details.genres")
                    }
                    LabeledContent("Tagi") {
                        TokenInput(values: $model.details.tags, suggestions: filterData?.tags ?? [], placeholder: "Tag")
                            .accessibilityIdentifier("details.tags")
                    }
                    Toggle("Skrócona", isOn: $model.details.abridged).accessibilityIdentifier("details.abridged")
                    Toggle("Dla dorosłych", isOn: $model.details.explicit).accessibilityIdentifier("details.explicit")
                    if model.details.explicit, !model.detailsBase.explicit, model.listenerSeesExplicit == false {
                        Label("Konto słuchacza nie ma dostępu do treści dla dorosłych — po zapisie ta książka zniknie z jego biblioteki i z telefonu.", systemImage: "eye.slash")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                Section("Opis") {
                    TextEditor(text: $model.details.description)
                        .font(.body)
                        .frame(minHeight: 120)
                        .accessibilityLabel("Opis")
                        .accessibilityIdentifier("details.description")
                }
            }
            .formStyle(.grouped)
            HStack {
                if model.detailsDirty {
                    Text("Niezapisane zmiany").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Przywróć") { model.resetDetails() }
                    .disabled(!model.detailsDirty || model.isBusy)
                Button("Zapisz") {
                    // Kończy edycję pola: niezatwierdzony żeton (bez przecinka i Enter) trafia do szkicu.
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    Task { await model.saveDetails() }
                }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.detailsDirty || model.isBusy)
                    .accessibilityIdentifier("details.save")
            }
            .padding(.top, 10)
        }
    }

    /// Podpowiedzi: zawiera wpisany tekst (bez wielkości liter i znaków diakrytycznych), najwyżej 8.
    static func matches(_ text: String, in values: [String]) -> [String] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return Array(values.lazy.filter {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil && $0 != query
        }.prefix(8))
    }
}

/// Pole z żetonami (`NSTokenField`): wiele wartości, podpowiedzi przy pisaniu, przecinek albo
/// Enter kończy żeton. Rośnie w pionie, gdy żetony nie mieszczą się w jednej linii.
struct TokenInput: NSViewRepresentable {
    @Binding var values: [String]
    let suggestions: [String]
    var placeholder = ""

    func makeNSView(context: Context) -> NSTokenField {
        let field = ClickableTokenField()
        field.delegate = context.coordinator
        field.tokenStyle = .rounded
        field.placeholderString = placeholder
        field.completionDelay = 0.05
        field.objectValue = values
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        if Coordinator.tokens(of: field) != values {
            field.objectValue = values
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTokenField, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let height = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 22
        return CGSize(width: width, height: max(22, height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// Kliknięcie w pustą część pola (poza żetonami) w formularzu SwiftUI nie dawało kursora —
    /// pole samo staje się aktywne i stawia kursor na końcu.
    final class ClickableTokenField: NSTokenField {
        override func mouseDown(with event: NSEvent) {
            if currentEditor() == nil, let window, window.makeFirstResponder(self) {
                currentEditor()?.moveToEndOfDocument(nil)
                return
            }
            super.mouseDown(with: event)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: TokenInput

        init(parent: TokenInput) {
            self.parent = parent
        }

        static func tokens(of field: NSTokenField) -> [String] {
            ((field.objectValue as? [Any]) ?? []).compactMap { $0 as? String }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            parent.values = Self.tokens(of: field)
            field.invalidateIntrinsicContentSize()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            parent.values = Self.tokens(of: field)
        }

        func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String, indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            let taken = Set(Self.tokens(of: tokenField).map { $0.lowercased() })
            let found = parent.suggestions.filter {
                !taken.contains($0.lowercased()) && $0.range(of: substring, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            // Najpierw te, które zaczynają się od wpisanego tekstu.
            let sorted = found.sorted { a, b in
                let pa = a.range(of: substring, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
                let pb = b.range(of: substring, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
                return pa && !pb
            }
            selectedIndex?.pointee = -1
            return Array(sorted.prefix(12))
        }
    }
}
