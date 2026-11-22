// Pochodzenie: widoki odtwarzacza przeniesione z projektu Dove tego samego autora
// (`App/Dove/Features/Library/AudiobookViews.swift`, MPL-2.0) i dostosowane do macOS:
// panel boczny zamiast pełnego ekranu, pasek odtwarzania na dole okna, sterowanie w menu ikony,
// bez muzyki, kolejki i wyboru wyjścia AirPlay.

import SwiftUI

/// Pełny odtwarzacz w panelu bocznym okna: okładka, rozdział, suwak, przewijanie,
/// prędkość, timer usypiania i lista rozdziałów.
struct PlayerPanel: View {
    let listening: ListeningController
    @State private var cover: NSImage?

    private var player: AudiobookPlayer { listening.player }

    var body: some View {
        if let book = player.book {
            VStack(spacing: 14) {
                CoverView(image: cover, symbol: "headphones")
                    .frame(maxWidth: 220, maxHeight: 220)
                    .shadow(radius: 8, y: 4)
                    // Licznik okładki: po edycji okładki odtwarzacz wczytuje nową, jak `AsyncCover`.
                    .task(id: "\(book.itemID)#\(listening.coverRevision[book.itemID] ?? 0)") {
                        cover = await listening.cover(for: book.itemID, path: listening.nowPlayingCoverPath, size: 300)
                    }

                VStack(spacing: 3) {
                    Text(book.title).font(.headline).multilineTextAlignment(.center).lineLimit(2)
                    if let author = book.author { Text(author).foregroundStyle(.secondary).lineLimit(1) }
                    if book.chapters.count > 1, let chapter = player.currentChapter {
                        Text(chapter.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }

                ChapterScrubber(player: player)

                TransportControls(player: player, large: true)

                if let error = player.error {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                HStack {
                    SpeedMenu(player: player)
                    Spacer()
                    SleepMenu(player: player)
                    Spacer()
                    if book.episodeID == nil {
                        BookmarksMenu(listening: listening, itemID: book.itemID)
                        Spacer()
                    }
                    Menu {
                        Button("Oznacz jako ukończone", systemImage: "checkmark.circle") {
                            Task { await listening.markFinished() }
                        }
                        Button("Zatrzymaj i zamknij", systemImage: "xmark.circle") {
                            Task { await listening.stopPlayback() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Więcej")
                }
                .controlSize(.small)

                if let next = listening.queue.first {
                    HStack {
                        Label("Następne: \(next.title)" + (listening.queue.count > 1 ? " (+\(listening.queue.count - 1))" : ""), systemImage: "text.line.first.and.arrowtriangle.forward")
                            .lineLimit(1)
                        Spacer()
                        Button("Wyczyść kolejkę", systemImage: "xmark.circle.fill") { listening.clearQueue() }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                ChapterList(player: player)
            }
            .padding()
        } else {
            ContentUnavailableView("Nic nie gra", systemImage: "headphones", description: Text("Wybierz książkę z listy."))
        }
    }
}

/// Zakładki bieżącej książki: dodanie w bieżącym miejscu i przejście do zapisanych.
struct BookmarksMenu: View {
    let listening: ListeningController
    let itemID: String

    var body: some View {
        let bookmarks = listening.bookmarks[itemID] ?? []
        Menu {
            Button("Dodaj zakładkę", systemImage: "bookmark") { Task { await listening.addBookmarkAtCurrentPosition() } }
            if !bookmarks.isEmpty {
                Divider()
                ForEach(bookmarks) { bookmark in
                    Button("\(ChapterScrubber.time(bookmark.time))  \(bookmark.title)") { listening.player.seek(to: bookmark.time) }
                }
            }
        } label: {
            Label(bookmarks.isEmpty ? "Zakładki" : "Zakładki (\(bookmarks.count))", systemImage: bookmarks.isEmpty ? "bookmark" : "bookmark.fill")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(bookmarks.isEmpty ? "Zakładki" : "Zakładki: \(bookmarks.count)")
        .accessibilityIdentifier("player.bookmarks")
    }
}
