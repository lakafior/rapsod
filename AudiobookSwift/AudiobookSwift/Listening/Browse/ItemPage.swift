import AppKit
import SwiftUI

/// Strona pozycji (`GET /api/items/:id?expanded=1`): książka albo podcast.
struct ItemPage: View {
    let browser: LibraryBrowser
    let itemID: String
    @State private var item: AudiobookshelfClient.ItemDetail?
    @State private var error: String?

    var body: some View {
        Group {
            if let item {
                if item.isPodcast {
                    PodcastPage(browser: browser, item: item)
                } else {
                    BookPage(browser: browser, item: item)
                }
            } else {
                LoadingState(error: error) { await load() }
            }
        }
        .navigationTitle(item?.title ?? "")
        .task(id: ReloadKey(id: itemID, revision: browser.revision)) { await load() }
    }

    private func load() async {
        do {
            item = try await browser.listening.api { try await $0.item(id: itemID, token: $1) }
            error = nil
        } catch {
            if Task.isCancelled { return }
            self.error = error.localizedDescription
        }
    }
}
