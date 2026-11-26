import AppKit
import AudiobookshelfKit
import SwiftUI

/// Wiersz listy to miejsce na liście, nie pozycja: lista stronicowana zna liczbę pozycji przed
/// wczytaniem stron, więc wiersze istnieją od razu, a treść dochodzi, gdy strona się wczyta.
/// Stały identyfikator sprawia też, że wczytanie strony nie przebudowuje całej tabeli.
struct ListRow: Identifiable, Hashable {
    let id: Int

    /// Jeden styl wszystkich list biblioteki: `.automatic` wychodził różnie zależnie od miejsca
    /// w oknie (pełna szerokość albo zaokrąglone paski).
    static var style: InsetTableStyle { InsetTableStyle(alternatesRowBackgrounds: true) }
}

/// Sortowanie kolumny po kluczu serwera. Tabela tylko pokazuje kierunek i zgłasza kliknięcie
/// w nagłówek — porządek wierszy ustala serwer (albo `ItemTable.sorted` dla list bez stron).
struct ColumnSort: SortComparator, Hashable {
    let key: String
    var order: SortOrder = .forward

    init(_ key: String, order: SortOrder = .forward) {
        self.key = key
        self.order = order
    }

    func compare(_ lhs: ListRow, _ rhs: ListRow) -> ComparisonResult { .orderedSame }
}

/// Zapamiętane szerokości, kolejność i widoczność kolumn (`UserDefaults`, bo okno nie
/// przywraca stanu sceny).
enum ColumnStore {
    static func load(_ name: String) -> TableColumnCustomization<ListRow> {
        guard let data = UserDefaults.standard.data(forKey: key(name)),
              let value = try? JSONDecoder().decode(TableColumnCustomization<ListRow>.self, from: data) else { return .init() }
        return value
    }

    static func save(_ value: TableColumnCustomization<ListRow>, _ name: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key(name)) }
    }

    private static func key(_ name: String) -> String { "libraryWindow.columns.\(name)" }
}

extension Binding where Value == LibraryBrowser.Sort {
    /// Nagłówki tabeli ↔ sortowanie przeglądarki (to samo, co w menu „Sortowanie”).
    var columnOrder: Binding<[ColumnSort]> {
        Binding<[ColumnSort]>(get: { [ColumnSort(wrappedValue.key, order: wrappedValue.descending ? .reverse : .forward)] },
                              set: { if let first = $0.first { wrappedValue = .init(key: first.key, descending: first.order == .reverse) } })
    }
}

/// Lista pozycji jak w Finderze (etap 14c): `Table` z kolumnami do sortowania i ukrywania
/// (menu podręczne nagłówka), zaznaczaniem wielu wierszy, menu podręcznym jak na kartach
/// i otwieraniem podwójnym kliknięciem albo Return. Na macOS `Table` to `NSTableView`, która
/// używa ponownie komórek, więc pamięć nie rośnie z przewijaniem.
struct ItemTable: View {
    let browser: LibraryBrowser
    let count: Int
    let item: (Int) -> AudiobookshelfClient.LibraryItem?
    /// Miejsca wczytanych pozycji o danych identyfikatorach (zaznaczenie z `browser.selection`).
    let indices: (Set<String>) -> Set<Int>
    var ensureLoaded: (Int) -> Void = { _ in }
    /// Sortowanie nagłówkami; `nil` — kolejność z serwera bez zmiany (np. wyniki wyszukiwania).
    var sort: Binding<LibraryBrowser.Sort>?
    /// Strona serii: kolumna serii pokazuje numer tomu w tej serii i sortuje po nim.
    var seriesID: String?
    /// Zaznaczanie razem z trybem „Zaznacz” i paskiem działań (etap 9h); `nil` — zaznaczenie
    /// tylko w tej liście.
    var selectionScope: String?

    @State private var bookColumns = ColumnStore.load("books")
    @State private var podcastColumns = ColumnStore.load("podcasts")
    @State private var localSelection = Set<Int>()

    private var listening: ListeningController { browser.listening }
    private var rows: [ListRow] { (0..<count).map(ListRow.init) }

    var body: some View {
        Group {
            if browser.isPodcastLibrary { podcastTable } else { bookTable }
        }
        .tableStyle(ListRow.style)
        .contextMenu(forSelectionType: ListRow.ID.self) { selected in
            menu(for: selected)
        } primaryAction: { selected in
            if let index = selected.min(), let item = item(index) { browser.open(.item(item.id)) }
        }
        .onChange(of: bookColumns) { ColumnStore.save(bookColumns, "books") }
        .onChange(of: podcastColumns) { ColumnStore.save(podcastColumns, "podcasts") }
        .accessibilityIdentifier("itemTable")
    }

    // MARK: Kolumny

    private var sortOrder: Binding<[ColumnSort]> {
        sort?.columnOrder ?? .constant([])
    }

    private var bookTable: some View {
        Table(rows, selection: selection, sortOrder: sortOrder, columnCustomization: $bookColumns) {
            TableColumn("Tytuł", sortUsing: ColumnSort("media.metadata.title")) { row in titleCell(row.id) }
                .width(min: 120, ideal: 170)
                .customizationID("title")
                .disabledCustomizationBehavior(.visibility)
            TableColumn("Autor", sortUsing: ColumnSort("media.metadata.authorName")) { row in
                text(item(row.id)?.media.metadata.authorName)
            }
            .width(min: 60, ideal: 110)
            .customizationID("author")
            TableColumn("Lektor") { row in text(item(row.id)?.media.metadata.narratorName) }
                .width(min: 60, ideal: 100)
                .customizationID("narrator")
            if let seriesID {
                TableColumn("Tom", sortUsing: ColumnSort("sequence")) { row in
                    text(item(row.id)?.sequence(in: seriesID).map { "#\($0)" })
                }
                .width(min: 40, ideal: 50)
                .customizationID("sequence")
            }
            if seriesID == nil {
                TableColumn("Seria") { row in text(seriesText(item(row.id))) }
                    .width(min: 60, ideal: 140)
                    .customizationID("series")
                    .defaultVisibility(.hidden)
            }
            TableColumn("Rok", sortUsing: ColumnSort("media.metadata.publishedYear")) { row in
                text(item(row.id)?.media.metadata.publishedYear).monospacedDigit()
            }
            .width(min: 40, ideal: 50)
            .customizationID("year")
            .defaultVisibility(.hidden)
            TableColumn("Czas", sortUsing: ColumnSort("media.duration")) { row in
                text(item(row.id).map { Formats.duration($0.media.duration) }).monospacedDigit()
            }
            .width(min: 50, ideal: 70)
            .customizationID("duration")
            TableColumn("Postęp") { row in progressCell(row.id) }
                .width(min: 50, ideal: 80)
                .customizationID("progress")
            TableColumn("Dodano", sortUsing: ColumnSort("addedAt")) { row in
                text(Formats.date(ms: item(row.id)?.addedAt)).monospacedDigit()
            }
            .width(min: 60, ideal: 90)
            .customizationID("added")
            .defaultVisibility(.hidden)
            TableColumn("Rozmiar", sortUsing: ColumnSort("size")) { row in
                text(item(row.id).map { Formats.size($0.media.size) }).monospacedDigit()
            }
            .width(min: 50, ideal: 80)
            .customizationID("size")
            .defaultVisibility(.hidden)
        }
    }

    private var podcastTable: some View {
        Table(rows, selection: selection, sortOrder: sortOrder, columnCustomization: $podcastColumns) {
            TableColumn("Tytuł", sortUsing: ColumnSort("media.metadata.title")) { row in titleCell(row.id) }
                .width(min: 120, ideal: 200)
                .customizationID("title")
                .disabledCustomizationBehavior(.visibility)
            TableColumn("Autor", sortUsing: ColumnSort("media.metadata.author")) { row in
                // Wiersz odcinka (wyniki wyszukiwania) ma w tej kolumnie podcast, jak karta.
                let item = item(row.id)
                text(item?.recentEpisode != nil ? item?.title : item?.author)
            }
            .width(min: 60, ideal: 130)
            .customizationID("author")
            TableColumn("Odcinki", sortUsing: ColumnSort("media.numTracks")) { row in
                text(item(row.id)?.media.numEpisodes.map(String.init)).monospacedDigit()
            }
            .width(min: 40, ideal: 70)
            .customizationID("episodes")
            TableColumn("Dodano", sortUsing: ColumnSort("addedAt")) { row in
                text(Formats.date(ms: item(row.id)?.addedAt)).monospacedDigit()
            }
            .width(min: 60, ideal: 100)
            .customizationID("added")
            TableColumn("Rozmiar", sortUsing: ColumnSort("size")) { row in
                text(item(row.id).map { Formats.size($0.media.size) }).monospacedDigit()
            }
            .width(min: 50, ideal: 80)
            .customizationID("size")
        }
    }

    // MARK: Komórki

    /// Okładka-miniatura z tytułem (jak ikona z nazwą w Finderze). Ta kolumna jest zawsze
    /// widoczna, więc to ona doczytuje strony, gdy wiersz pojawia się na ekranie.
    private func titleCell(_ index: Int) -> some View {
        let item = item(index)
        return HStack(spacing: 8) {
            Group {
                if let item {
                    AsyncCover(listening: listening, itemID: item.id, path: item.media.coverPath, size: Self.coverSize, symbol: item.isPodcast ? "mic" : "book.closed")
                } else {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                }
            }
            .frame(width: Self.coverSize, height: Self.coverSize)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .accessibilityHidden(true)
            Text(item?.recentEpisode?.title ?? item?.title ?? "Wczytywanie…")
                .lineLimit(1)
                .foregroundStyle(item == nil ? .secondary : .primary)
        }
        .onAppear { ensureLoaded(index) }
        // Strona zwolniona przy odświeżeniu: widoczny wiersz doczytuje ją sam.
        .onChange(of: item == nil) { if item == nil { ensureLoaded(index) } }
    }

    private func progressCell(_ index: Int) -> some View {
        let item = item(index)
        return ProgressCell(listening: listening, key: item.map { ListeningController.key($0.id, $0.recentEpisode?.id) })
    }

    private func text(_ value: String?) -> some View {
        Text(value ?? "").lineLimit(1).foregroundStyle(.secondary)
    }

    /// „Nazwa #1, Inna #2” z wersji skróconej albo serie z pełnej (wyniki wyszukiwania, kolekcje).
    private func seriesText(_ item: AudiobookshelfClient.LibraryItem?) -> String? {
        guard let metadata = item?.media.metadata else { return nil }
        if let name = metadata.seriesName, !name.isEmpty { return name }
        let series = metadata.series?.values ?? []
        return series.isEmpty ? nil : series.map { ref in ref.sequence.map { "\(ref.name) #\($0)" } ?? ref.name }.joined(separator: ", ")
    }

    static let coverSize: CGFloat = 24

    // MARK: Zaznaczenie

    /// Lista w sekcji z trybem „Zaznacz” zaznacza w `browser.selection` — tym samym, na którym
    /// działa pasek działań; inaczej zaznaczenie jest tylko jej.
    private var selection: Binding<Set<ListRow.ID>> {
        guard selectionScope != nil else { return $localSelection }
        return Binding(get: { indices(Set(browser.selection.map(\.id))) }, set: { apply($0) })
    }

    private func apply(_ new: Set<Int>) {
        let old = indices(Set(browser.selection.map(\.id)))
        var added = new.subtracting(old)
        var removed = old.subtracting(new)
        // W trybie „Zaznacz” zwykłe kliknięcie przełącza wiersz jak kartę w siatce, zamiast
        // zostawiać zaznaczony tylko ten jeden (⌘- i ⇧-kliknięcie działają jak w Finderze).
        if browser.isSelecting, new.count == 1, let index = new.first, Self.isPlainClick {
            if old.contains(index) { added = []; removed = [index] } else { added = [index]; removed = [] }
        }
        let addedItems = added.sorted().compactMap(item)
        let removedIDs = Set(removed.compactMap { item($0)?.id })
        // Wiele wierszy (⌘-, ⇧-kliknięcie, ⌘A) włącza tryb „Zaznacz” z paskiem działań.
        if !browser.isSelecting, browser.selection.count - removedIDs.count + addedItems.count > 1 {
            browser.isSelecting = true
        }
        browser.changeSelection(removing: removedIDs, adding: addedItems)
    }

    private static var isPlainClick: Bool {
        guard let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type) else { return false }
        return event.modifierFlags.intersection([.command, .shift]).isEmpty
    }

    // MARK: Menu podręczne

    @ViewBuilder private func menu(for selected: Set<Int>) -> some View {
        let items = selected.sorted().compactMap(item)
        if items.count == 1, let item = items.first {
            ItemMenu(browser: browser, item: item)
        } else if items.count > 1 {
            let playable = items.filter { !$0.isEbookOnly && (!$0.isPodcast || $0.recentEpisode != nil) }
            if !playable.isEmpty {
                Button("Odtwarzaj po kolei (\(playable.count))") {
                    let entries = playable.map { ListeningController.QueueEntry(itemID: $0.id, episodeID: $0.recentEpisode?.id, title: $0.title) }
                    Task { await listening.playQueue(entries) }
                }
                Divider()
                Button("Oznacz jako ukończone") { mark(playable, true) }
                Button("Oznacz jako nieukończone") { mark(playable, false) }
            }
        }
    }

    private func mark(_ items: [AudiobookshelfClient.LibraryItem], _ finished: Bool) {
        let entries = items.map { AudiobookshelfClient.BatchProgress(libraryItemId: $0.id, episodeId: $0.recentEpisode?.id, isFinished: finished) }
        Task { await listening.setFinished(entries) }
    }
}

extension ItemTable {
    /// Lista bez stron (kolekcja, autor, wyniki wyszukiwania): wszystkie pozycje są już w pamięci.
    init(browser: LibraryBrowser, items: [AudiobookshelfClient.LibraryItem], sort: Binding<LibraryBrowser.Sort>? = nil) {
        self.init(browser: browser, count: items.count, item: { items.indices.contains($0) ? items[$0] : nil }, indices: { ids in
            Set(items.indices.filter { ids.contains(items[$0].id) })
        }, sort: sort)
    }

    /// Kolejność listy bez stron po kliknięciu w nagłówek (te same klucze, co serwer).
    /// Pusty klucz — kolejność oryginalna (np. ułożona kolekcja).
    static func sorted(_ items: [AudiobookshelfClient.LibraryItem], by sort: LibraryBrowser.Sort) -> [AudiobookshelfClient.LibraryItem] {
        func value(_ item: AudiobookshelfClient.LibraryItem) -> Comparable? {
            let metadata = item.media.metadata
            switch sort.key {
            case "media.metadata.title": return (metadata.titleIgnorePrefix ?? item.title).lowercased()
            case "media.metadata.authorName", "media.metadata.author": return (item.author ?? "").lowercased()
            case "media.metadata.publishedYear": return metadata.publishedYear ?? ""
            case "media.duration": return item.media.duration ?? 0
            case "addedAt": return item.addedAt ?? 0
            case "size": return item.media.size ?? 0
            case "media.numTracks": return item.media.numEpisodes ?? 0
            default: return nil
            }
        }
        guard !items.isEmpty, value(items[0]) != nil else { return items }
        let sorted = items.sorted { a, b in
            switch (value(a), value(b)) {
            case let (x as String, y as String): return x.localizedStandardCompare(y) == .orderedAscending
            case let (x as Double, y as Double): return x < y
            case let (x as Int, y as Int): return x < y
            default: return false
            }
        }
        return sort.descending ? sorted.reversed() : sorted
    }
}

/// Postęp w wierszu listy. Osobny widok: tylko on czyta słownik postępu (jak `ItemProgressBadge`).
private struct ProgressCell: View {
    let listening: ListeningController
    let key: String?

    var body: some View {
        let progress = key.flatMap { listening.progress[$0] }
        Group {
            if progress?.isFinished == true {
                Label("Ukończone", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            } else if let value = progress?.progress, value > 0 {
                HStack(spacing: 6) {
                    ProgressView(value: min(1, value)).progressViewStyle(.linear).frame(maxWidth: 50)
                    Text(value.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().foregroundStyle(.secondary)
                }
            } else {
                Text("")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(progress))
    }

    private static func label(_ progress: AudiobookshelfClient.MediaProgress?) -> String {
        if progress?.isFinished == true { return "Ukończone" }
        if let value = progress?.progress, value > 0 { return "Postęp \(value.formatted(.percent.precision(.fractionLength(0))))" }
        return "Nierozpoczęte"
    }
}

/// Lista serii (etap 14c): pierwsza okładka z nazwą, liczba książek, ukończone, łączny czas.
struct SeriesTable: View {
    let browser: LibraryBrowser
    let list: PagedList<AudiobookshelfClient.Series>
    let count: Int
    @Binding var sort: LibraryBrowser.Sort

    @State private var columns = ColumnStore.load("series")
    @State private var selection = Set<Int>()

    var body: some View {
        Table((0..<count).map(ListRow.init), selection: $selection, sortOrder: $sort.columnOrder, columnCustomization: $columns) {
            TableColumn("Nazwa", sortUsing: ColumnSort("name")) { row in nameCell(row.id) }
                .width(min: 120, ideal: 220)
                .customizationID("name")
                .disabledCustomizationBehavior(.visibility)
            TableColumn("Książki", sortUsing: ColumnSort("numBooks")) { row in
                Text(list.element(at: row.id).map { "\($0.items.count)" } ?? "").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 70)
            .customizationID("books")
            TableColumn("Ukończone") { row in SeriesFinished(listening: browser.listening, series: list.element(at: row.id)) }
                .width(min: 50, ideal: 90)
                .customizationID("finished")
            TableColumn("Łączny czas", sortUsing: ColumnSort("totalDuration")) { row in
                Text(list.element(at: row.id).map { Formats.duration($0.items.compactMap(\.media.duration).reduce(0, +)) } ?? "")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 110)
            .customizationID("duration")
        }
        .contextMenu(forSelectionType: ListRow.ID.self) { selected in
            if selected.count == 1, let series = selected.first.flatMap(list.element) {
                Button("Otwórz") { browser.open(.series(id: series.id, name: series.name)) }
            }
        } primaryAction: { selected in
            if let series = selected.min().flatMap(list.element) { browser.open(.series(id: series.id, name: series.name)) }
        }
        .tableStyle(ListRow.style)
        .onChange(of: columns) { ColumnStore.save(columns, "series") }
        .accessibilityIdentifier("seriesTable")
    }

    private func nameCell(_ index: Int) -> some View {
        let series = list.element(at: index)
        let first = series?.items.first
        return HStack(spacing: 8) {
            Group {
                if let first {
                    AsyncCover(listening: browser.listening, itemID: first.id, path: first.media.coverPath, size: ItemTable.coverSize)
                } else {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                }
            }
            .frame(width: ItemTable.coverSize, height: ItemTable.coverSize)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .accessibilityHidden(true)
            Text(series?.name ?? "Wczytywanie…").lineLimit(1).foregroundStyle(series == nil ? .secondary : .primary)
        }
        .onAppear { list.ensureLoaded(index) }
        .onChange(of: series == nil) { if series == nil { list.ensureLoaded(index) } }
    }
}

/// Ukończone tomy serii; tylko ten widok czyta słownik postępu.
private struct SeriesFinished: View {
    let listening: ListeningController
    let series: AudiobookshelfClient.Series?

    var body: some View {
        let books = series?.items ?? []
        let finished = books.filter { listening.progress[$0.id]?.isFinished == true }.count
        Text(books.isEmpty || finished == 0 ? "" : finished == books.count ? "Cała seria" : "\(finished) z \(books.count)")
            .monospacedDigit().foregroundStyle(.secondary)
    }
}
