// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import Observation
import AudiobookshelfKit

/// Lista książek scalona ze wszystkich bibliotek, doczytywana stronami przy przewijaniu.
@MainActor
@Observable
final class BookListModel {
    private(set) var items: [Tagged<Client.LibraryItem>] = []
    private(set) var isLoading = false
    private(set) var isFinished = false
    private(set) var hasLoaded = false
    private(set) var stalled: LibraryFailure?
    private(set) var failures: [LibraryFailure] = []
    private(set) var error: String?
    private(set) var total: Int?
    /// Pozycja, której pojawienie się na ekranie dociąga następną stronę (ok. 2 ekrany przed końcem).
    @ObservationIgnored private(set) var prefetchID: String?
    @ObservationIgnored private var merge: SortedMerge<Client.LibraryItem>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    static let batchSize = 60

    func reset(_ merge: SortedMerge<Client.LibraryItem>) {
        loadTask?.cancel()
        loadTask = nil
        self.merge = merge
        items = []
        isFinished = false
        hasLoaded = false
        stalled = nil
        failures = []
        error = nil
        total = nil
        prefetchID = nil
        loadMore()
    }

    func appeared(_ id: String) {
        if id == prefetchID { loadMore() }
    }

    func loadMore() {
        guard loadTask == nil, !isFinished, let merge else { return }
        isLoading = true
        loadTask = Task {
            defer {
                if self.merge === merge {
                    isLoading = false
                    loadTask = nil
                }
            }
            do {
                let batch = try await merge.next(Self.batchSize)
                guard self.merge === merge else { return }
                items.append(contentsOf: batch.elements)
                isFinished = batch.isFinished
                stalled = batch.stalled
                failures = merge.failures
                total = merge.total
                error = nil
                hasLoaded = true
                prefetchID = items.count > 20 ? items[items.count - 20].id : items.last?.id
            } catch is CancellationError {
            } catch {
                guard self.merge === merge else { return }
                self.error = LibraryStore.message(error)
                hasLoaded = true
            }
        }
    }
}

/// Serie albo autorzy połączeni z kilku bibliotek, doczytywani przy przewijaniu.
@MainActor
@Observable
final class EntityListModel<Element: Decodable & Sendable & Identifiable> where Element.ID == String {
    private(set) var entities: [MergedEntity<Element>] = []
    private(set) var isLoading = false
    private(set) var isFinished = false
    private(set) var hasLoaded = false
    private(set) var stalled: LibraryFailure?
    private(set) var failures: [LibraryFailure] = []
    private(set) var error: String?
    @ObservationIgnored private(set) var prefetchID: String?
    @ObservationIgnored private var merge: GroupedMerge<Element>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    func reset(_ merge: GroupedMerge<Element>) {
        loadTask?.cancel()
        loadTask = nil
        self.merge = merge
        entities = []
        isFinished = false
        hasLoaded = false
        stalled = nil
        error = nil
        loadMore()
    }

    func appeared(_ id: String) {
        if id == prefetchID { loadMore() }
    }

    func loadMore() {
        guard loadTask == nil, !isFinished, let merge else { return }
        isLoading = true
        loadTask = Task {
            defer {
                if self.merge === merge {
                    isLoading = false
                    loadTask = nil
                }
            }
            do {
                let all = try await merge.loadMore(50)
                guard self.merge === merge else { return }
                entities = all
                isFinished = merge.isFinished
                stalled = merge.stalled
                failures = merge.failures
                error = nil
                hasLoaded = true
                prefetchID = all.count > 15 ? all[all.count - 15].id : all.last?.id
            } catch is CancellationError {
            } catch {
                guard self.merge === merge else { return }
                self.error = LibraryStore.message(error)
                hasLoaded = true
            }
        }
    }
}

/// Zakładka „Audiobooki”: wszystkie biblioteki książek jako jedna.
struct BooksTab: View {
    let model: AppModel
    let session: ServerSession

    enum Mode: String, CaseIterable, Identifiable {
        case books, series, authors
        var id: Self { self }
        var title: String {
            switch self {
            case .books: "Książki"
            case .series: "Serie"
            case .authors: "Autorzy"
            }
        }
    }

    @AppStorage("books.mode") private var mode: Mode = .books

    var body: some View {
        NavigationStack {
            Group {
                switch session.library.state {
                case .loading:
                    ProgressView()
                case .failed(let message):
                    LoadFailureView(message: message) { Task { await session.library.load() } }
                case .ready(let combined):
                    switch mode {
                    case .books: BooksGrid(combined: combined, session: session, mode: $mode)
                    case .series: SeriesList(combined: combined, session: session, mode: $mode)
                    case .authors: AuthorsList(combined: combined, session: session, mode: $mode)
                    }
                }
            }
            .navigationTitle("Audiobooki")
            .browseDestinations(model: model, session: session)
        }
    }
}

/// Przełącznik Książki / Serie / Autorzy nad listą.
private struct ModePicker: View {
    @Binding var mode: BooksTab.Mode

    var body: some View {
        Picker("Widok", selection: $mode) {
            ForEach(BooksTab.Mode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - Książki

private struct BookQuery: Hashable {
    var sort: CombinedLibraries.ItemSort
    var descending: Bool
    var filter: CombinedLibraries.ProgressFilter?
    var libraryID: String?
}

private struct BooksGrid: View {
    let combined: CombinedLibraries
    let session: ServerSession
    @Binding var mode: BooksTab.Mode

    @AppStorage("books.sort") private var sort: CombinedLibraries.ItemSort = .title
    @AppStorage("books.descending") private var descending = false
    @AppStorage("books.filter") private var filterRaw = ""
    @AppStorage("books.library") private var libraryID = ""
    @State private var list = BookListModel()
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 104

    private var filter: CombinedLibraries.ProgressFilter? { CombinedLibraries.ProgressFilter(rawValue: filterRaw) }
    private var scopedLibrary: String? { combined.libraries.contains { $0.id == libraryID } ? libraryID : nil }
    private var query: BookQuery { BookQuery(sort: sort, descending: descending, filter: filter, libraryID: scopedLibrary) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ModePicker(mode: $mode)
                FailureNotice(failures: list.failures)
                if let summary {
                    Text(summary).font(.footnote).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: coverColumns(minimum: cardWidth), spacing: 18) {
                    ForEach(list.items) { entry in
                        BookCard(item: entry.value, session: session, libraryName: badge(entry.libraryID))
                            .onAppear { list.appeared(entry.id) }
                    }
                }
                footer
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .overlay {
            if list.hasLoaded, list.items.isEmpty, list.error == nil, list.stalled == nil {
                ContentUnavailableView(filter == nil ? "Brak książek" : "Nic nie pasuje do filtra", systemImage: "books.vertical",
                                       description: Text(filter == nil ? "W bibliotekach książek nie ma jeszcze pozycji." : "Zmień filtr postępu albo bibliotekę."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { sortMenu }
        }
        .refreshable { await reload() }
        .task(id: query) { list.reset(makeMerge()) }
        .onChange(of: sort) { _, new in descending = new.defaultDescending }
        .onChange(of: session.library.itemsRevision) { list.reset(makeMerge()) }
    }

    private func makeMerge() -> SortedMerge<Client.LibraryItem> {
        combined.items(sort: sort, descending: descending, progress: filter, libraryID: scopedLibrary,
                       lastUpdate: sort == .lastListened ? session.library.progress.lastUpdate : [:])
    }

    private func reload() async {
        await session.library.refreshProgress()
        list.reset(makeMerge())
    }

    private func badge(_ libraryID: String) -> String? {
        combined.hasSeveralLibraries && scopedLibrary == nil ? combined.libraryName(libraryID) : nil
    }

    private var summary: String? {
        guard let total = list.total else { return nil }
        let count = PolishCount.books(total)
        return scopedLibrary.flatMap { combined.libraryName($0) }.map { "\(count) · \($0)" } ?? count
    }

    @ViewBuilder
    private var footer: some View {
        if let stalled = list.stalled {
            VStack(spacing: 8) {
                Text("Biblioteka „\(stalled.libraryName)” przestała odpowiadać. Dalsze pozycje czekają na nią, żeby kolejność się zgadzała.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Spróbuj ponownie") { list.loadMore() }
            }
            .frame(maxWidth: .infinity)
        } else if let error = list.error {
            if list.items.isEmpty {
                LoadFailureView(message: error) { list.reset(makeMerge()) }
            } else {
                VStack(spacing: 8) {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("Spróbuj ponownie") { list.loadMore() }
                }
                .frame(maxWidth: .infinity)
            }
        } else if !list.isFinished {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()
                .onAppear { list.loadMore() }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sortuj", selection: $sort) {
                Text("Tytuł").tag(CombinedLibraries.ItemSort.title)
                Text("Autor").tag(CombinedLibraries.ItemSort.author)
                Text("Data dodania").tag(CombinedLibraries.ItemSort.addedAt)
                Text("Czas trwania").tag(CombinedLibraries.ItemSort.duration)
                Text("Ostatnio słuchane").tag(CombinedLibraries.ItemSort.lastListened)
            }
            Picker("Kierunek", selection: $descending) {
                Text(ascendingTitle).tag(false)
                Text(descendingTitle).tag(true)
            }
            Section("Postęp") {
                Picker("Postęp", selection: $filterRaw) {
                    Text("Wszystkie").tag("")
                    Text("Nierozpoczęte").tag(CombinedLibraries.ProgressFilter.notStarted.rawValue)
                    Text("W trakcie").tag(CombinedLibraries.ProgressFilter.inProgress.rawValue)
                    Text("Ukończone").tag(CombinedLibraries.ProgressFilter.finished.rawValue)
                }
            }
            if combined.hasSeveralLibraries {
                Section("Biblioteka") {
                    Picker("Biblioteka", selection: $libraryID) {
                        Text("Wszystkie").tag("")
                        ForEach(combined.libraries) { Text($0.name).tag($0.id) }
                    }
                }
            }
        } label: {
            Label("Sortowanie i filtr", systemImage: filter == nil && scopedLibrary == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
    }

    private var ascendingTitle: String {
        switch sort {
        case .title, .author: "A–Z"
        case .addedAt, .lastListened: "Od najstarszych"
        case .duration: "Od najkrótszych"
        }
    }

    private var descendingTitle: String {
        switch sort {
        case .title, .author: "Z–A"
        case .addedAt, .lastListened: "Od najnowszych"
        case .duration: "Od najdłuższych"
        }
    }
}

// MARK: - Serie i autorzy

private struct SeriesList: View {
    let combined: CombinedLibraries
    let session: ServerSession
    @Binding var mode: BooksTab.Mode
    @AppStorage("series.descending") private var descending = false
    @State private var list = EntityListModel<Client.Series>()

    var body: some View {
        List {
            Section {
                ModePicker(mode: $mode).listRowBackground(Color.clear).listRowInsets(.init())
            }
            FailureNotice(failures: list.failures)
            ForEach(list.entities) { series in
                NavigationLink(value: Route.series(series)) {
                    SeriesRow(series: series, session: session, libraries: badges(series))
                }
                .onAppear { list.appeared(series.id) }
            }
            EntityFooter(isFinished: list.isFinished, stalled: list.stalled, error: list.error, isEmpty: list.entities.isEmpty) { list.loadMore() }
        }
        .overlay {
            if list.hasLoaded, list.entities.isEmpty, list.error == nil {
                ContentUnavailableView("Brak serii", systemImage: "square.stack", description: Text("Żadna książka nie ma przypisanej serii."))
            }
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { DirectionMenu(descending: $descending) } }
        .refreshable { list.reset(combined.series(descending: descending)) }
        .task(id: descending) { list.reset(combined.series(descending: descending)) }
    }

    private func badges(_ series: MergedEntity<Client.Series>) -> String? {
        guard combined.hasSeveralLibraries else { return nil }
        return Array(Set(series.libraryIDs)).compactMap { combined.libraryName($0) }.sorted().joined(separator: " · ")
    }
}

private struct SeriesRow: View {
    let series: MergedEntity<Client.Series>
    let session: ServerSession
    let libraries: String?

    var body: some View {
        let books = series.members.reduce(0) { $0 + $1.value.items.count }
        HStack(spacing: 12) {
            if let first = series.members.lazy.compactMap(\.value.items.first).first {
                ItemCover(itemID: first.id, session: session, points: 60).frame(width: 52)
            } else {
                Image(systemName: "square.stack").frame(width: 52, height: 52).background(.quaternary, in: .rect(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(series.first.name)
                Text(PolishCount.books(books)).font(.footnote).foregroundStyle(.secondary)
                if let libraries { LibraryBadge(name: libraries) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AuthorsList: View {
    let combined: CombinedLibraries
    let session: ServerSession
    @Binding var mode: BooksTab.Mode
    @AppStorage("authors.descending") private var descending = false
    @State private var list = EntityListModel<Client.Author>()

    var body: some View {
        List {
            Section {
                ModePicker(mode: $mode).listRowBackground(Color.clear).listRowInsets(.init())
            }
            FailureNotice(failures: list.failures)
            ForEach(list.entities) { author in
                NavigationLink(value: Route.author(author)) {
                    let books = author.members.reduce(0) { $0 + ($1.value.numBooks ?? 0) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(author.first.name)
                        Text(PolishCount.books(books)).font(.footnote).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .onAppear { list.appeared(author.id) }
            }
            EntityFooter(isFinished: list.isFinished, stalled: list.stalled, error: list.error, isEmpty: list.entities.isEmpty) { list.loadMore() }
        }
        .overlay {
            if list.hasLoaded, list.entities.isEmpty, list.error == nil {
                ContentUnavailableView("Brak autorów", systemImage: "person.2", description: Text("W bibliotekach nie ma jeszcze autorów."))
            }
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { DirectionMenu(descending: $descending) } }
        .refreshable { list.reset(combined.authors(descending: descending)) }
        .task(id: descending) { list.reset(combined.authors(descending: descending)) }
    }
}

private struct DirectionMenu: View {
    @Binding var descending: Bool

    var body: some View {
        Menu {
            Picker("Kolejność", selection: $descending) {
                Text("A–Z").tag(false)
                Text("Z–A").tag(true)
            }
        } label: {
            Label("Kolejność", systemImage: "arrow.up.arrow.down.circle")
        }
    }
}

private struct EntityFooter: View {
    let isFinished: Bool
    let stalled: LibraryFailure?
    let error: String?
    let isEmpty: Bool
    let retry: () -> Void

    var body: some View {
        if let stalled {
            VStack(alignment: .leading, spacing: 6) {
                Text("Biblioteka „\(stalled.libraryName)” przestała odpowiadać.").font(.footnote).foregroundStyle(.secondary)
                Button("Spróbuj ponownie", action: retry)
            }
        } else if let error {
            VStack(alignment: .leading, spacing: 6) {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                Button("Spróbuj ponownie", action: retry)
            }
        } else if !isFinished {
            ProgressView()
                .frame(maxWidth: .infinity)
                .onAppear(perform: retry)
        }
    }
}
