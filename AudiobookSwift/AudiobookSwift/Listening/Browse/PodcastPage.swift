import AppKit
import SwiftUI

/// Strona podcastu: opis i odcinki z postępem, opisem, filtrem i sortowaniem. Zarządzanie
/// (etap 9d, konto root): „Edytuj” (szczegóły, okładka, harmonogram, dopasowanie), odcinki
/// z kanału do pobrania, sprawdzanie nowych, dopasowanie opisów odcinków; w wierszu odcinka
/// edycja i usunięcie.
struct PodcastPage: View {
    let browser: LibraryBrowser
    let item: AudiobookshelfClient.ItemDetail
    @State private var filter = EpisodeFilter.incomplete
    @State private var sort = "publishedAt"
    @State private var query = ""
    @FocusState private var queryFocused: Bool
    @State private var shown: AudiobookshelfClient.PodcastEpisode?
    @State private var editing: EditRequest?
    @State private var showsFeed = false
    @State private var checksNew = false
    @State private var confirmMatch = false
    @State private var notice: String?
    @State private var itemAction: ItemAction?

    private struct EditRequest: Identifiable {
        let tab: ItemEditorModel.Tab
        var id: ItemEditorModel.Tab { tab }
    }

    enum EpisodeFilter: String, CaseIterable {
        case incomplete = "Nieukończone", inProgress = "W trakcie", complete = "Ukończone", all = "Wszystkie"
    }

    private var listening: ListeningController { browser.listening }

    var body: some View {
        let metadata = item.media.metadata
        let episodes = visibleEpisodes
        List {
            Section {
                HStack(alignment: .top, spacing: 20) {
                    AsyncCover(listening: listening, itemID: item.id, path: item.media.coverPath, size: 180, symbol: "mic")
                        .frame(width: 180, height: 180)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.title.weight(.semibold))
                        if let author = metadata.author { Text(author).foregroundStyle(.secondary) }
                        if let genres = metadata.genres, !genres.isEmpty {
                            LinkList(values: genres.map { g in (g, { browser.open(.filtered(.genre(g))) }) })
                        }
                        if let description = HTMLText.plain(metadata.description) { ExpandableText(text: description, lines: 5) }
                        actions
                        if let notice {
                            Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                                .accessibilityIdentifier("podcast.notice")
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            Section {
                ForEach(episodes) { episode in
                    EpisodeRow(browser: browser, itemID: item.id, libraryID: item.libraryId, episode: episode) { shown = episode }
                }
            } header: {
                HStack {
                    Text("Odcinki (\(episodes.count))")
                    Spacer()
                    TextField("Szukaj odcinka", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                        .focused($queryFocused)
                        .onChange(of: queryFocused) { browser.textField("podcast.episodeSearch", focused: queryFocused) }
                        .onDisappear { browser.textField("podcast.episodeSearch", focused: false) }
                    Picker("Pokaż", selection: $filter) { ForEach(EpisodeFilter.allCases, id: \.self) { Text($0.rawValue) } }
                        .labelsHidden().fixedSize()
                    Picker("Sortuj", selection: $sort) {
                        Text("Data publikacji").tag("publishedAt")
                        Text("Tytuł").tag("title")
                        Text("Sezon").tag("season")
                        Text("Numer odcinka").tag("episode")
                    }
                    .labelsHidden().fixedSize()
                    .help("Sortowanie odcinków")
                }
            }
        }
        .sheet(item: $shown) { episode in EpisodeDetails(podcast: item.title, author: metadata.author, episode: episode) }
        .sheet(item: $editing) { request in ItemEditorSheet(browser: browser, item: item, tab: request.tab) }
        .sheet(isPresented: $showsFeed) { EpisodeFeedSheet(browser: browser, item: item) }
        .sheet(isPresented: $checksNew) { CheckNewEpisodesSheet(browser: browser, item: item) }
        .itemActions(browser: browser, item: item, action: $itemAction)
        .confirmationDialog("Dopasować opisy odcinków do kanału?", isPresented: $confirmMatch) {
            Button("Uzupełnij puste pola") { matchEpisodes(override: false) }
            Button("Nadpisz wszystkie z kanału", role: .destructive) { matchEpisodes(override: true) }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Serwer porówna pobrane odcinki z kanałem RSS i przepisze z niego tytuły, opisy, daty i numery. Pliki audio się nie zmieniają.")
        }
    }

    private var actions: some View {
        let manager = browser.manager
        let hasFeed = !(item.media.metadata.feedUrl ?? "").isEmpty
        return HStack(spacing: 8) {
            Button("Odcinki z kanału…", systemImage: "arrow.down.circle") { showsFeed = true }
                .disabled(!manager.isAvailable || !hasFeed)
                .help(!manager.isAvailable ? manager.unavailableReason : hasFeed ? "Wybierz odcinki z kanału RSS do pobrania" : "Podcast nie ma adresu kanału RSS")
                .accessibilityIdentifier("podcast.feed")
            Button {
                editing = EditRequest(tab: .details)
            } label: {
                Label("Edytuj", systemImage: "pencil").labelStyle(.iconOnly)
            }
            .disabled(!manager.isAvailable)
            .help(manager.isAvailable ? "Edytuj szczegóły, okładkę i harmonogram pobierania" : manager.unavailableReason)
            .accessibilityLabel("Edytuj")
            .accessibilityIdentifier("podcast.edit")
            Menu {
                if manager.isAvailable {
                    Button("Sprawdź nowe odcinki…") { checksNew = true }.disabled(!hasFeed)
                    Button("Dopasuj opisy odcinków…") { confirmMatch = true }.disabled(!hasFeed)
                    Divider()
                    Button("Edytuj szczegóły…") { editing = EditRequest(tab: .details) }
                    Button("Okładka…") { editing = EditRequest(tab: .cover) }
                    Button("Harmonogram pobierania…") { editing = EditRequest(tab: .schedule) }
                    Button("Dopasuj w iTunes…") { editing = EditRequest(tab: .match) }
                    Button("Skanuj ponownie") { itemAction = .scan }
                    Divider()
                }
                Button("Oznacz wszystkie jako ukończone") { markAll(true) }
                Button("Oznacz wszystkie jako nieukończone") { markAll(false) }
                if let path = item.path {
                    Divider()
                    Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
                }
                if manager.isAvailable {
                    Divider()
                    Button("Usuń podcast…", role: .destructive) { itemAction = .delete }
                }
            } label: {
                Label("Więcej", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Więcej")
            .accessibilityIdentifier("podcast.more")
            if item.media.autoDownloadEpisodes == true {
                Label("Pobiera nowe automatycznie", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary)
            }
        }
        .controlSize(.regular)
        .padding(.top, 4)
    }

    private func matchEpisodes(override: Bool) {
        let id = item.id
        notice = "Dopasowywanie odcinków…"
        Task {
            do {
                let count = try await browser.manager.run { try await $0.quickMatchEpisodes(itemID: id, override: override, token: $1) }
                notice = count == 0 ? "Żaden odcinek nie wymagał zmian." : "Zaktualizowano odcinki: \(count)."
            } catch {
                notice = ItemManager.message(for: error, action: "Nie udało się dopasować odcinków")
            }
        }
    }

    private var visibleEpisodes: [AudiobookshelfClient.PodcastEpisode] {
        var list = item.media.episodes?.elements ?? []
        list = list.filter { episode in
            let p = listening.progress[ListeningController.key(item.id, episode.id)]
            switch filter {
            case .all: return true
            case .complete: return p?.isFinished == true
            case .incomplete: return p?.isFinished != true
            case .inProgress: return p?.isFinished != true && (p?.currentTime ?? 0) > 0
            }
        }
        let text = query.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { list = list.filter { ($0.title ?? "").localizedCaseInsensitiveContains(text) } }
        switch sort {
        case "title": list.sort { ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending }
        case "season": list.sort { ($0.season ?? "").localizedStandardCompare($1.season ?? "") == .orderedDescending }
        case "episode": list.sort { ($0.episode ?? "").localizedStandardCompare($1.episode ?? "") == .orderedDescending }
        default: list.sort { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) }
        }
        return list
    }

    private func markAll(_ finished: Bool) {
        let entries = (item.media.episodes?.elements ?? []).map { AudiobookshelfClient.BatchProgress(libraryItemId: item.id, episodeId: $0.id, isFinished: finished) }
        Task { await listening.setFinished(entries) }
    }
}

private struct EpisodeDetails: View {
    let podcast: String
    let author: String?
    let episode: AudiobookshelfClient.PodcastEpisode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(podcast + (author.map { " — \($0)" } ?? "")).font(.callout).foregroundStyle(.secondary)
            Text(episode.title ?? "Odcinek").font(.title2.weight(.semibold))
            ScrollView {
                Text(HTMLText.plain(episode.description) ?? "Brak opisu.").textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let file = episode.audioFile?.metadata?.filename { GridRow { Text("Plik").foregroundStyle(.secondary); Text(file) } }
                GridRow { Text("Rozmiar").foregroundStyle(.secondary); Text(Formats.size(episode.size ?? episode.audioFile?.metadata?.size)) }
                GridRow { Text("Czas").foregroundStyle(.secondary); Text(Formats.duration(episode.length)) }
                if let date = episode.published { GridRow { Text("Opublikowano").foregroundStyle(.secondary); Text(Formats.day(date, long: true)) } }
            }
            .font(.callout)
            HStack { Spacer(); Button("Zamknij") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }
}
