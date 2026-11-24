import AudiobookshelfKit
import SwiftUI

/// Okładka wczytywana leniwie: dopiero gdy komórka jest na ekranie, z pamięci podręcznej
/// z limitem (`CoverCache`). Zniknięcie komórki przerywa wczytywanie.
struct AsyncCover: View {
    let listening: ListeningController
    let itemID: String
    let path: String?
    let size: CGFloat
    var symbol = "book.closed"
    @State private var image: NSImage?
    /// Pozycja, której okładkę widać — komórka użyta ponownie dla innej pozycji nie pokazuje cudzej.
    @State private var shownID: String?

    var body: some View {
        CoverView(image: image, symbol: symbol)
            .task(id: "\(itemID)#\(listening.coverRevision[itemID] ?? 0)|\(path ?? "")") {
                if shownID != itemID {
                    image = nil
                    shownID = itemID
                }
                let loaded = await listening.cover(for: itemID, path: path, size: size)
                // Po zmianie okładki starsze wczytanie może skończyć się później — nie nadpisuje nowszego.
                if !Task.isCancelled { image = loaded }
            }
    }
}

/// Karta pozycji w siatce: kwadratowa okładka z postępem, tytuł, autor.
struct ItemCard: View {
    let browser: LibraryBrowser
    let item: AudiobookshelfClient.LibraryItem?
    var width: CGFloat = ItemCard.width
    /// Numer tomu (strona serii, „Kolejne w serii”).
    var sequence: String?
    /// Siatka z trybem zaznaczania (etap 9h): w tym trybie kliknięcie zaznacza.
    var selectable = false
    @State private var hovering = false
    @Environment(\.openWindow) private var openWindow

    static let width: CGFloat = 150

    private var listening: ListeningController { browser.listening }

    var body: some View {
        // Karta to przycisk (fokus klawiatury, VoiceOver): okładka z tytułem są etykietą,
        // a przyciski „Odtwarzaj”/„Czytaj” po najechaniu leżą nad nim jako osobna nakładka —
        // przycisk wewnątrz etykiety innego przycisku nie działa pewnie.
        Button { if let item { activate(item) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .bottom) {
                    Rectangle().fill(.quaternary.opacity(0.5))
                    if let item {
                        AsyncCover(listening: listening, itemID: item.id, path: item.media.coverPath, size: width, symbol: item.isPodcast ? "mic" : "book.closed")
                            .accessibilityHidden(true)
                        ItemProgressBadge(listening: listening, key: ListeningController.key(item.id, item.recentEpisode?.id))
                    }
                }
                .frame(width: width, height: width)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if let sequence { Text("#\(sequence)").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 2).background(.thinMaterial, in: Capsule()).padding(5) }
                }
                .overlay(alignment: .topTrailing) {
                    if selecting, let item {
                        let selected = browser.isSelected(item.id)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title2).symbolRenderingMode(.palette)
                            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.9)), selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.black.opacity(0.35)))
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                }
                .overlay {
                    if selecting, let item, browser.isSelected(item.id) {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(.tint, lineWidth: 3)
                    }
                }
                Text(item?.recentEpisode?.title ?? item?.title ?? " ")
                    .font(.callout).lineLimit(2, reservesSpace: true)
                Text((item?.recentEpisode != nil ? item?.title : item?.author) ?? " ")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item == nil)
        // Nad okładką (kwadrat u góry karty), poza etykietą przycisku karty. `onHover` niżej
        // obejmuje też tę nakładkę, więc najechanie na przycisk nie chowa go.
        .overlay(alignment: .top) {
            hoverAction.frame(width: width, height: width)
        }
        .onHover { hovering = $0 }
        .contextMenu { if let item, !selecting { ItemMenu(browser: browser, item: item) } }
        .accessibilityAddTraits(selecting && item.map { browser.isSelected($0.id) } == true ? .isSelected : [])
        .accessibilityIdentifier(item.map { "card.\($0.id)" } ?? "card.placeholder")
    }

    @ViewBuilder private var hoverAction: some View {
        if selecting {
            EmptyView()
        } else if hovering, let item, item.isEbookOnly {
            Button { openWindow(id: ReaderWindow.windowID, value: ReaderTarget(itemID: item.id, fileIno: nil, title: item.title)) } label: {
                Image(systemName: "book.circle.fill")
                    .font(.system(size: 40)).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Czytaj")
            .accessibilityLabel("Czytaj")
        } else if hovering, let item, !item.isPodcast || item.recentEpisode != nil {
            let pauses = isCurrent(item) && listening.player.isPlaying
            Button { play(item) } label: {
                Image(systemName: pauses ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40)).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Odtwarzaj")
            .accessibilityLabel(pauses ? "Pauza" : "Odtwarzaj")
        }
    }

    private var selecting: Bool { selectable && browser.isSelecting }

    private func activate(_ item: AudiobookshelfClient.LibraryItem) {
        if selecting {
            browser.toggleSelection(item)
        } else {
            browser.open(.item(item.id))
        }
    }

    private func isCurrent(_ item: AudiobookshelfClient.LibraryItem) -> Bool {
        listening.player.book?.key == ListeningController.key(item.id, item.recentEpisode?.id)
    }

    private func play(_ item: AudiobookshelfClient.LibraryItem) {
        Task { await listening.play(itemID: item.id, episodeID: item.recentEpisode?.id) }
    }
}

/// Postęp jednej pozycji na okładce karty. Tylko ten mały widok czyta słownik postępu
/// (`@Observable` śledzi go w całości), więc synchronizacja postępu nie przebudowuje kart z okładkami.
struct ItemProgressBadge: View {
    let listening: ListeningController
    let key: String

    var body: some View {
        ProgressOverlay(progress: listening.progress[key])
    }
}

/// Pasek postępu na dole okładki albo znacznik „ukończone”.
struct ProgressOverlay: View {
    let progress: AudiobookshelfClient.MediaProgress?

    var body: some View {
        if let progress {
            if progress.isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette).foregroundStyle(.white, .green)
                    .font(.title3).padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .accessibilityLabel("Ukończone")
            } else if let value = progress.progress, value > 0 {
                GeometryReader { proxy in
                    Rectangle().fill(.orange).frame(width: proxy.size.width * min(1, value), height: 4)
                }
                .frame(height: 4)
                .accessibilityLabel("Postęp \(value.formatted(.percent.precision(.fractionLength(0))))")
            }
        }
    }
}
