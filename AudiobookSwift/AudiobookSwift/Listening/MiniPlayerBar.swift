// Pochodzenie: widoki odtwarzacza przeniesione z projektu Dove tego samego autora
// (`App/Dove/Features/Library/AudiobookViews.swift`, MPL-2.0) i dostosowane do macOS:
// panel boczny zamiast pełnego ekranu, pasek odtwarzania na dole okna, sterowanie w menu ikony,
// bez muzyki, kolejki i wyboru wyjścia AirPlay.

import AudiobookshelfPlayback
import SwiftUI

/// Pasek na dole okna, gdy coś jest załadowane: okładka, tytuł, rozdział, sterowanie.
struct MiniPlayerBar: View {
    let listening: ListeningController
    @Binding var showsPlayer: Bool
    @State private var cover: NSImage?

    var body: some View {
        let player = listening.player
        if let book = player.book {
            HStack(spacing: 12) {
                CoverView(image: cover, symbol: "headphones")
                    .frame(width: 36, height: 36)
                    .task(id: "\(book.itemID)#\(listening.coverRevision[book.itemID] ?? 0)") {
                        cover = await listening.cover(for: book.itemID, path: book.coverPath, size: 40)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(book.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(player.currentChapter?.title ?? book.author ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if player.lastSkip != nil {
                    SkipBanner(player: player, compact: true).fixedSize()
                }
                TransportControls(player: player)
                Button { showsPlayer.toggle() } label: { Image(systemName: "sidebar.trailing") }
                    .buttonStyle(.borderless)
                    .help(showsPlayer ? "Schowaj odtwarzacz" : "Pokaż odtwarzacz")
                    .accessibilityLabel(showsPlayer ? "Schowaj odtwarzacz" : "Pokaż odtwarzacz")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

/// Sterowanie w menu ikony na pasku menu. Czyta tylko tytuł i stan odtwarzania —
/// nie czas, więc menu nie przebudowuje się w trakcie słuchania.
struct MenuPlayerControls: View {
    let player: AudiobookPlayer

    var body: some View {
        if let book = player.book {
            Text(book.title)
            Button(player.isPlaying ? "Pauza" : "Odtwarzaj") { player.togglePlayPause() }
            Button("Cofnij 15 s") { player.skip(by: -AudiobookPlayer.skipBack) }
            Button("Naprzód 30 s") { player.skip(by: AudiobookPlayer.skipForward) }
            Divider()
        }
    }
}
