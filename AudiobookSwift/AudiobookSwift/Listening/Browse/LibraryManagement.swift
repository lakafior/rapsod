import SwiftUI

// MARK: - Tagi i gatunki (etap 9i; wzorzec: `pages/config/item-metadata-utils/tags.vue` i `genres.vue`)

/// Wszystkie tagi albo gatunki serwera z liczbą pozycji, zmiana nazwy (scalanie) i usuwanie.
/// Lista i zmiany — tokenem root (upstream wymaga administratora); liczby z danych filtra biblioteki.
struct MetadataValuesSection: View {
    let browser: LibraryBrowser
    let libraryID: String
    @AppStorage("libraryWindow.metadataList") private var listRaw = AudiobookshelfClient.MetadataList.genres.rawValue
    @State private var values: [String]?
    @State private var status = AdminStatus()
    @State private var filter = ""
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: String?

    private var list: AudiobookshelfClient.MetadataList { .init(rawValue: listRaw) ?? .genres }
    private var noun: String { list == .tags ? "tag" : "gatunek" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Lista", selection: $listRaw) {
                    Text("Gatunki").tag(AudiobookshelfClient.MetadataList.genres.rawValue)
                    Text("Tagi").tag(AudiobookshelfClient.MetadataList.tags.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Szukaj", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Spacer()
                if status.isBusy { ProgressView().controlSize(.small) }
            }
            .padding(12)
            if let error = status.error {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 12)
            }
            if let notice = status.notice {
                Label(notice, systemImage: "checkmark.circle").foregroundStyle(.green).padding(.horizontal, 12)
            }
            Divider()
            if let values {
                let shown = filter.isEmpty ? values : values.filter { $0.localizedCaseInsensitiveContains(filter) }
                if values.isEmpty {
                    ContentUnavailableView(list == .tags ? "Brak tagów" : "Brak gatunków", systemImage: "tag")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(shown, id: \.self) { value in
                        HStack {
                            Button(value) { browser.open(.filtered(list == .tags ? .tag(value) : .genre(value))) }
                                .buttonStyle(.link)
                            Spacer()
                            Button("Zmień nazwę…", systemImage: "pencil") { newName = value; renaming = value }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                                .help("Zmień nazwę we wszystkich pozycjach; istniejąca nazwa łączy oba")
                            Button("Usuń…", systemImage: "trash", role: .destructive) { deleting = value }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                                .help("Usuń ze wszystkich pozycji")
                        }
                        .disabled(status.isBusy)
                    }
                }
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
        .navigationTitle("Tagi i gatunki")
        .task(id: listRaw) { await load() }
        .alert("Nowa nazwa: \(renaming ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nazwa", text: $newName)
            Button("Zmień") { if let old = renaming { Task { await rename(old, to: newName) } } }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Zmiana obejmuje wszystkie biblioteki serwera. Jeśli \(noun) o nowej nazwie już istnieje, oba zostaną połączone.")
        }
        .confirmationDialog("Usunąć \(noun) „\(deleting ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { value in
            Button("Usuń ze wszystkich pozycji", role: .destructive) { Task { await delete(value) } }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in
            Text("Zniknie ze wszystkich pozycji we wszystkich bibliotekach serwera (także z plików metadata.json, jeśli są zapisywane).")
        }
    }

    private func load() async {
        values = nil
        let list = list
        await status.run("Wczytywanie…", failure: "Nie udało się wczytać listy") {
            values = try await browser.manager.run { try await $0.metadataValues(list, token: $1) }
        }
        if values == nil { values = [] }
    }

    private func rename(_ old: String, to new: String) async {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old else { return }
        let list = list
        await status.run("Zmienianie nazwy…", failure: "Nie udało się zmienić nazwy") {
            let count = try await browser.manager.run { try await $0.renameMetadataValue(list, from: old, to: new, token: $1) }
            values = try await browser.manager.run { try await $0.metadataValues(list, token: $1) }
            status.notice = "„\(old)” → „\(new)”: zmienionych pozycji \(count)."
        }
        browser.invalidateFilterData()
    }

    private func delete(_ value: String) async {
        let list = list
        await status.run("Usuwanie…", failure: "Nie udało się usunąć") {
            let count = try await browser.manager.run { try await $0.deleteMetadataValue(list, value, token: $1) }
            values?.removeAll { $0 == value }
            status.notice = "Usunięto „\(value)” z \(count) poz."
        }
        browser.invalidateFilterData()
    }
}

// MARK: - Lektorzy: zmiana nazwy i usunięcie (menu podręczne listy lektorów)

struct NarratorManageMenu: View {
    let browser: LibraryBrowser
    let libraryID: String
    let narrator: AudiobookshelfClient.Narrator
    @Binding var renaming: AudiobookshelfClient.Narrator?
    @Binding var deleting: AudiobookshelfClient.Narrator?

    var body: some View {
        Button("Pokaż książki") { browser.open(.filtered(.narrator(narrator.name))) }
        if browser.manager.isAvailable {
            Divider()
            Button("Zmień nazwę…") { renaming = narrator }
            Button("Usuń ze wszystkich książek…", role: .destructive) { deleting = narrator }
        }
    }
}

// MARK: - Statystyki biblioteki (etap 9i; wzorzec: `pages/library/_library/stats.vue`)

struct LibraryStatsView: View {
    let browser: LibraryBrowser
    let libraryID: String
    @State private var stats: AudiobookshelfClient.LibraryStats?
    @State private var error: String?

    var body: some View {
        Group {
            if let stats {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 16) {
                            StatTile(title: browser.isPodcastLibrary ? "Podcasty" : "Pozycje", value: "\(stats.totalItems ?? 0)")
                            if let authors = stats.totalAuthors { StatTile(title: "Autorzy", value: "\(authors)") }
                            StatTile(title: "Gatunki", value: "\(stats.totalGenres ?? 0)")
                            StatTile(title: "Łączny czas", value: Formats.duration(stats.totalDuration ?? 0))
                            StatTile(title: "Rozmiar", value: ByteCountFormatter.string(fromByteCount: Int64(stats.totalSize ?? 0), countStyle: .file))
                            StatTile(title: "Pliki audio", value: "\(stats.numAudioTracks ?? 0)")
                        }
                        let genres = Array((stats.genresWithCount?.elements ?? []).prefix(10))
                        if !genres.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Najczęstsze gatunki").font(.title2.weight(.semibold))
                                let top = Double(genres.map { $0.count ?? 0 }.max() ?? 1)
                                ForEach(genres) { genre in
                                    HStack(spacing: 10) {
                                        Text(genre.title).lineLimit(1).frame(width: 170, alignment: .leading)
                                        GeometryReader { geometry in
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(.tint)
                                                .frame(width: max(4, geometry.size.width * Double(genre.count ?? 0) / max(top, 1)))
                                        }
                                        .frame(height: 12)
                                        Text("\(genre.count ?? 0)").monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                                    }
                                }
                            }
                        }
                        ranking("Autorzy z największą liczbą książek", stats.authorsWithCount?.elements ?? []) { author in
                            ("\(author.count ?? 0)", { if let id = author.authorID { browser.open(.author(id: id, name: author.title)) } })
                        }
                        ranking("Najdłuższe", stats.longestItems?.elements ?? []) { item in
                            (Formats.duration(item.duration ?? 0), { browser.open(.item(item.id)) })
                        }
                        ranking("Największe", stats.largestItems?.elements ?? []) { item in
                            (ByteCountFormatter.string(fromByteCount: Int64(item.size ?? 0), countStyle: .file), { browser.open(.item(item.id)) })
                        }
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(24)
                }
            } else {
                LoadingState(error: error) { await load() }
            }
        }
        .navigationTitle("Statystyki biblioteki")
        .task(id: libraryID) { await load() }
        .onChange(of: browser.revision) { Task { await load() } }
    }

    private func ranking<Element: Identifiable>(_ title: String, _ elements: [Element], row: @escaping (Element) -> (String, () -> Void)) -> some View
        where Element: RankingRow {
        Group {
            if !elements.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.title2.weight(.semibold))
                    ForEach(Array(elements.enumerated()), id: \.offset) { index, element in
                        let (value, open) = row(element)
                        HStack {
                            Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit().frame(width: 26, alignment: .trailing)
                            Button(element.label, action: open).buttonStyle(.link).lineLimit(1)
                            Spacer()
                            Text(value).monospacedDigit()
                        }
                        Divider()
                    }
                }
            }
        }
    }

    private func load() async {
        do {
            stats = try await browser.listening.api { try await $0.libraryStats(libraryID: libraryID, token: $1) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

protocol RankingRow { var label: String { get } }
extension AudiobookshelfClient.LibraryStats.Named: RankingRow { var label: String { title } }
extension AudiobookshelfClient.LibraryStats.Sized: RankingRow { var label: String { title ?? "—" } }

/// Kafelek z liczbą (statystyki słuchania i biblioteki).
struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(minWidth: 150, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
