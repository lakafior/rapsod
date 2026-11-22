// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AudiobookshelfKit
import AudiobookshelfPlayback

/// Prosta strona pozycji: okładka, tytuł, autor, postęp, „Odtwarzaj”/„Kontynuuj” i opis.
/// Podcast — lista odcinków z serwera. Pełne przeglądanie to następny etap.
struct ItemDetailView: View {
    let itemID: String
    let model: AppModel
    let session: ServerSession

    @State private var item: AudiobookshelfClient.ItemDetail?
    @State private var progress: [String: AudiobookshelfClient.MediaProgress] = [:]
    @State private var loadError: String?
    @Environment(\.displayScale) private var displayScale
    @State private var cover: UIImage?

    private var playback: PlaybackCoordinator { model.playback }

    var body: some View {
        List {
            if let item {
                header(item)
                if item.isPodcast {
                    episodes(item)
                } else if let text = HTMLText.plain(item.media.metadata.description), !text.isEmpty {
                    Section("Opis") {
                        Text(text).font(.callout)
                    }
                }
            } else if let loadError {
                Text(loadError).foregroundStyle(.red)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(item?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.id) { await load() }
        .task(id: playback.progressRevision) { await loadProgress() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func header(_ item: AudiobookshelfClient.ItemDetail) -> some View {
        Section {
            VStack(spacing: 12) {
                CoverImage(image: cover, isPodcast: item.isPodcast)
                    .frame(width: 220, height: 220)
                    .accessibilityHidden(true)
                    .task(id: item.id) {
                        cover = await session.cover(itemID: item.id, path: nil, size: 220, scale: displayScale)
                    }
                Text(item.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                if let author = authorLine(item) {
                    Text(author).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if !item.isPodcast {
                    ProgressSummary(progress: progress[item.id], duration: item.media.duration)
                    PlayButton(model: model, itemID: item.id, episodeID: nil, progress: progress[item.id])
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func episodes(_ item: AudiobookshelfClient.ItemDetail) -> some View {
        let list = (item.media.episodes?.elements ?? []).sorted { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) }
        Section("Odcinki") {
            if list.isEmpty {
                Text("Na serwerze nie ma pobranych odcinków.").foregroundStyle(.secondary)
            }
            ForEach(list) { episode in
                let key = PlaybackTimeline.key(item.id, episode.id)
                Button {
                    Task { await playback.play(itemID: item.id, episodeID: episode.id) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(episode.title ?? "Odcinek").foregroundStyle(.primary)
                            if let published = episode.published {
                                Text(published, format: .dateTime.day().month().year())
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            ProgressSummary(progress: progress[key], duration: episode.length, compact: true)
                        }
                        Spacer()
                        Image(systemName: playback.nowPlayingKey == key && playback.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title)
                            .foregroundStyle(.tint)
                    }
                }
                .accessibilityLabel(Text("Odtwarzaj \(episode.title ?? "odcinek")"))
            }
        }
    }

    private func authorLine(_ item: AudiobookshelfClient.ItemDetail) -> String? {
        let names = item.media.metadata.authors?.map(\.name) ?? []
        if !names.isEmpty { return names.joined(separator: ", ") }
        return item.media.metadata.author
    }

    private func load() async {
        do {
            item = try await session.auth.perform { try await $0.item(id: itemID, token: $1) }
            loadError = nil
        } catch {
            if item == nil { loadError = error.localizedDescription }
            if AddressSelection.isConnectionError(error) { model.connectionTroubled() }
        }
        await loadProgress()
    }

    /// Postęp z serwera (ten sam, który widzi Mac).
    private func loadProgress() async {
        let state: AudiobookshelfClient.MeState? = try? await session.auth.perform { try await $0.me(token: $1) }
        guard let me = state else { return }
        var entries: [String: AudiobookshelfClient.MediaProgress] = [:]
        for entry in me.mediaProgress.elements where entry.libraryItemId == itemID {
            entries[PlaybackTimeline.key(itemID, entry.episodeId)] = entry
        }
        progress = entries
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
                }
                Text(title(isCurrent: isCurrent))
            }
            .font(.headline)
            .frame(maxWidth: 280)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isStarting)
        if let error = playback.loadError, !isCurrent {
            Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
        }
    }

    private func title(isCurrent: Bool) -> String {
        if isCurrent { return model.playback.player.isPlaying ? "Pauza" : "Wznów" }
        guard let progress, !progress.isFinished, (progress.currentTime ?? 0) > 0 else {
            return progress?.isFinished == true ? "Słuchaj od nowa" : "Odtwarzaj"
        }
        return "Kontynuuj"
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

struct CoverImage: View {
    let image: UIImage?
    var isPodcast = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: isPodcast ? "dot.radiowaves.left.and.right" : "book.closed")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .clipShape(.rect(cornerRadius: 8))
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
        let duration = Duration.seconds(max(0, seconds.isFinite ? seconds : 0))
        return duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }
}
