import AppKit
import AudiobookshelfKit
import SwiftUI

// Zakładki arkusza edycji dla podcastu (etap 9d): Szczegóły, Harmonogram i Dopasuj (iTunes).
// Okładka korzysta z `CoverTab`; wzorzec: `PodcastDetailsEdit.vue`, `tabs/Schedule.vue`, `tabs/Match.vue`.

/// Szkic szczegółów podcastu (`Podcast.updateFromRequest`).
struct PodcastDraft: Equatable {
    var title: String
    var author: String
    var description: String
    var releaseDate: String
    var genres: [String]
    var tags: [String]
    var feedURL: String
    var itunesPageURL: String
    var itunesID: String
    var language: String
    var type: String
    var explicit: Bool

    init(_ item: AudiobookshelfClient.ItemDetail) {
        let m = item.media.metadata
        title = m.title ?? ""
        author = m.author ?? ""
        description = HTMLText.plain(m.description) ?? ""
        releaseDate = m.releaseDate ?? ""
        genres = m.genres ?? []
        tags = item.media.tags ?? []
        feedURL = m.feedUrl ?? ""
        itunesPageURL = m.itunesPageUrl ?? ""
        itunesID = m.itunesId ?? ""
        language = m.language ?? ""
        type = m.type == "serial" ? "serial" : "episodic"
        explicit = m.explicit ?? false
    }

    var problem: String? {
        if DetailsDraft.clean(title).isEmpty { return "Tytuł nie może być pusty." }
        let feed = DetailsDraft.clean(feedURL)
        if !feed.isEmpty, !CoverTab.isWebURL(feed) { return "Adres kanału musi zaczynać się od http:// albo https://." }
        return nil
    }

    func update(from base: PodcastDraft) -> AudiobookshelfClient.PodcastUpdate {
        func text(_ new: String, _ old: String) -> String? { DetailsDraft.clean(new) == DetailsDraft.clean(old) ? nil : DetailsDraft.clean(new) }
        var m = AudiobookshelfClient.PodcastUpdate.Metadata()
        m.title = text(title, base.title)
        m.author = text(author, base.author)
        if DetailsDraft.clean(description) != DetailsDraft.clean(base.description) { m.description = HTMLText.html(fromPlain: DetailsDraft.clean(description)) }
        m.releaseDate = text(releaseDate, base.releaseDate)
        if DetailsDraft.clean(genres) != DetailsDraft.clean(base.genres) { m.genres = DetailsDraft.clean(genres) }
        m.feedUrl = text(feedURL, base.feedURL)
        m.itunesPageUrl = text(itunesPageURL, base.itunesPageURL)
        m.itunesId = text(itunesID, base.itunesID)
        m.language = text(language, base.language)
        if type != base.type { m.type = type }
        if explicit != base.explicit { m.explicit = explicit }
        var update = AudiobookshelfClient.PodcastUpdate()
        if !m.isEmpty { update.metadata = m }
        if DetailsDraft.clean(tags) != DetailsDraft.clean(base.tags) { update.tags = DetailsDraft.clean(tags) }
        return update
    }
}

/// Harmonogram automatycznego pobierania. Wyrażenie cron jak w serwerze (`node-cron`, 5 pól).
struct ScheduleDraft: Equatable {
    enum Preset: String, CaseIterable {
        case hourly, every6h, daily, weekly, custom
        var title: String {
            switch self {
            case .hourly: "Co godzinę"
            case .every6h: "Co 6 godzin"
            case .daily: "Codziennie"
            case .weekly: "Co tydzień"
            case .custom: "Własne (cron)"
            }
        }
    }

    var enabled: Bool
    var preset: Preset
    var hour: Int
    /// 0 = niedziela (jak w cronie).
    var weekday: Int
    var cron: String
    var maxNew: Int
    var maxKeep: Int

    init(_ item: AudiobookshelfClient.ItemDetail) {
        enabled = item.media.autoDownloadEpisodes ?? false
        maxNew = item.media.maxNewEpisodesToDownload ?? 3
        maxKeep = item.media.maxEpisodesToKeep ?? 0
        cron = item.media.autoDownloadSchedule ?? "0 * * * *"
        hour = 6
        weekday = 1
        preset = .custom
        let parts = cron.split(separator: " ").map(String.init)
        guard parts.count == 5, parts[0] == "0", parts[2] == "*", parts[3] == "*" else { return }
        switch (parts[1], parts[4]) {
        case ("*", "*"): preset = .hourly
        case ("*/6", "*"): preset = .every6h
        case (let h, "*") where Int(h).map({ (0...23).contains($0) }) == true: preset = .daily; hour = Int(h)!
        case (let h, let d) where Int(h).map({ (0...23).contains($0) }) == true && Int(d).map({ (0...6).contains($0) }) == true:
            preset = .weekly; hour = Int(h)!; weekday = Int(d)!
        default: break
        }
    }

    var expression: String {
        switch preset {
        case .hourly: "0 * * * *"
        case .every6h: "0 */6 * * *"
        case .daily: "0 \(hour) * * *"
        case .weekly: "0 \(hour) * * \(weekday)"
        case .custom: cron.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
    }

    var problem: String? {
        if maxNew < 0 || maxKeep < 0 { return "Limity nie mogą być ujemne." }
        if preset == .custom, expression.split(separator: " ").count != 5 {
            return "Wyrażenie cron ma 5 pól: minuta, godzina, dzień miesiąca, miesiąc, dzień tygodnia (np. „0 6 * * *”)."
        }
        return nil
    }

    func update(from base: ScheduleDraft) -> AudiobookshelfClient.PodcastUpdate {
        var update = AudiobookshelfClient.PodcastUpdate()
        if enabled != base.enabled { update.autoDownloadEpisodes = enabled }
        if expression != base.expression { update.autoDownloadSchedule = expression }
        if maxNew != base.maxNew { update.maxNewEpisodesToDownload = maxNew }
        if maxKeep != base.maxKeep { update.maxEpisodesToKeep = maxKeep }
        return update
    }

    /// Te same ustawienia na serwerze (wariant i pola pomocnicze mogą się różnić). Nie jako `==`:
    /// `@Observable` nie powiadamia o zmianie na wartość „równą”, więc wybór „Własne” przy tym samym
    /// wyrażeniu nie odświeżałby formularza.
    func isSame(as base: ScheduleDraft) -> Bool { update(from: base).isEmpty }

    static func episodes(_ n: Int) -> String {
        let tens = n % 100, ones = n % 10
        if n == 1 { return "1 odcinek" }
        if (2...4).contains(ones) && !(12...14).contains(tens) { return "\(n) odcinki" }
        return "\(n) odcinków"
    }

    static let weekdays = ["niedziela", "poniedziałek", "wtorek", "środa", "czwartek", "piątek", "sobota"]
}

struct PodcastDetailsTab: View {
    @Bindable var model: ItemEditorModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Tytuł", text: $model.podcast.title).accessibilityIdentifier("podcast.title")
                    TextField("Autor", text: $model.podcast.author).accessibilityIdentifier("podcast.author")
                    TextField("Adres kanału RSS", text: $model.podcast.feedURL).accessibilityIdentifier("podcast.feed")
                    TextField("Data wydania", text: $model.podcast.releaseDate)
                }
                Section {
                    LabeledContent("Gatunki") {
                        TokenInput(values: $model.podcast.genres, suggestions: model.browser.filterData?.genres ?? [], placeholder: "Gatunek")
                    }
                    LabeledContent("Tagi") {
                        TokenInput(values: $model.podcast.tags, suggestions: model.browser.filterData?.tags ?? [], placeholder: "Tag")
                    }
                    TextField("Język", text: $model.podcast.language)
                    Picker("Typ", selection: $model.podcast.type) {
                        Text("Odcinkowy (najnowsze pierwsze)").tag("episodic")
                        Text("Seryjny (po kolei)").tag("serial")
                    }
                    Toggle("Dla dorosłych", isOn: $model.podcast.explicit).accessibilityIdentifier("podcast.explicit")
                    if model.podcast.explicit, !model.podcastBase.explicit, model.listenerSeesExplicit == false {
                        Label("Konto słuchacza nie ma dostępu do treści dla dorosłych — po zapisie ten podcast zniknie z jego biblioteki i z telefonu.", systemImage: "eye.slash")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                Section("iTunes") {
                    TextField("Strona w iTunes", text: $model.podcast.itunesPageURL)
                    TextField("Identyfikator iTunes", text: $model.podcast.itunesID)
                }
                Section("Opis") {
                    TextEditor(text: $model.podcast.description).frame(minHeight: 120).accessibilityLabel("Opis")
                }
            }
            .formStyle(.grouped)
            SaveBar(dirty: model.podcastDirty, busy: model.isBusy, reset: { model.resetPodcast() }) {
                Task { await model.savePodcast() }
            }
        }
    }
}

struct ScheduleTab: View {
    @Bindable var model: ItemEditorModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Automatycznie pobieraj nowe odcinki", isOn: $model.schedule.enabled)
                        .accessibilityIdentifier("schedule.enabled")
                    if model.item.media.metadata.feedUrl?.isEmpty ?? true {
                        Label("Podcast nie ma adresu kanału RSS — serwer nie ma skąd pobierać.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                Section("Kiedy sprawdzać kanał") {
                    Picker("Harmonogram", selection: $model.schedule.preset) {
                        ForEach(ScheduleDraft.Preset.allCases, id: \.self) { Text($0.title) }
                    }
                    .accessibilityIdentifier("schedule.preset")
                    if model.schedule.preset == .weekly {
                        Picker("Dzień", selection: $model.schedule.weekday) {
                            ForEach(0..<7, id: \.self) { Text(ScheduleDraft.weekdays[$0]) }
                        }
                    }
                    if model.schedule.preset == .daily || model.schedule.preset == .weekly {
                        Picker("Godzina", selection: $model.schedule.hour) {
                            ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)) }
                        }
                    }
                    if model.schedule.preset == .custom {
                        TextField("Wyrażenie cron", text: $model.schedule.cron, prompt: Text("0 6 * * *"))
                            .font(.body.monospaced())
                            .accessibilityIdentifier("schedule.cron")
                        Text("Minuta, godzina, dzień miesiąca, miesiąc, dzień tygodnia — czas serwera, czyli tego Maca.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let last = Formats.date(ms: model.item.media.lastEpisodeCheck) {
                        LabeledContent("Ostatnie sprawdzenie", value: last)
                    }
                }
                .disabled(!model.schedule.enabled)
                Section("Limity") {
                    Stepper(value: $model.schedule.maxNew, in: 0...100) {
                        LabeledContent("Najwyżej nowych na raz", value: model.schedule.maxNew == 0 ? "bez limitu" : "\(model.schedule.maxNew)")
                    }
                    .accessibilityIdentifier("schedule.maxNew")
                    Stepper(value: $model.schedule.maxKeep, in: 0...1000) {
                        LabeledContent("Zachowuj najwyżej", value: model.schedule.maxKeep == 0 ? "wszystkie odcinki" : ScheduleDraft.episodes(model.schedule.maxKeep))
                    }
                    .accessibilityIdentifier("schedule.maxKeep")
                    if model.schedule.maxKeep > 0 {
                        Label("Po każdym automatycznym pobraniu serwer usuwa najstarszy odcinek ponad limit — z biblioteki i z dysku (plik audio), razem z postępem słuchania. Na raz znika najwyżej jeden odcinek.",
                              systemImage: "trash")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("schedule.keepWarning")
                    }
                }
                .disabled(!model.schedule.enabled)
            }
            .formStyle(.grouped)
            SaveBar(dirty: model.scheduleDirty, busy: model.isBusy, reset: { model.resetSchedule() }) {
                Task { await model.saveSchedule() }
            }
        }
    }
}

/// Wspólny dół formularza: „Przywróć” i „Zapisz” (⌘S).
struct SaveBar: View {
    let dirty: Bool
    let busy: Bool
    let reset: () -> Void
    let save: () -> Void

    var body: some View {
        HStack {
            if dirty { Text("Niezapisane zmiany").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Przywróć", action: reset).disabled(!dirty || busy)
            Button("Zapisz") {
                NSApp.keyWindow?.makeFirstResponder(nil)
                save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!dirty || busy)
            .accessibilityIdentifier("details.save")
        }
        .padding(.top, 10)
    }
}

/// Stan wyszukiwania dopasowania podcastu (żyje z arkuszem).
@MainActor
@Observable
final class PodcastMatchSearch {
    var term = ""
    var results: [AudiobookshelfClient.PodcastSearchResult] = []
    var hasSearched = false
    var selected: AudiobookshelfClient.PodcastSearchResult?
    var fields: Set<Field> = Set(Field.allCases)

    enum Field: String, CaseIterable {
        case title = "Tytuł", author = "Autor", description = "Opis", genres = "Gatunki", releaseDate = "Data wydania"
        case feedURL = "Adres kanału", itunes = "Strona i id iTunes", explicit = "Dla dorosłych", cover = "Okładka"
    }
}

/// Dopasowanie podcastu do wyniku iTunes (jak `Match.vue` dla podcastów: `PATCH media` + okładka z adresu).
struct PodcastMatchTab: View {
    @Bindable var model: ItemEditorModel
    @AppStorage("podcastSearch.country") private var country = "pl"

    private var search: PodcastMatchSearch { model.podcastMatch }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Szukaj w iTunes", text: Bindable(search).term).onSubmit(runSearch)
                    .accessibilityIdentifier("podcastMatch.term")
                Picker("Sklep", selection: $country) { ForEach(AddPodcastSheet.countries, id: \.0) { Text($0.1).tag($0.0) } }
                    .fixedSize()
                Button("Szukaj", action: runSearch)
                    .disabled(search.term.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy)
            }
            if let selected = search.selected {
                comparison(selected)
            } else if search.results.isEmpty {
                if search.hasSearched { Text("Brak wyników.").foregroundStyle(.secondary) }
                Spacer()
            } else {
                List(search.results, id: \.key) { result in
                    Button { search.selected = result } label: {
                        HStack(spacing: 12) {
                            RemoteThumbnail(url: result.cover.flatMap(URL.init(string:)), size: 48)
                            VStack(alignment: .leading) {
                                Text(result.title ?? "").font(.headline)
                                Text(result.artistName ?? "").foregroundStyle(.secondary)
                                if let feed = result.feedUrl { Text(feed).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .padding(.top, 12)
        .onAppear { if search.term.isEmpty { search.term = model.item.title } }
    }

    private func comparison(_ m: AudiobookshelfClient.PodcastSearchResult) -> some View {
        let current = model.item.media.metadata
        let rows: [(PodcastMatchSearch.Field, String, String)] = [
            (.title, current.title ?? "", m.title ?? ""),
            (.author, current.author ?? "", m.artistName ?? ""),
            (.description, HTMLText.plain(current.description) ?? "", HTMLText.plain(m.description) ?? ""),
            (.genres, (current.genres ?? []).joined(separator: ", "), (m.genres ?? []).joined(separator: ", ")),
            (.releaseDate, current.releaseDate ?? "", m.releaseDate ?? ""),
            (.feedURL, current.feedUrl ?? "", m.feedUrl ?? ""),
            (.itunes, current.itunesPageUrl ?? "", m.pageUrl ?? ""),
            (.explicit, current.explicit == true ? "tak" : "nie", m.explicit == true ? "tak" : "nie"),
        ].filter { !$0.2.isEmpty }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Wróć do wyników", systemImage: "chevron.left") { search.selected = nil }
                Spacer()
            }
            ScrollView {
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("")
                        Text("Teraz").font(.caption).foregroundStyle(.secondary)
                        Text("Z iTunes").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(rows, id: \.0) { field, old, new in
                        GridRow {
                            Toggle(field.rawValue, isOn: binding(field))
                            Text(old.isEmpty ? "—" : old).lineLimit(4).foregroundStyle(.secondary)
                            Text(new).lineLimit(4)
                        }
                    }
                    if m.cover != nil {
                        GridRow {
                            Toggle(PodcastMatchSearch.Field.cover.rawValue, isOn: binding(.cover))
                            AsyncCover(listening: model.listening, itemID: model.item.id, path: model.item.media.coverPath, size: 80).frame(width: 80, height: 80)
                            RemoteThumbnail(url: m.cover.flatMap(URL.init(string:)), size: 80)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Zastosuj zaznaczone") { apply(m) }
                    .buttonStyle(.borderedProminent)
                    .disabled(search.fields.isEmpty || model.isBusy)
                    .accessibilityIdentifier("podcastMatch.apply")
            }
        }
    }

    private func binding(_ field: PodcastMatchSearch.Field) -> Binding<Bool> {
        Binding(get: { search.fields.contains(field) }, set: { if $0 { search.fields.insert(field) } else { search.fields.remove(field) } })
    }

    private func runSearch() {
        let term = search.term.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        let country = country
        Task {
            await model.perform("Szukanie w iTunes…", failure: "Nie udało się wyszukać") {
                search.results = try await model.manager.run { try await $0.searchPodcasts(term: term, country: country, token: $1) }
                search.hasSearched = true
                search.selected = nil
                return nil
            }
        }
    }

    private func apply(_ m: AudiobookshelfClient.PodcastSearchResult) {
        let f = search.fields
        var meta = AudiobookshelfClient.PodcastUpdate.Metadata()
        if f.contains(.title), let v = m.title { meta.title = v }
        if f.contains(.author), let v = m.artistName { meta.author = v }
        if f.contains(.description), let v = m.description, !v.isEmpty { meta.description = v }
        if f.contains(.genres), let v = m.genres, !v.isEmpty { meta.genres = v }
        if f.contains(.releaseDate), let v = m.releaseDate { meta.releaseDate = v }
        if f.contains(.feedURL), let v = m.feedUrl { meta.feedUrl = v }
        if f.contains(.itunes) {
            meta.itunesPageUrl = m.pageUrl
            meta.itunesId = m.id.map(String.init)
            meta.itunesArtistId = m.artistId.map(String.init)
        }
        if f.contains(.explicit) { meta.explicit = m.explicit ?? false }
        var update = AudiobookshelfClient.PodcastUpdate()
        if !meta.isEmpty { update.metadata = meta }
        Task { await model.applyPodcastMatch(update, coverURL: f.contains(.cover) ? m.cover : nil) }
    }
}
