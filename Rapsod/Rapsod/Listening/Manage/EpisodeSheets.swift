import AppKit
import AudiobookshelfKit
import SwiftUI

/// „Odcinki z kanału”: lista odcinków z RSS z zaznaczaniem i pobieraniem wybranych —
/// jak `modals/podcast/EpisodeFeed.vue`. Pobrane rozpoznaje po `guid`, a bez niego po adresie pliku.
struct EpisodeFeedSheet: View {
    let browser: LibraryBrowser
    let item: AudiobookshelfClient.ItemDetail
    @Environment(\.dismiss) private var dismiss
    @State private var episodes: [AudiobookshelfClient.FeedEpisode]?
    @State private var selected: Set<Int> = []
    @State private var query = ""
    @State private var hideDownloaded = true
    @State private var busy: String?
    @State private var error: String?

    var body: some View {
        // Klucze pobranych liczone raz na przebieg `body`, nie dla każdego wiersza.
        let downloaded = downloadedKeys
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Odcinki z kanału").font(.title2.weight(.semibold))
                    Text(item.title).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Szukaj odcinka", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                Toggle("Ukryj pobrane", isOn: $hideDownloaded).toggleStyle(.checkbox)
            }
            if let episodes {
                let shown = visible(episodes, downloaded)
                List(shown) { episode in
                    row(episode, downloaded: downloaded.contains(episode))
                }
                .listStyle(.inset)
                .accessibilityIdentifier("feed.episodes")
                .overlay {
                    if shown.isEmpty {
                        ContentUnavailableView(episodes.isEmpty ? "Kanał nie ma odcinków" : "Wszystkie odcinki są już pobrane", systemImage: "checkmark.circle")
                    }
                }
            } else if let error {
                ContentUnavailableView {
                    Label("Nie udało się wczytać kanału", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Spróbuj ponownie") { Task { await load() } }
                }
            } else {
                ProgressView("Wczytywanie kanału…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                if let busy {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(.secondary)
                } else if let error, episodes != nil {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3)
                }
                Spacer()
                if let episodes {
                    let candidates = visible(episodes, downloaded).filter { !downloaded.contains($0) }
                    Button(selected.isEmpty ? "Zaznacz widoczne" : "Odznacz wszystkie") {
                        selected = selected.isEmpty ? Set(candidates.map(\.id)) : []
                    }
                    .disabled(candidates.isEmpty && selected.isEmpty)
                }
                Button("Anuluj") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(selected.isEmpty ? "Pobierz" : "Pobierz zaznaczone (\(selected.count))", action: download)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || busy != nil)
                    .accessibilityIdentifier("feed.download")
            }
            .font(.callout)
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 780, minHeight: 560, idealHeight: 660)
        .task { await load() }
    }

    private func row(_ episode: AudiobookshelfClient.FeedEpisode, downloaded: Bool) -> some View {
        Toggle(isOn: Binding(get: { downloaded || selected.contains(episode.id) },
                                    set: { if $0 { selected.insert(episode.id) } else { selected.remove(episode.id) } })) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(episode.title).font(.headline).lineLimit(2)
                    if downloaded { Label("Pobrany", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                    if episode.episodeType == "trailer" { Text("zwiastun").font(.caption).foregroundStyle(.secondary) }
                    if episode.episodeType == "bonus" { Text("dodatek").font(.caption).foregroundStyle(.secondary) }
                }
                if let text = episode.subtitle.flatMap({ HTMLText.plain($0) }) ?? episode.descriptionPlain {
                    Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 10) {
                    if let date = episode.published { Text(Formats.day(date)) }
                    if let season = episode.season { Text("Sezon \(season)") }
                    if let number = episode.episode { Text("Odcinek \(number)") }
                    if let seconds = episode.durationSeconds { Text(Formats.duration(seconds)) }
                    if let size = episode.size, size > 0 { Text(Formats.size(size)) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(downloaded || episode.url == nil)
        .padding(.vertical, 3)
    }

    private func visible(_ episodes: [AudiobookshelfClient.FeedEpisode], _ downloaded: DownloadedKeys) -> [AudiobookshelfClient.FeedEpisode] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return episodes.filter { episode in
            (!hideDownloaded || !downloaded.contains(episode)) && (text.isEmpty || episode.title.localizedCaseInsensitiveContains(text))
        }
    }

    /// Jak `EpisodeFeed.vue`: najpierw `guid`, w drugiej kolejności adres bez parametrów śledzących.
    private struct DownloadedKeys {
        let guids: Set<String>
        let urls: Set<String>
        /// Już w kolejce serwera — też nie do ponownego wyboru.
        let queued: [AudiobookshelfClient.EpisodeDownload]

        func contains(_ episode: AudiobookshelfClient.FeedEpisode) -> Bool {
            if let guid = episode.guid, guids.contains(guid) { return true }
            if let url = episode.url, urls.contains(AudiobookshelfClient.cleanEpisodeURL(url)) { return true }
            return queued.contains { d in (episode.guid != nil && d.guid == episode.guid) || (d.url != nil && d.url == episode.url) }
        }
    }

    private var downloadedKeys: DownloadedKeys {
        let local = item.media.episodes?.elements ?? []
        let queued = ([browser.listening.episodeDownloads.current].compactMap { $0 } + browser.listening.episodeDownloads.queue)
            .filter { $0.libraryItemId == item.id }
        return DownloadedKeys(
            guids: Set(local.compactMap(\.guid)),
            urls: Set(local.compactMap { $0.enclosure?.url.map(AudiobookshelfClient.cleanEpisodeURL) }),
            queued: queued
        )
    }

    private func load() async {
        guard let feed = item.media.metadata.feedUrl, !feed.isEmpty else {
            error = "Podcast nie ma adresu kanału RSS — dodaj go w edycji podcastu (Szczegóły)."
            return
        }
        error = nil
        do {
            episodes = try await browser.manager.run { try await $0.podcastFeed(url: feed, token: $1) }.episodes
        } catch AudiobookshelfClient.APIError.http(404, _) {
            error = "Serwer nie pobrał kanału albo to nie jest kanał RSS podcastu."
        } catch {
            self.error = ItemManager.message(for: error, action: "Nie udało się wczytać kanału")
        }
    }

    private func download() {
        guard let episodes else { return }
        let chosen = episodes.filter { selected.contains($0.id) }
        let id = item.id
        busy = "Dodawanie do kolejki…"
        Task {
            defer { busy = nil }
            do {
                try await browser.manager.run { try await $0.downloadEpisodes(itemID: id, chosen, token: $1) }
                dismiss()
            } catch {
                self.error = ItemManager.message(for: error, action: "Nie udało się zlecić pobrania")
            }
        }
    }
}

/// „Sprawdź nowe odcinki”: od wybranej daty, najwyżej N — jak przycisk na stronie podcastu
/// w web UI (najpierw `lastEpisodeCheck`, potem `checknew`). Znalezione od razu idą do kolejki.
struct CheckNewEpisodesSheet: View {
    let browser: LibraryBrowser
    let item: AudiobookshelfClient.ItemDetail
    @Environment(\.dismiss) private var dismiss
    @State private var since = Date()
    @State private var limit = 3
    @State private var busy = false
    @State private var result: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sprawdź nowe odcinki").font(.title3.weight(.semibold))
            Form {
                DatePicker("Opublikowane po", selection: $since, in: ...Date())
                Stepper(value: $limit, in: 0...100) {
                    LabeledContent("Najwyżej", value: limit == 0 ? "bez limitu" : "\(limit)")
                }
            }
            Text("Nowe odcinki od razu trafią do kolejki pobierania.").font(.callout).foregroundStyle(.secondary)
            if let result { Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green).accessibilityIdentifier("checkNew.result") }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(result == nil ? "Anuluj" : "Zamknij") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sprawdź", action: check)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
                    .accessibilityIdentifier("checkNew.run")
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if let ms = item.media.lastEpisodeCheck, ms > 0 { since = Date(timeIntervalSince1970: ms / 1000) }
            else if let newest = item.media.episodes?.elements.compactMap(\.published).max() { since = newest }
            else { since = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date() }
        }
    }

    private func check() {
        let id = item.id, limit = limit
        let ms = (since.timeIntervalSince1970 * 1000).rounded()
        busy = true
        error = nil
        result = nil
        Task {
            defer { busy = false }
            do {
                var update = AudiobookshelfClient.PodcastUpdate()
                update.lastEpisodeCheck = ms
                _ = try await browser.manager.run { try await $0.updatePodcast(itemID: id, update, token: $1) }
                let found = try await browser.manager.run { try await $0.checkNewEpisodes(itemID: id, limit: limit, token: $1) }
                result = found == 0 ? "Brak nowych odcinków." : "Nowe odcinki: \(found) — w kolejce pobierania."
            } catch AudiobookshelfClient.APIError.http(400, _) {
                error = "Podcast nie ma adresu kanału RSS."
            } catch {
                self.error = ItemManager.message(for: error, action: "Nie udało się sprawdzić kanału")
            }
        }
    }
}

/// Edycja odcinka (`modals/podcast/tabs/EpisodeDetails.vue`).
struct EpisodeEditSheet: View {
    let browser: LibraryBrowser
    let itemID: String
    let episode: AudiobookshelfClient.PodcastEpisode
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var subtitle = ""
    @State private var description = ""
    @State private var season = ""
    @State private var number = ""
    @State private var type = "full"
    @State private var hasDate = false
    @State private var date = Date()
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edycja odcinka").font(.title3.weight(.semibold)).padding([.horizontal, .top], 20)
            Form {
                TextField("Tytuł", text: $title).accessibilityIdentifier("episodeEdit.title")
                TextField("Podtytuł", text: $subtitle)
                HStack {
                    TextField("Sezon", text: $season)
                    TextField("Numer odcinka", text: $number)
                }
                Picker("Typ", selection: $type) {
                    Text("Pełny").tag("full")
                    Text("Zwiastun").tag("trailer")
                    Text("Dodatek").tag("bonus")
                }
                // Serwer nie umie wyczyścić `publishedAt` (musi być liczbą), więc daty nie da się usunąć.
                Toggle("Data publikacji", isOn: $hasDate).disabled(episode.publishedAt != nil)
                if hasDate { DatePicker("Opublikowano", selection: $date) }
                Section("Opis") {
                    TextEditor(text: $description).frame(minHeight: 140).accessibilityLabel("Opis")
                }
            }
            .formStyle(.grouped)
            HStack {
                if busy { ProgressView().controlSize(.small) }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3) }
                Spacer()
                Button("Anuluj") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Zapisz", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(busy || update.isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("episodeEdit.save")
            }
            .font(.callout)
            .padding(16)
        }
        .frame(width: 560, height: 600)
        .onAppear {
            title = episode.title ?? ""
            subtitle = HTMLText.plain(episode.subtitle) ?? ""
            description = HTMLText.plain(episode.description) ?? ""
            season = episode.season ?? ""
            number = episode.episode ?? ""
            type = episode.episodeType.flatMap { ["full", "trailer", "bonus"].contains($0) ? $0 : nil } ?? "full"
            if let published = episode.published { hasDate = true; date = published }
        }
    }

    /// Data w formacie z kanałów RSS (RFC 2822), jak `$formatJsDate(…, 'E, d MMM yyyy HH:mm:ssxx')`.
    private static let rfc2822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ssxx"
        return f
    }()

    private var update: AudiobookshelfClient.EpisodeUpdate {
        func changed(_ new: String, _ old: String?) -> String? {
            let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
            return n == (old ?? "").trimmingCharacters(in: .whitespacesAndNewlines) ? nil : n
        }
        var u = AudiobookshelfClient.EpisodeUpdate()
        u.title = changed(title, episode.title)
        if let s = changed(subtitle, HTMLText.plain(episode.subtitle)) { u.subtitle = s }
        if changed(description, HTMLText.plain(episode.description)) != nil {
            u.description = HTMLText.html(fromPlain: description.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        u.season = changed(season, episode.season)
        u.episode = changed(number, episode.episode)
        if type != (episode.episodeType ?? "full") { u.episodeType = type }
        if hasDate {
            let ms = (date.timeIntervalSince1970 * 1000).rounded()
            if episode.publishedAt.map({ abs($0 - ms) >= 60_000 }) ?? true {
                u.publishedAt = ms
                u.pubDate = Self.rfc2822.string(from: date)
            }
        }
        return u
    }

    private func save() {
        let update = update, itemID = itemID, episodeID = episode.id
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await browser.manager.run { try await $0.updateEpisode(itemID: itemID, episodeID: episodeID, update, token: $1) }
                dismiss()
            } catch {
                self.error = ItemManager.message(for: error, action: "Nie udało się zapisać odcinka")
            }
        }
    }
}

/// Akcje zarządzania odcinkiem w menu kontekstowym wiersza: edycja i usunięcie (z plikiem albo bez).
struct EpisodeManageMenu: View {
    let browser: LibraryBrowser
    let episode: AudiobookshelfClient.PodcastEpisode
    @Binding var editing: Bool
    @Binding var removing: Bool

    var body: some View {
        if browser.manager.isAvailable {
            Divider()
            Button("Edytuj odcinek…") { editing = true }
            Button("Usuń odcinek…", role: .destructive) { removing = true }
        }
    }
}

extension View {
    /// Arkusz edycji i potwierdzenie usunięcia odcinka. Potwierdzenie mówi wprost, co zniknie z dysku.
    func episodeManagement(browser: LibraryBrowser, itemID: String, episode: AudiobookshelfClient.PodcastEpisode,
                           editing: Binding<Bool>, removing: Binding<Bool>) -> some View {
        modifier(EpisodeManagement(browser: browser, itemID: itemID, episode: episode, editing: editing, removing: removing))
    }
}

private struct EpisodeManagement: ViewModifier {
    let browser: LibraryBrowser
    let itemID: String
    let episode: AudiobookshelfClient.PodcastEpisode
    @Binding var editing: Bool
    @Binding var removing: Bool

    func body(content: Content) -> some View {
        let file = episode.audioFile?.metadata?.filename ?? "plik audio"
        content
            .sheet(isPresented: $editing) { EpisodeEditSheet(browser: browser, itemID: itemID, episode: episode) }
            .confirmationDialog("Usunąć odcinek „\(episode.title ?? "Odcinek")”?", isPresented: $removing) {
                Button("Usuń z biblioteki", role: .destructive) { remove(hard: false) }
                Button("Usuń razem z plikiem", role: .destructive) { remove(hard: true) }
                    .accessibilityIdentifier("episode.removeHard")
                Button("Anuluj", role: .cancel) {}
            } message: {
                Text("„Usuń z biblioteki” zostawia plik „\(file)” na dysku (przy następnym skanie wróci jako odcinek). „Usuń razem z plikiem” kasuje go z dysku na stałe. W obu przypadkach znika postęp słuchania odcinka i jego wpisy w playlistach — także na telefonie.")
            }
    }

    private func remove(hard: Bool) {
        let listening = browser.listening
        let key = ListeningController.key(itemID, episode.id)
        let itemID = itemID, episodeID = episode.id
        Task {
            // Odtwarzacz czyta plik prosto z dysku — najpierw go zamyka.
            if listening.player.book?.key == key { await listening.stopPlayback() }
            do {
                try await browser.manager.run { try await $0.removeEpisode(itemID: itemID, episodeID: episodeID, hard: hard, token: $1) }
            } catch {
                listening.loadError = ItemManager.message(for: error, action: "Nie udało się usunąć odcinka")
            }
        }
    }
}
