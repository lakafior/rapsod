// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AudiobookshelfKit

/// Siatka podanych książek (strona serii, autora).
struct BookGrid: View {
    let books: [Client.LibraryItem]
    let session: ServerSession
    var caption: ((Client.LibraryItem) -> String?)? = nil
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 104

    var body: some View {
        let combined = session.library.combined
        LazyVGrid(columns: coverColumns(minimum: cardWidth), spacing: 18) {
            ForEach(books) { book in
                VStack(alignment: .leading, spacing: 2) {
                    if let caption = caption?(book) {
                        Text(caption).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    BookCard(item: book, session: session,
                             libraryName: combined?.hasSeveralLibraries == true ? combined?.libraryName(book.libraryId) : nil)
                }
            }
        }
    }
}

/// Seria ze wszystkich bibliotek: książki w kolejności tomów.
struct SeriesPage: View {
    let series: MergedEntity<Client.Series>?
    let seed: Tagged<Client.Series>?
    let model: AppModel
    let session: ServerSession

    @State private var books: [Client.LibraryItem] = []
    @State private var seriesIDs: Set<String> = []
    @State private var failures: [LibraryFailure] = []
    @State private var error: String?
    @State private var isLoading = true
    @State private var bulkMessage: String?
    @State private var isDownloading = false

    private var name: String { series?.first.name ?? seed?.value.name ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                FailureNotice(failures: failures)
                if !books.isEmpty {
                    Text(PolishCount.books(books.count)).font(.footnote).foregroundStyle(.secondary)
                }
                BookGrid(books: books, session: session) { book in
                    let sequence = (book.media.metadata.series?.values ?? []).first { seriesIDs.contains($0.id) }?.sequence
                    return sequence.map { "Tom \($0)" }
                }
            }
            .padding()
        }
        .overlay {
            if isLoading, books.isEmpty {
                ProgressView()
            } else if let error, books.isEmpty {
                LoadFailureView(message: error) { Task { await load() } }
            }
        }
        .navigationTitle(name)
        .toolbar {
            if !books.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Pobierz wszystkie tomy na telefon", systemImage: isDownloading ? "hourglass" : "arrow.down.circle") {
                        Task {
                            isDownloading = true
                            bulkMessage = await BulkDownload.start(books.map { .book(itemID: $0.id) }, session: session).message
                            isDownloading = false
                        }
                    }
                    .disabled(isDownloading)
                }
            }
        }
        .alert("Pobieranie serii", isPresented: Binding(get: { bulkMessage != nil }, set: { if !$0 { bulkMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(bulkMessage ?? "")
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let combined = session.library.combined else { return }
        isLoading = true
        defer { isLoading = false }
        let entity: MergedEntity<Client.Series>
        if let series {
            entity = series
        } else if let seed {
            entity = await combined.seriesEntity(seed)
        } else {
            return
        }
        do {
            let result = try await combined.books(of: entity)
            books = result.value
            failures = result.failures
            seriesIDs = Set(entity.members.map(\.value.id))
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = LibraryStore.message(error)
        }
    }
}

/// Autor ze wszystkich bibliotek: opis, serie i książki.
struct AuthorPage: View {
    let author: MergedEntity<Client.Author>?
    let seed: Tagged<Client.Author>?
    let model: AppModel
    let session: ServerSession

    @State private var page: CombinedLibraries.AuthorPage?
    @State private var failures: [LibraryFailure] = []
    @State private var error: String?
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    private var name: String { page?.name ?? author?.first.name ?? seed?.value.name ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FailureNotice(failures: failures)
                if let page {
                    HStack(alignment: .top, spacing: 14) {
                        Group {
                            if let image {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                            }
                        }
                        .frame(width: 88, height: 88)
                        .clipShape(.circle)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(PolishCount.books(page.books.count)).foregroundStyle(.secondary)
                            if !page.series.isEmpty {
                                Text(PolishCount.series(page.series.count)).foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline)
                    }
                    if let text = HTMLText.plain(page.description), !text.isEmpty {
                        ExpandableText(text: text)
                    }
                    ForEach(page.series, id: \.name) { series in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(series.name).font(.title3.bold())
                            BookGrid(books: series.books, session: session) { book in
                                book.sequence().map { "Tom \($0)" }
                            }
                        }
                    }
                    let inSeries = Set(page.series.flatMap { $0.books.map(\.id) })
                    let standalone = page.books.filter { !inSeries.contains($0.id) }
                    if !standalone.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(page.series.isEmpty ? "Książki" : "Pozostałe książki").font(.title3.bold())
                            BookGrid(books: standalone, session: session)
                        }
                    }
                }
            }
            .padding()
        }
        .overlay {
            if page == nil {
                if let error {
                    LoadFailureView(message: error) { Task { await load() } }
                } else {
                    ProgressView()
                }
            }
        }
        .navigationTitle(name)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let combined = session.library.combined else { return }
        let entity: MergedEntity<Client.Author>
        if let author {
            entity = author
        } else if let seed {
            entity = await combined.authorEntity(seed)
        } else {
            return
        }
        do {
            let result = try await combined.author(entity)
            page = result.value
            failures = result.failures
            error = nil
            if let id = result.value.imageAuthorID {
                let pixels = Int(88 * displayScale)
                if let data = try? await session.auth.perform({ try await $0.authorImage(id: id, width: pixels, token: $1) }) {
                    image = await CoverCache.thumbnail(data: data, pixels: pixels)
                }
            }
        } catch is CancellationError {
        } catch {
            self.error = LibraryStore.message(error)
        }
    }
}

/// Książki lektora ze wszystkich bibliotek (filtr `narrators` serwera, scalany jak główna lista).
struct NarratorPage: View {
    let name: String
    let model: AppModel
    let session: ServerSession
    @State private var list = BookListModel()
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 104

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                FailureNotice(failures: list.failures)
                LazyVGrid(columns: coverColumns(minimum: cardWidth), spacing: 18) {
                    ForEach(list.items) { entry in
                        BookCard(item: entry.value, session: session,
                                 libraryName: session.library.combined?.hasSeveralLibraries == true ? session.library.combined?.libraryName(entry.libraryID) : nil)
                            .onAppear { list.appeared(entry.id) }
                    }
                }
                if !list.isFinished, list.error == nil, list.stalled == nil {
                    ProgressView().frame(maxWidth: .infinity).onAppear { list.loadMore() }
                }
                if let message = list.error ?? list.stalled?.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                    Button("Spróbuj ponownie") { list.loadMore() }
                }
            }
            .padding()
        }
        .navigationTitle(name)
        .task {
            guard let combined = session.library.combined else { return }
            list.reset(combined.items(sort: .title, descending: false, serverFilter: Client.filter("narrators", name)))
        }
    }
}

/// Długi opis: kilka linijek i „Więcej”.
struct ExpandableText: View {
    let text: String
    var lineLimit = 4
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.callout)
                .lineLimit(expanded ? nil : lineLimit)
            Button(expanded ? "Mniej" : "Więcej") {
                withAnimation(.snappy) { expanded.toggle() }
            }
            .font(.callout.weight(.semibold))
        }
    }
}
