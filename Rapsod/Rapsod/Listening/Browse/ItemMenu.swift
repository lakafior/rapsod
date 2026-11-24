import AudiobookshelfKit
import SwiftUI

/// Menu podręczne pozycji (siatki, półki, wyniki wyszukiwania).
struct ItemMenu: View {
    let browser: LibraryBrowser
    let item: AudiobookshelfClient.LibraryItem
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let listening = browser.listening
        let episodeID = item.recentEpisode?.id
        let progress = listening.progress[ListeningController.key(item.id, episodeID)]
        Button("Otwórz") { browser.open(.item(item.id)) }
        if item.media.ebookFormat != nil, !item.isPodcast {
            Button("Czytaj") { openWindow(id: ReaderWindow.windowID, value: ReaderTarget(itemID: item.id, fileIno: nil, title: item.title)) }
        }
        if !item.isPodcast || episodeID != nil {
            if !item.isEbookOnly {
                Button((progress?.currentTime ?? 0) > 0 && progress?.isFinished != true ? "Kontynuuj" : "Odtwarzaj") {
                    Task { await listening.play(itemID: item.id, episodeID: episodeID) }
                }
            }
            Divider()
            if progress?.isFinished == true {
                Button("Oznacz jako nieukończone") { Task { await listening.setFinished(itemID: item.id, episodeID: episodeID, false) } }
            } else {
                Button("Oznacz jako ukończone") { Task { await listening.setFinished(itemID: item.id, episodeID: episodeID, true) } }
            }
            if progress != nil, progress?.hideFromContinueListening != true {
                Button("Usuń ze „Słuchaj dalej”") { Task { await listening.removeFromContinueListening(itemID: item.id, episodeID: episodeID) } }
            }
            AddToPlaylistMenu(browser: browser, entry: .init(libraryItemId: item.id, episodeId: episodeID), libraryID: item.libraryId)
        }
    }
}
