// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AudiobookshelfKit
import AudiobookshelfPlayback

/// Strona pozycji: okładka, tytuł, autorzy, seria i lektorzy jako odnośniki, czas, postęp
/// z „Oznacz jako ukończone” i „Usuń postęp”, opis, rozdziały (dotknięcie zaczyna od rozdziału)
/// i odtwarzanie. Podcast — strona podcastu (`PodcastPage`, etap 10e). Bez edycji metadanych.
struct ItemDetailView: View {
    let itemID: String
    let model: AppModel
    let session: ServerSession

    @State private var item: AudiobookshelfClient.ItemDetail?
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var confirmsRemoval = false
    @State private var isWorking = false
    @Environment(\.displayScale) private var displayScale
    @State private var cover: UIImage?
    @ScaledMetric(relativeTo: .title) private var coverSize: CGFloat = 220

    private var playback: PlaybackCoordinator { model.playback }

    var body: some View {
        if let item, item.isPodcast {
            PodcastPage(item: item, model: model, session: session)
        } else {
            bookPage
        }
    }

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    private var bookPage: some View {
        Group {
            if let item {
                if sizeClass == .regular {
                    // iPad: okładka i główne akcje w lewej kolumnie, reszta przewija się obok.
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView {
                            heroContent(item).padding(24)
                        }
                        .frame(width: 380)
                        .background { ArtworkBackdrop(image: cover, base: Color(.systemGroupedBackground)).ignoresSafeArea() }
                        List { detailSections(item) }
                    }
                } else {
                    List {
                        Section {
                            heroContent(item)
                                .frame(maxWidth: .infinity)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }
                        detailSections(item)
                    }
                    .scrollContentBackground(.hidden)
                    .background(alignment: .top) {
                        ArtworkBackdrop(image: cover, base: Color(.systemGroupedBackground))
                            .frame(height: 560)
                            .ignoresSafeArea(edges: .top)
                    }
                    .background(Color(.systemGroupedBackground))
                }
            } else if let loadError {
                LoadFailureView(message: loadError) { Task { await load() } }
            } else {
                ProgressView()
            }
        }
        .task(id: item?.id) {
            guard let id = item?.id else { return }
            cover = await session.cover(itemID: id, path: nil, size: 360, scale: displayScale)
        }
        .navigationTitle(item?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let item, !item.isPodcast {
                ToolbarItem(placement: .topBarTrailing) { progressMenu(item) }
            }
        }
        .task(id: session.id) { await load() }
        .refreshable {
            await session.library.refreshProgress()
            await load()
        }
        .alert("Nie udało się", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .confirmationDialog("Usunąć postęp tej książki?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Usuń postęp", role: .destructive) { Task { await removeProgress() } }
        } message: {
            Text("Miejsce słuchania zniknie na wszystkich urządzeniach.")
        }
    }

    @ViewBuilder
    private func detailSections(_ item: AudiobookshelfClient.ItemDetail) -> some View {
        details(item)
        if let text = HTMLText.plain(item.media.metadata.description), !text.isEmpty {
            Section("Opis") {
                ExpandableText(text: text, lineLimit: 5)
            }
        }
        if let chapters = item.media.chapters, chapters.count > 1 {
            chapterList(item, chapters)
        }
    }

    /// Okładka, tytuł, autor, postęp i główne akcje (odtwarzanie, pobranie).
    private func heroContent(_ item: AudiobookshelfClient.ItemDetail) -> some View {
        VStack(spacing: 14) {
            CoverImage(image: cover, isPodcast: item.isPodcast)
                .frame(width: min(coverSize, 300))
                .accessibilityHidden(true)
                .padding(.top, 8)
            VStack(spacing: 4) {
                Text(item.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle = item.media.metadata.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if let authors = item.media.metadata.authors, !authors.isEmpty {
                    Text(authors.map(\.name).joined(separator: ", "))
                        .font(.body)
                        .foregroundStyle(.tint)
                        .multilineTextAlignment(.center)
                }
            }
            BookProgress(entry: session.library.progress.entry(item.id), duration: item.media.duration)
            if typeSize.isAccessibilitySize {
                // Największy tekst: przyciski pod sobą, pobieranie z podpisem.
                VStack(spacing: 12) {
                    PlayButton(model: model, itemID: item.id, episodeID: nil, progress: session.library.progress.entry(item.id).value)
                    DownloadButton(target: .book(itemID: item.id), session: session)
                }
            } else {
                HStack(spacing: 12) {
                    PlayButton(model: model, itemID: item.id, episodeID: nil, progress: session.library.progress.entry(item.id).value)
                    DownloadButton(target: .book(itemID: item.id), session: session, compact: true)
                }
                .frame(maxWidth: 360)
            }
            PlayErrorText(model: model, key: item.id)
        }
    }

    @ViewBuilder
    private func details(_ item: AudiobookshelfClient.ItemDetail) -> some View {
        let metadata = item.media.metadata
        Section {
            ForEach(metadata.authors ?? []) { author in
                NavigationLink(value: Route.authorSeed(libraryID: item.libraryId, id: author.id, name: author.name)) {
                    LabeledContent("Autor", value: author.name)
                }
            }
            ForEach(metadata.series?.values ?? []) { series in
                NavigationLink(value: Route.seriesSeed(libraryID: item.libraryId, id: series.id, name: series.name)) {
                    LabeledContent("Seria", value: series.sequence.map { "\(series.name) · tom \($0)" } ?? series.name)
                }
            }
            ForEach(metadata.narrators ?? [], id: \.self) { narrator in
                NavigationLink(value: Route.narrator(narrator)) {
                    LabeledContent("Lektor", value: narrator)
                }
            }
            if let duration = item.media.duration, duration > 0 {
                LabeledContent("Czas", value: TimeText.long(duration))
            }
            if let year = metadata.publishedYear, !year.isEmpty {
                LabeledContent("Rok wydania", value: year)
            }
            if let combined = session.library.combined, combined.hasSeveralLibraries, let library = combined.libraryName(item.libraryId) {
                LabeledContent("Biblioteka", value: library)
            }
        }
    }

    private func chapterList(_ item: AudiobookshelfClient.ItemDetail, _ chapters: [AudiobookshelfClient.ItemDetail.Media.Chapter]) -> some View {
        Section("Rozdziały (\(chapters.count))") {
            ForEach(chapters) { chapter in
                Button {
                    Task { await play(item, from: chapter) }
                } label: {
                    ChapterRow(chapter: chapter, itemID: item.id, player: playback.player)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Zaczyna odtwarzanie od tego rozdziału"))
            }
        }
    }

    private func progressMenu(_ item: AudiobookshelfClient.ItemDetail) -> some View {
        let progress = session.library.progress.entry(item.id).value
        return Menu {
            if progress?.isFinished == true {
                Button("Oznacz jako nieukończone", systemImage: "arrow.uturn.backward") { Task { await setFinished(item, false) } }
            } else {
                Button("Oznacz jako ukończone", systemImage: "checkmark.circle") { Task { await setFinished(item, true) } }
            }
            if progress != nil {
                Button("Usuń postęp", systemImage: "trash", role: .destructive) { confirmsRemoval = true }
                    .disabled(playback.isLoaded(itemID: item.id))
            }
        } label: {
            Label("Postęp", systemImage: isWorking ? "hourglass" : "ellipsis.circle")
        }
        .disabled(isWorking)
    }

    // MARK: Działania

    /// Od początku rozdziału: bieżąca książka — przeskok; inna — start i przeskok po wczytaniu.
    private func play(_ item: AudiobookshelfClient.ItemDetail, from chapter: AudiobookshelfClient.ItemDetail.Media.Chapter) async {
        await playback.play(itemID: item.id, from: chapter.start)
    }

    private func setFinished(_ item: AudiobookshelfClient.ItemDetail, _ finished: Bool) async {
        isWorking = true
        defer { isWorking = false }
        do {
            if finished, playback.isLoaded(itemID: item.id) {
                await playback.markFinished()
            } else {
                try await session.auth.perform { try await $0.setFinished(itemID: item.id, episodeID: nil, finished: finished, token: $1) }
            }
            await session.library.refreshProgress()
        } catch {
            actionError = LibraryStore.message(error)
        }
    }

    private func removeProgress() async {
        guard let id = session.library.progress.value(itemID)?.id else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await session.auth.perform { try await $0.deleteProgress(id: id, token: $1) }
            session.library.progress.remove(itemID)
            await session.library.refreshProgress()
        } catch {
            actionError = LibraryStore.message(error)
        }
    }

    private func load() async {
        do {
            item = try await session.auth.perform { try await $0.item(id: itemID, token: $1) }
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            if item == nil { loadError = LibraryStore.message(error) }
            if AddressSelection.isConnectionError(error) { model.connectionTroubled() }
        }
    }
}

/// Postęp książki pod okładką — obserwuje tylko swój wpis.
private struct BookProgress: View {
    let entry: ProgressStore.Entry
    let duration: Double?

    var body: some View {
        ProgressSummary(progress: entry.value, duration: duration)
    }
}

/// Rozdział z czasem; bieżący rozdział odtwarzanej książki wyróżniony.
private struct ChapterRow: View {
    let chapter: AudiobookshelfClient.ItemDetail.Media.Chapter
    let itemID: String
    let player: AudiobookPlayer

    var body: some View {
        let isCurrent = player.book?.itemID == itemID && player.currentChapterID == chapter.id
        HStack {
            Image(systemName: isCurrent ? "speaker.wave.2.fill" : "play.circle")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(chapter.title)
                .foregroundStyle(.primary)
                .fontWeight(isCurrent ? .semibold : .regular)
            Spacer()
            Text(TimeText.clock(chapter.start))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(chapter.title), od \(TimeText.long(chapter.start))\(isCurrent ? ", teraz odtwarzany" : "")"))
    }
}

/// „Odtwarzaj” albo „Kontynuuj”; dla bieżącej książki — pauza i wznowienie.
struct PlayButton: View {
    let model: AppModel
    let itemID: String
    let episodeID: String?
    let progress: AudiobookshelfClient.MediaProgress?

    var body: some View {
        let playback = model.playback
        let key = PlaybackTimeline.key(itemID, episodeID)
        let isCurrent = playback.nowPlayingKey == key
        let isStarting = playback.startingKey == key
        Button {
            Task { await playback.play(itemID: itemID, episodeID: episodeID) }
        } label: {
            HStack {
                if isStarting {
                    ProgressView()
                } else {
                    Image(systemName: isCurrent && playback.player.isPlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(title(isCurrent: isCurrent))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(isStarting)
    }

    private func title(isCurrent: Bool) -> String {
        if isCurrent { return model.playback.player.isPlaying ? "Pauza" : "Wznów" }
        guard let progress, !progress.isFinished, (progress.currentTime ?? 0) > 0 else {
            return progress?.isFinished == true ? "Słuchaj od nowa" : "Odtwarzaj"
        }
        return "Kontynuuj"
    }
}

/// Błąd startu odtwarzania pod przyciskami (gdy dotyczy innej pozycji niż bieżąca).
struct PlayErrorText: View {
    let model: AppModel
    let key: String

    var body: some View {
        if let error = model.playback.loadError, model.playback.nowPlayingKey != key {
            Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
        }
    }
}

private struct ProgressSummary: View {
    let progress: AudiobookshelfClient.MediaProgress?
    let duration: Double?
    var compact = false

    var body: some View {
        if let progress, progress.isFinished {
            Label("Ukończone", systemImage: "checkmark.circle.fill")
                .font(.footnote).foregroundStyle(.secondary)
        } else if let progress, let time = progress.currentTime, time > 0, let total = duration ?? progress.duration, total > 0 {
            VStack(spacing: 4) {
                if !compact {
                    ProgressView(value: min(1, time / total))
                        .frame(maxWidth: 240)
                }
                Text("Zostało \(TimeText.long(total - time))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Przesłuchane \(Int(min(1, time / total) * 100)) procent, zostało \(TimeText.long(total - time))"))
        } else if let duration, !compact {
            Text(TimeText.long(duration)).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Czas do pokazania: „1:02:03” albo „12:05”, oraz opisowo „1 godz. 2 min”.
enum TimeText {
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func long(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        let duration = Duration.seconds(value)
        // Krótsze niż minuta: sekundy zamiast „0 min”.
        let units: Set<Duration.UnitsFormatStyle.Unit> = value < 60 ? [.seconds] : [.hours, .minutes]
        return duration.formatted(.units(allowed: units, width: .abbreviated, maximumUnitCount: 2))
    }
}
