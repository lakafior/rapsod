import AppKit
import AudiobookshelfKit
import SwiftUI

/// Wiersz odcinka (strona podcastu, „Najnowsze odcinki”).
struct EpisodeRow: View {
    let browser: LibraryBrowser
    let itemID: String
    let libraryID: String
    let episode: AudiobookshelfClient.PodcastEpisode
    var podcastTitle: String?
    let showDetails: () -> Void
    @State private var editing = false
    @State private var removing = false

    var body: some View {
        let listening = browser.listening
        let key = ListeningController.key(itemID, episode.id)
        let progress = listening.progress[key]
        let isCurrent = listening.player.book?.key == key
        HStack(alignment: .top, spacing: 12) {
            Button {
                Task { await listening.play(itemID: itemID, episodeID: episode.id) }
            } label: {
                Image(systemName: isCurrent && listening.player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title)
            }
            .buttonStyle(.borderless)
            .help("Odtwarzaj")
            .accessibilityLabel(isCurrent && listening.player.isPlaying ? "Pauza" : "Odtwarzaj")
            VStack(alignment: .leading, spacing: 3) {
                if let podcastTitle { Text(podcastTitle).font(.caption).foregroundStyle(.secondary) }
                Text(episode.title ?? "Odcinek").font(.headline).lineLimit(2)
                if let text = HTMLText.plain(episode.subtitle ?? episode.description) {
                    Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 10) {
                    if let date = episode.published { Text(Formats.day(date)) }
                    if let season = episode.season, !season.isEmpty { Text("Sezon \(season)") }
                    if let number = episode.episode, !number.isEmpty { Text("Odcinek \(number)") }
                    if progress?.isFinished == true {
                        Label("Ukończony", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if let progress, let current = progress.currentTime, current > 0 {
                        Text("Zostało \(Formats.duration((progress.duration ?? episode.length ?? 0) - current))").foregroundStyle(.orange)
                    } else {
                        Text(Formats.duration(episode.length))
                    }
                    EpisodeSkipBadge(skip: listening.skip, itemID: itemID, episode: episode)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await listening.play(itemID: itemID, episodeID: episode.id) } }
        .contextMenu {
            Button("Odtwarzaj") { Task { await listening.play(itemID: itemID, episodeID: episode.id) } }
            Button("Opis odcinka…", action: showDetails)
            Divider()
            if progress?.isFinished == true {
                Button("Oznacz jako nieukończony") { Task { await listening.setFinished(itemID: itemID, episodeID: episode.id, false) } }
            } else {
                Button("Oznacz jako ukończony") { Task { await listening.setFinished(itemID: itemID, episodeID: episode.id, true) } }
            }
            if progress != nil {
                Button("Wyzeruj postęp") { Task { await listening.resetProgress(itemID: itemID, episodeID: episode.id) } }
            }
            Button("Wykryj segmenty sponsorowane") { listening.skip.analyze(itemID: itemID, episodeID: episode.id) }
                .disabled(SkipController.audioURL(episode) == nil)
            if listening.skip.isModelQueued(itemID: itemID, episodeID: episode.id) {
                Button("Przerwij analizę modelem") { listening.skip.cancelModel(itemID: itemID, episodeID: episode.id) }
            }
            AddToPlaylistMenu(browser: browser, entry: .init(libraryItemId: itemID, episodeId: episode.id), libraryID: libraryID)
            EpisodeManageMenu(browser: browser, episode: episode, editing: $editing, removing: $removing)
        }
        .episodeManagement(browser: browser, itemID: itemID, episode: episode, editing: $editing, removing: $removing)
        .accessibilityIdentifier("episode.\(episode.id)")
    }
}
