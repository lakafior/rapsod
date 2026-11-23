// Pochodzenie: kod własny projektu (etap 11b, ruch przebudowany w 11d). Ten sam układ co tryb
// „Tekst” klienta iOS (`iOS/AudiobookSwiftiOS/BookTextView.swift`); logika (mapa, bieżące
// zdanie, śledzenie) jest w pakiecie (`TextFollowModel`), skład i ruch też (`TextFlowController`),
// a tu tylko stany, przycisk powrotu, ustawienia i okno.

import AudiobookshelfKit
import AudiobookshelfPlayback
import SwiftUI

enum BookTextSettings {
    /// Tryb tekstu w panelu odtwarzacza (zamiast okładki i listy rozdziałów).
    static let panelKey = "player.showsText"
    static let serifKey = "bookText.serif"
    static let scaleKey = "bookText.scale"
    static let scales: [Double] = [0.8, 0.9, 1, 1.12, 1.25, 1.4, 1.6]

    static func step(_ scale: Double, by direction: Int) -> Double {
        let current = scales.firstIndex { $0 >= scale - 0.001 } ?? 2
        return scales[min(max(0, current + direction), scales.count - 1)]
    }
}

extension ListeningController {
    /// Wczytuje mapę tekstu bieżącej książki do `text` (pamięć podręczna na dysku, jak na telefonie).
    func loadTextForCurrentBook() {
        guard let book = player.book, book.episodeID == nil else { text.reset(); return }
        let itemID = book.itemID
        let revision = textSync.mapRevision[itemID] ?? 0
        text.load(key: "\(itemID)#\(revision)", source: TextSyncSource(
            itemID: itemID,
            fetchItem: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.api { try await $0.item(id: itemID, token: $1) }
            },
            fetchFile: { [weak self] ino in
                guard let self else { throw CancellationError() }
                return try await self.api { try await $0.libraryFile(itemID: itemID, ino: ino, token: $1) }
            }
        ), cache: .standard())
    }
}

/// Tekst książki ze stanami (wczytywanie, brak mapy, błąd) — w panelu i w osobnym oknie.
struct BookTextView: View {
    let listening: ListeningController
    /// Podstawowy rozmiar tekstu (panel mniejszy, okno większe).
    var baseSize: CGFloat = 15
    var columnWidth: CGFloat = 560

    private var model: TextFollowModel { listening.text }

    var body: some View {
        Group {
            switch model.phase {
            case .idle, .loading:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Wczytywanie tekstu…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable(let reason):
                ContentUnavailableView {
                    Label("Brak tekstu", systemImage: "text.page.slash")
                } description: {
                    Text(reason == .notSynced || reason == .noEbook
                         ? reason.message.replacingOccurrences(of: "Na Macu otwórz", with: "Otwórz")
                            .replacingOccurrences(of: "Na Macu dodaj", with: "Dodaj")
                         : reason.message)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Nie udało się wczytać tekstu", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Spróbuj ponownie") { model.reload() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                if let document = model.document {
                    BookTextScroll(model: model, document: document, player: listening.player, baseSize: baseSize, columnWidth: columnWidth)
                }
            }
        }
        .background { TextTimeFeed(model: model, player: listening.player) }
        .task(id: "\(listening.player.book?.key ?? "-")#\(listening.player.book.map { listening.textSync.mapRevision[$0.itemID] ?? 0 } ?? 0)") {
            listening.loadTextForCurrentBook()
        }
    }
}

private struct BookTextScroll: View {
    let model: TextFollowModel
    let document: TextSyncDocument
    let player: AudiobookPlayer
    let baseSize: CGFloat
    let columnWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(BookTextSettings.serifKey) private var serif = true
    @AppStorage(BookTextSettings.scaleKey) private var scale = 1.0

    var body: some View {
        let dimmed = contrast == .increased ? 0.6 : (colorScheme == .dark ? 0.4 : 0.34)
        BookTextCanvas(
            model: model, document: document,
            sentence: model.currentSentence, following: model.isFollowing,
            jump: model.jumpRequest, back: model.returnRequest,
            size: baseSize * scale, serif: serif, dimmed: dimmed, glow: colorScheme == .dark,
            columnWidth: columnWidth, reduceMotion: reduceMotion,
            onTap: play(sentence:)
        )
        .overlay(alignment: .bottom) {
            if !model.isFollowing {
                Button {
                    model.resumeFollowing()
                } label: {
                    Label("Wróć do bieżącego miejsca", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Wróć do bieżącego miejsca (⌘↩)")
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) { notices }
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: model.isFollowing)
    }

    @ViewBuilder
    private var notices: some View {
        if model.isStale || model.isOffline {
            VStack(alignment: .leading, spacing: 4) {
                if model.isStale {
                    Label("Nagranie albo e-book zmieniły się od synchronizacji — tekst może nie trafiać w audio. Zsynchronizuj e-book ponownie na stronie książki.", systemImage: "exclamationmark.triangle.fill")
                }
                if model.isOffline {
                    Label("Tekst z pamięci (bez połączenia z serwerem)", systemImage: "wifi.slash")
                }
            }
            .font(.callout)
            .padding(10)
            .glassEffect(in: .rect(cornerRadius: 12))
            .padding(10)
        }
    }

    private func play(sentence: Int) {
        guard let time = model.time(forSentence: sentence) else { return }
        player.seek(to: time)
        if !player.isPlaying { player.togglePlayPause() }
    }
}

/// Podaje modelowi czas z odtwarzacza — tylko ten pusty widok obserwuje zegar.
private struct TextTimeFeed: View {
    let model: TextFollowModel
    let player: AudiobookPlayer

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: player.currentTime, initial: true) { feed() }
            .onChange(of: player.isPlaying) { feed() }
            .onChange(of: player.rate) { feed() }
            .accessibilityHidden(true)
    }

    private func feed() {
        model.update(time: player.currentTime, rate: player.rate, isPlaying: player.isPlaying)
    }
}

/// Krój i rozmiar tekstu (menu w panelu i w oknie).
struct BookTextAppearanceMenu: View {
    @AppStorage(BookTextSettings.serifKey) private var serif = true
    @AppStorage(BookTextSettings.scaleKey) private var scale = 1.0

    var body: some View {
        Menu {
            Picker("Krój", selection: $serif) {
                Text("Szeryfowy").tag(true)
                Text("Bezszeryfowy").tag(false)
            }
            .pickerStyle(.inline)
            Divider()
            Button("Większy tekst") { scale = BookTextSettings.step(scale, by: 1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(scale >= BookTextSettings.scales.last!)
            Button("Mniejszy tekst") { scale = BookTextSettings.step(scale, by: -1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(scale <= BookTextSettings.scales.first!)
            Button("Domyślny rozmiar") { scale = 1 }
                .keyboardShortcut("0", modifiers: .command)
        } label: {
            Label("Wygląd tekstu", systemImage: "textformat.size")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Wygląd tekstu")
    }
}

/// Osobne, większe okno do czytania tekstu przy słuchaniu (⌃⇧⌘T).
struct BookTextWindow: View {
    static let windowID = "book-text"
    let listening: ListeningController
    @State private var cover: NSImage?

    private var player: AudiobookPlayer { listening.player }

    var body: some View {
        VStack(spacing: 0) {
            if player.book != nil {
                BookTextView(listening: listening, baseSize: 20, columnWidth: 680)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 16) {
                    TransportControls(player: player)
                    ChapterScrubber(player: player)
                    SpeedMenu(player: player)
                    BookTextAppearanceMenu()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            } else {
                ContentUnavailableView("Nic nie gra", systemImage: "text.book.closed", description: Text("Włącz książkę, żeby czytać jej tekst przy słuchaniu."))
            }
        }
        .navigationTitle(player.book?.title ?? "Tekst książki")
        .navigationSubtitle(player.currentChapter?.title ?? "")
        .frame(minWidth: 420, minHeight: 360)
    }
}
