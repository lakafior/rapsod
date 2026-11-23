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
    /// Tryb „Tekst” (etap 11b): tekst książki zamiast dużej okładki i listy rozdziałów.
    @AppStorage(BookTextSettings.panelKey) private var showsText = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var player: AudiobookPlayer { listening.player }

    var body: some View {
        if let book = player.book {
            let textMode = showsText && book.episodeID == nil
            VStack(spacing: 14) {
                if textMode {
                    HStack(spacing: 10) {
                        CoverView(image: cover, symbol: "headphones")
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title).font(.headline).lineLimit(1)
                            Text((book.chapters.count > 1 ? player.currentChapter?.title : nil) ?? book.author ?? "")
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    BookTextView(listening: listening)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                                     .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    CoverView(image: cover, symbol: "headphones")
                        .frame(maxWidth: 220, maxHeight: 220)
                        .shadow(radius: 8, y: 4)
                        .transition(.opacity)

                    VStack(spacing: 3) {
                        Text(book.title).font(.headline).multilineTextAlignment(.center).lineLimit(2)
                        if let author = book.author { Text(author).foregroundStyle(.secondary).lineLimit(1) }
                        if book.chapters.count > 1, let chapter = player.currentChapter {
                            Text(chapter.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
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
                        Toggle(isOn: Binding(get: { showsText }, set: { value in
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { showsText = value }
                        })) {
                            Label("Tekst książki", systemImage: "quote.bubble")
                                .labelStyle(.iconOnly)
                        }
                        .toggleStyle(.button)
                        .help(showsText ? "Pokaż okładkę (⌃⌘T)" : "Pokaż tekst książki (⌃⌘T)")
                        .accessibilityIdentifier("player.text")
                        if textMode {
                            BookTextAppearanceMenu()
                            Button("Tekst w osobnym oknie", systemImage: "macwindow") { openWindow(id: BookTextWindow.windowID) }
                                .labelStyle(.iconOnly)
                                .help("Tekst w osobnym oknie (⌃⇧⌘T)")
                        }
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

                if !textMode {
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
            }
            .padding()
            // Licznik okładki: po edycji okładki odtwarzacz wczytuje nową, jak `AsyncCover`.
            .task(id: "\(book.itemID)#\(listening.coverRevision[book.itemID] ?? 0)") {
                cover = await listening.cover(for: book.itemID, path: listening.nowPlayingCoverPath, size: 300)
            }
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
