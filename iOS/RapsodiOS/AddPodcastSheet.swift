// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AudiobookshelfKit

/// Arkusz „Dodaj podcast” (przycisk „+” w zakładce Podcasty): wyszukiwanie w iTunes albo
/// wklejony adres kanału RSS, potem formularz z danymi kanału. Serwer pozwala dodawać podcasty
/// tylko administratorom — zwykły słuchacz dostaje wyjaśnienie zamiast błędu 403.
struct AddPodcastSheet: View {
    let session: ServerSession
    let libraries: [Client.Library]
    /// Wywoływane z id nowej pozycji (albo `nil`, gdy konto i tak jej nie zobaczy).
    let onAdded: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var term = ""
    @State private var country = "pl"
    @State private var results: [Client.PodcastSearchResult] = []
    @State private var searched = false
    @State private var existing: [Client.PodcastTitle] = []
    @State private var busy: String?
    @State private var error: String?
    @State private var draft: PodcastDraft?
    @State private var seesExplicit: Bool?
    /// Katalogi, które nie odpowiedziały przy ostatnim wyszukiwaniu.
    @State private var failures: [String] = []
    @State private var hasIndexKey = PodcastIndexKey.load() != nil

    static let countries: [(String, String)] = [
        ("pl", "Polska"), ("us", "USA"), ("gb", "Wielka Brytania"), ("de", "Niemcy"), ("fr", "Francja"),
        ("es", "Hiszpania"), ("it", "Włochy"), ("ca", "Kanada"), ("au", "Australia"),
    ]

    private var countryOptions: [(String, String)] {
        Self.countries.contains { $0.0 == country } ? Self.countries : Self.countries + [(country, country.uppercased())]
    }

    private var trimmed: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isURL: Bool { trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Nazwa, autor albo adres RSS", text: $term)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(isURL ? .go : .search)
                        .onSubmit(submit)
                        .accessibilityIdentifier("addPodcast.term")
                    Picker("Sklep iTunes", selection: $country) {
                        ForEach(countryOptions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Button(isURL ? "Wczytaj kanał" : "Szukaj", systemImage: isURL ? "dot.radiowaves.left.and.right" : "magnifyingglass", action: submit)
                        .disabled(trimmed.isEmpty || busy != nil)
                } footer: {
                    Text("Wpisz nazwę podcastu albo wklej adres kanału RSS. Szukam w iTunes, fyyd"
                         + (hasIndexKey ? " i Podcast Index." : " — więcej wyników da klucz Podcast Index (Ustawienia → Podcasty → Wyszukiwanie podcastów).")
                         + " Przed dodaniem zobaczysz dane kanału.")
                }
                if let busy {
                    Section { Label { Text(busy) } icon: { ProgressView() }.foregroundStyle(.secondary) }
                } else if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("addPodcast.error")
                    }
                }
                if !results.isEmpty {
                    Section {
                        ForEach(results, id: \.key) { resultRow($0) }
                    } header: {
                        Text("Wyniki")
                    } footer: {
                        if !failures.isEmpty { Text(failures.joined(separator: " ")) }
                    }
                } else if searched, busy == nil, error == nil {
                    Section { Text("Brak wyników z kanałem RSS.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Dodaj podcast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } }
            }
            .navigationDestination(item: $draft) { start in
                PodcastDraftForm(session: session, draft: start, seesExplicit: seesExplicit) { id in
                    dismiss()
                    onAdded(id)
                }
            }
        }
        .task { await prepare() }
    }

    private func resultRow(_ result: Client.PodcastSearchResult) -> some View {
        let existingID = existingItem(for: result)
        return Button {
            if let existingID {
                dismiss()
                onAdded(existingID)
            } else if let feed = result.feedUrl {
                loadFeed(feed, from: result)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: result.cover.flatMap(URL.init(string:))) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.15)
                }
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title ?? "").font(.headline).lineLimit(2)
                    if let artist = result.artistName { Text(artist).foregroundStyle(.secondary).lineLimit(1) }
                    Text(details(result)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if existingID != nil {
                        Label("Już w bibliotece", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(busy != nil)
        .accessibilityIdentifier("addPodcast.result")
    }

    private func details(_ result: Client.PodcastSearchResult) -> String {
        var parts: [String] = []
        if let source = result.source, source != .itunes { parts.append(source.title) }
        if let count = result.trackCount { parts.append(PolishCount.episodes(count)) }
        if result.explicit == true { parts.append("dla dorosłych") }
        if let genres = result.genres, !genres.isEmpty { parts.append(genres.prefix(2).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func existingItem(for result: Client.PodcastSearchResult) -> String? {
        let title = result.title?.lowercased()
        return existing.first { podcast in
            (result.id != nil && podcast.itunesId == result.id.map(String.init)) || (title != nil && podcast.title?.lowercased() == title)
        }?.libraryItemId
    }

    private func prepare() async {
        seesExplicit = try? await session.auth.perform { try await $0.canAccessExplicitContent(token: $1) }
        guard let first = libraries.first else { return }
        if let region = try? await session.auth.perform({ try await $0.libraryDetails(id: first.id, token: $1) }).settings.podcastSearchRegion,
           !region.isEmpty {
            country = region
        }
        var titles: [Client.PodcastTitle] = []
        for library in libraries {
            titles += (try? await session.auth.perform { try await $0.podcastTitles(libraryID: library.id, token: $1) }) ?? []
        }
        existing = titles
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        if isURL {
            loadFeed(trimmed, from: nil)
            return
        }
        let term = trimmed, country = country, auth = session.auth
        let credentials = PodcastIndexKey.load()
        hasIndexKey = credentials != nil
        failures = []
        run("Szukanie w katalogach…", failure: "Nie udało się wyszukać") {
            let outcome = await PodcastDirectories.searchAll(term: term, podcastIndex: credentials) {
                try await auth.perform { try await $0.searchPodcasts(term: term, country: country, token: $1) }
            }
            // Wszystkie zawiodły — błąd zamiast pustej listy.
            if outcome.results.isEmpty, let first = outcome.failures.first, outcome.failures.count == (credentials == nil ? 2 : 3) {
                throw Failure(text: "Nie udało się wyszukać: \(first.message)")
            }
            results = outcome.results
            failures = outcome.failures.map { "\($0.directory.title): \($0.message)" }
            searched = true
        }
    }

    private func loadFeed(_ url: String, from result: Client.PodcastSearchResult?) {
        run("Wczytywanie kanału…", failure: "Nie udało się wczytać kanału") {
            do {
                let feed = try await session.auth.perform { try await $0.podcastFeed(url: url, token: $1) }
                draft = PodcastDraft(feed: feed, result: result, feedURL: url, libraries: libraries)
            } catch AudiobookshelfClient.APIError.http(404, _) {
                throw Failure(text: "Serwer nie pobrał kanału albo to nie jest kanał RSS podcastu.")
            }
        }
    }

    struct Failure: Error { let text: String }

    private func run(_ label: String, failure: String, _ work: @escaping () async throws -> Void) {
        guard busy == nil else { return }
        busy = label
        error = nil
        Task {
            defer { busy = nil }
            do {
                try await work()
            } catch let failure as Failure {
                error = failure.text
            } catch {
                self.error = AddPodcastSheet.message(for: error, action: failure)
            }
        }
    }

    static func message(for error: any Error, action: String) -> String {
        if case AudiobookshelfClient.APIError.http(403, _) = error {
            return "Dodawanie podcastów wymaga roli „Administrator” dla konta tego telefonu. Na Macu: ustawienia Rapsod → Użytkownicy → profil tej osoby → rola „Administrator”."
        }
        return "\(action): \(error.localizedDescription)"
    }
}

/// Szkic nowego podcastu: dane z iTunes (gdy wybrany z wyszukiwania), uzupełnione z kanału.
struct PodcastDraft: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var author: String
    var description: String
    var releaseDate: String
    var genres: String
    var feedURL: String
    var imageURL: String
    var itunesPageURL: String
    var itunesID: String
    var itunesArtistID: String
    var language: String
    var explicit: Bool
    var serial: Bool
    var autoDownload = AutoDownloadSettings()
    var libraryID: String
    var folderID: String
    let libraries: [Client.Library]
    let episodeCount: Int
    let newest: Date?
    let feedExplicit: Bool

    init(feed: Client.PodcastFeed, result: Client.PodcastSearchResult?, feedURL: String, libraries: [Client.Library]) {
        let meta = feed.metadata
        title = result?.title ?? meta.title ?? ""
        author = result?.artistName ?? meta.author ?? ""
        description = HTMLText.plain(result?.description) ?? meta.descriptionPlain ?? HTMLText.plain(meta.description) ?? ""
        releaseDate = result?.releaseDate ?? ""
        genres = (result?.genres ?? meta.categories ?? []).joined(separator: ", ")
        self.feedURL = result?.feedUrl ?? meta.feedUrl ?? feedURL
        imageURL = result?.cover ?? meta.image ?? ""
        itunesPageURL = result?.pageUrl ?? ""
        itunesID = result?.id.map(String.init) ?? ""
        itunesArtistID = result?.artistId.map(String.init) ?? ""
        language = meta.language ?? ""
        serial = (meta.type ?? "").lowercased() == "serial"
        explicit = result?.explicit == true || meta.isExplicit
        feedExplicit = explicit
        self.libraries = libraries
        libraryID = libraries.first?.id ?? ""
        folderID = libraries.first?.folders.first?.id ?? ""
        episodeCount = feed.episodes.count
        newest = feed.episodes.compactMap(\.published).max()
    }

    var library: Client.Library? { libraries.first { $0.id == libraryID } }
    var folders: [Client.Library.Folder] { library?.folders ?? [] }
    var folderName: String { Self.folderName(for: title) }

    var fullPath: String? {
        guard let folder = folders.first(where: { $0.id == folderID }), !folderName.isEmpty else { return nil }
        return URL(filePath: folder.fullPath).appending(path: folderName).path(percentEncoded: false)
    }

    var genreList: [String] {
        var seen = Set<String>()
        return genres.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    var payload: Client.NewPodcast? {
        guard let fullPath, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let clean = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return .init(path: fullPath, folderId: folderID, libraryId: libraryID, media: .init(
            metadata: .init(
                title: clean(title), author: clean(author), description: Self.html(clean(description)),
                releaseDate: releaseDate, genres: genreList, feedUrl: clean(feedURL), imageUrl: imageURL,
                itunesPageUrl: itunesPageURL, itunesId: itunesID, itunesArtistId: itunesArtistID,
                language: clean(language), explicit: explicit, type: serial ? "serial" : "episodic"),
            autoDownloadEpisodes: autoDownload.enabled))
    }

    /// Harmonogram i limity — serwer przy tworzeniu bierze tylko przełącznik, resztę zapisuje się
    /// zaraz potem. Harmonogram idzie zawsze, gdy pobieranie jest włączone (domyślny serwera
    /// mógł zostać zmieniony w jego ustawieniach).
    var settingsUpdate: Client.PodcastUpdate {
        var update = autoDownload.update(from: .serverDefaults)
        update.autoDownloadEpisodes = nil
        if autoDownload.enabled { update.autoDownloadSchedule = autoDownload.cron }
        return update
    }

    /// Nazwa folderu z tytułu: bez znaków niedozwolonych w nazwach plików i bez kropek
    /// i spacji na końcu; dwukropek zamieniony na myślnik, żeby „Seria: tytuł” zostało czytelne.
    static func folderName(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\?<>*|\"").union(.controlCharacters).union(.newlines)
        var result = ""
        for scalar in title.unicodeScalars {
            if scalar == ":" {
                result += " - "
            } else if !forbidden.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        let words = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var name = Substring(words)
        while let last = name.last, last == "." || last == " " { name.removeLast() }
        var trimmed = String(name)
        while trimmed.utf8.count > 240 { trimmed.removeLast() }
        return trimmed
    }

    /// Opis z pola tekstowego jako prosty HTML: akapity rozdzielone pustą linią.
    static func html(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return escaped.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "<p>" + $0.replacingOccurrences(of: "\n", with: "<br>") + "</p>" }
            .joined()
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Formularz przed dodaniem: dane kanału do poprawienia, biblioteka i folder, „dla dorosłych”.
private struct PodcastDraftForm: View {
    let session: ServerSession
    let seesExplicit: Bool?
    let onDone: (String?) -> Void
    @State private var draft: PodcastDraft
    @State private var busy = false
    @State private var error: String?
    /// Podcast już dodany, ale ustawień pobierania nie udało się zapisać.
    @State private var created: String??

    init(session: ServerSession, draft: PodcastDraft, seesExplicit: Bool?, onDone: @escaping (String?) -> Void) {
        self.session = session
        self.seesExplicit = seesExplicit
        self.onDone = onDone
        _draft = State(initialValue: draft)
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    AsyncImage(url: URL(string: draft.imageURL)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.secondary.opacity(0.15)
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(.rect(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draft.title.isEmpty ? "Nowy podcast" : draft.title).font(.headline).lineLimit(3)
                        Text("Odcinków w kanale: \(draft.episodeCount)").font(.footnote).foregroundStyle(.secondary)
                        if let newest = draft.newest {
                            Text("Najnowszy: \(newest.formatted(date: .long, time: .omitted))").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                TextField("Tytuł", text: $draft.title).accessibilityIdentifier("newPodcast.title")
                TextField("Autor", text: $draft.author).accessibilityIdentifier("newPodcast.author")
                TextField("Gatunki (po przecinku)", text: $draft.genres)
                TextField("Język", text: $draft.language).textInputAutocapitalization(.never)
                Picker("Typ", selection: $draft.serial) {
                    Text("Odcinkowy").tag(false)
                    Text("Seryjny").tag(true)
                }
            } footer: {
                Text("Odcinkowy: najnowsze odcinki pierwsze. Seryjny: słucha się po kolei.")
            }
            Section {
                Toggle("Dla dorosłych", isOn: $draft.explicit).accessibilityIdentifier("newPodcast.explicit")
                if draft.explicit, seesExplicit == false {
                    Label("To konto nie ma dostępu do treści dla dorosłych — podcast nie pojawi się na tym telefonie."
                          + (draft.feedExplicit ? " Kanał sam się tak oznacza; wyłącz, jeśli chcesz go tu słuchać." : ""),
                          systemImage: "eye.slash")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            AutoDownloadSections(settings: $draft.autoDownload,
                                 note: draft.autoDownload.enabled ? "Teraz nic się nie pobierze — wybierz odcinki na stronie podcastu po dodaniu." : nil)
            Section {
                if draft.libraries.count > 1 {
                    Picker("Biblioteka", selection: $draft.libraryID) {
                        ForEach(draft.libraries) { Text($0.name).tag($0.id) }
                    }
                }
                if draft.folders.count > 1 {
                    Picker("Folder biblioteki", selection: $draft.folderID) {
                        ForEach(draft.folders, id: \.id) { Text($0.fullPath).tag($0.id) }
                    }
                }
                LabeledContent("Folder podcastu") {
                    Text(draft.fullPath ?? "—").foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
            }
            Section("Adres kanału RSS") {
                TextField("Adres kanału RSS", text: $draft.feedURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            Section("Opis") {
                TextField("Opis", text: $draft.description, axis: .vertical).lineLimit(4...12)
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("newPodcast.error")
                }
            }
        }
        .navigationTitle("Nowy podcast")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if busy {
                    ProgressView()
                } else if let created {
                    Button("Gotowe") { onDone(created) }
                } else {
                    Button("Dodaj", action: create)
                        .disabled(draft.payload == nil)
                        .accessibilityIdentifier("newPodcast.create")
                }
            }
        }
        .onChange(of: draft.libraryID) {
            if !draft.folders.contains(where: { $0.id == draft.folderID }) { draft.folderID = draft.folders.first?.id ?? "" }
        }
        .interactiveDismissDisabled(busy)
    }

    private func create() {
        guard let payload = draft.payload else { return }
        let hidden = draft.explicit && seesExplicit == false
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let id = try await session.auth.perform { try await $0.createPodcast(payload, token: $1) }
                let update = draft.settingsUpdate
                if !update.isEmpty {
                    do {
                        _ = try await session.auth.perform { try await $0.updatePodcast(itemID: id, update, token: $1) }
                    } catch {
                        created = .some(hidden ? nil : id)
                        self.error = "Podcast dodany, ale bez ustawień pobierania. " + PodcastSettingsSheet.message(for: error)
                        return
                    }
                }
                onDone(hidden ? nil : id)
            } catch AudiobookshelfClient.APIError.http(400, let body) where body.contains("already exists") {
                error = "Podcast w folderze „\(draft.folderName)” już jest w bibliotece."
            } catch {
                self.error = AddPodcastSheet.message(for: error, action: "Nie udało się dodać podcastu")
            }
        }
    }
}
