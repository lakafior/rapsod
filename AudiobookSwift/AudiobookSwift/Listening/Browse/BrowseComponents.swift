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

/// Opis z HTML (opisy książek i odcinków) jako tekst, bez WebKit: akapity i nowe linie
/// zostają, znaczniki znikają, encje są dekodowane. `NSAttributedString(html:)` uruchamiałby WebKit.
enum HTMLText {
    /// Wyniki dla ostatnich opisów: `plain` jest wołane z `body` wierszy list, a to kilkanaście
    /// wyrażeń regularnych na opis. `NSCache` jest bezpieczny między wątkami.
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 600
        return cache
    }()

    static func plain(_ html: String?) -> String? {
        guard let html, !html.isEmpty else { return nil }
        if let cached = cache.object(forKey: html as NSString) { return cached.length == 0 ? nil : cached as String }
        let result = convert(html)
        cache.setObject((result ?? "") as NSString, forKey: html as NSString)
        return result
    }

    private static func convert(_ html: String) -> String? {
        var text = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let breaks: [(String, String)] = [
            ("(?i)<br\\s*/?>", "\n"), ("(?i)</p\\s*>", "\n\n"), ("(?i)</(div|h[1-6]|ul|ol)\\s*>", "\n"), ("(?i)<li[^>]*>", "• "), ("(?i)</li\\s*>", "\n"),
        ]
        for (pattern, replacement) in breaks {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&hellip;": "…", "&ndash;": "–", "&mdash;": "—"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        text = decodeNumeric(text)
        text = text.replacingOccurrences(of: "[ \\t]+\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func decodeNumeric(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: "&#\\d+;", options: .regularExpression) {
            result += rest[..<range.lowerBound]
            let digits = rest[range].dropFirst(2).dropLast()
            if let code = UInt32(digits), let scalar = Unicode.Scalar(code) { result.unicodeScalars.append(scalar) }
            rest = rest[range.upperBound...]
        }
        return result + rest
    }
}

/// Długi tekst zwinięty do kilku linii z „Więcej”/„Mniej”.
struct ExpandableText: View {
    let text: String
    var lines = 6
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .lineLimit(expanded ? nil : lines)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if text.count > lines * 90 || text.filter({ $0 == "\n" }).count >= lines {
                Button(expanded ? "Mniej" : "Więcej") { expanded.toggle() }
                    .buttonStyle(.link)
            }
        }
    }
}

/// Wartości prowadzące do list (autor, lektor, gatunek…) — jak linki w web UI.
struct LinkList: View {
    let values: [(label: String, action: () -> Void)]

    var body: some View {
        // Zwykłe zawijanie: każdy element to przycisk-link.
        FlowLayout(spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Button(value.label + (index < values.count - 1 ? "," : "")) { value.action() }
                    .buttonStyle(.link)
                    .multilineTextAlignment(.leading)
            }
        }
    }
}

/// Prosty układ zawijający elementy do kolejnych wierszy.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = Self.size(of: view, maxWidth: width)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    /// Element dłuższy niż wiersz (np. bardzo długa nazwa wydawcy) dostaje szerokość wiersza i się zawija.
    private static func size(of view: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let natural = view.sizeThatFits(.unspecified)
        // Pomiar z szerokością 0 (minimalny rozmiar w `Grid`) nie może zwężać kolumny.
        guard maxWidth.isFinite, maxWidth > 80, natural.width > maxWidth else { return natural }
        return view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = Self.size(of: view, maxWidth: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

enum Formats {
    /// „1 plik”, „3 pliki”, „5 plików” (odmiana liczebnika).
    static func files(_ count: Int) -> String {
        let tens = count % 100, ones = count % 10
        if count == 1 { return "1 plik" }
        if (2...4).contains(ones), !(12...14).contains(tens) { return "\(count) pliki" }
        return "\(count) plików"
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) godz. \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total) s"
    }

    /// Jak web UI (`$bytesPretty`): jednostki dziesiętne, do dwóch miejsc po przecinku.
    static func size(_ bytes: Double?) -> String {
        guard let bytes, bytes > 0 else { return "—" }
        let polish = Locale(identifier: "pl_PL")
        func number(_ value: Double, _ digits: Int) -> String {
            value.formatted(.number.precision(.fractionLength(0...digits)).locale(polish))
        }
        switch bytes {
        case ..<1_000: return "\(Int(bytes)) B"
        case ..<1_000_000: return number(bytes / 1_000, 2) + " KB"
        case ..<1_000_000_000: return number(bytes / 1_000_000, 2) + " MB"
        default: return number(bytes / 1_000_000_000, 2) + " GB"
        }
    }

    static func date(ms: Double?) -> String? {
        ms.map { day(Date(timeIntervalSince1970: $0 / 1000)) }
    }

    /// Data po polsku niezależnie od języka systemu (interfejs aplikacji jest tylko po polsku).
    static func day(_ date: Date, long: Bool = false) -> String {
        date.formatted(.dateTime.day().month(long ? .wide : .abbreviated).year().locale(Locale(identifier: "pl_PL")))
    }
}

/// Klucz `.task(id:)` stron wczytywanych z serwera: zmiana tego, co pokazują, albo licznika zmian
/// biblioteki (`LibraryBrowser.revision`) wczytuje je od nowa i przerywa wczytanie poprzednie
/// (nieaktualne nie nadpisze nowszego).
struct ReloadKey: Hashable {
    let id: String
    let revision: Int
}

/// Komunikat błędu albo kółko ładowania dla stron wczytywanych z serwera.
struct LoadingState: View {
    let error: String?
    let retry: () async -> Void

    var body: some View {
        if let error {
            ContentUnavailableView {
                Label("Nie udało się wczytać", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Spróbuj ponownie") { Task { await retry() } }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension AudiobookshelfClient.LibraryItem {
    /// Książka bez plików audio, z samym e-bookiem — główną akcją jest „Czytaj”, nie „Odtwarzaj”.
    var isEbookOnly: Bool { !isPodcast && (media.numTracks ?? 1) == 0 && media.ebookFormat != nil }
}
