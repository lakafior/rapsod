// Pochodzenie: kod własny projektu (etap 11b). Ten sam układ co tryb „Tekst” klienta iOS
// (`iOS/AudiobookSwiftiOS/BookTextView.swift`), napisany osobno dla macOS; logika (mapa,
// bieżące zdanie, śledzenie, okno akapitów) jest wspólna w pakiecie (`TextFollowModel`).

import AudiobookshelfKit
import SwiftUI

/// Numer zdania w mapie, doczepiony do kawałka tekstu akapitu.
struct SentenceMark: TextAttribute {
    let index: Int
}

/// Bieżące zdanie w pełnej jasności, reszta przygaszona; `active` animuje się płynnie zdanie po zdaniu.
struct SentenceHighlight: TextRenderer {
    var active: Double
    var dimmed: Double
    var glow: Bool

    var animatableData: Double {
        get { active }
        set { active = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                var ctx = context
                let weight = run[SentenceMark.self].map { max(0, 1 - abs(Double($0.index) - active)) } ?? 0
                ctx.opacity = dimmed + (1 - dimmed) * weight
                if glow, weight > 0.02 {
                    ctx.addFilter(.shadow(color: .white.opacity(0.22 * weight), radius: 6))
                }
                ctx.draw(run)
            }
        }
    }
}

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

private final class ScrollMetrics {
    var offset: CGFloat = 0
    var viewport: CGFloat = 0
    var sentenceTop: CGFloat?
    var sentenceParagraph: Int?
    var pendingRefine = false
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
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var metrics = ScrollMetrics()

    private static let readingLine: CGFloat = 0.3

    var body: some View {
        let size = baseSize * scale
        let dimmed = contrast == .increased ? 0.6 : (colorScheme == .dark ? 0.4 : 0.34)
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: size * 0.85) {
                    ForEach(model.window, id: \.self) { index in
                        let paragraph = document.paragraphs[index]
                        ParagraphText(
                            paragraph: paragraph, document: document,
                            highlight: model.highlight(for: paragraph),
                            isCurrent: model.currentParagraph == index,
                            current: model.currentSentence,
                            size: size, serif: serif, dimmed: dimmed, glow: colorScheme == .dark, reduceMotion: reduceMotion,
                            onTap: play(sentence:),
                            onSentenceTop: { top in sentenceMoved(top, paragraph: index) }
                        )
                        // Porównanie bez domknięć: przy zmianie zdania przelicza się tylko akapit, którego to dotyczy.
                        .equatable()
                        // Kolumna z marginesem wewnątrz akapitu, a akapit na całą szerokość: przewijanie
                        // do akapitu (`scrollTo(id:)`) wyrównuje go z krawędzią widoku, więc margines
                        // poza akapitem przesuwał tekst w bok.
                        .frame(maxWidth: columnWidth, alignment: .leading)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity)
                        .id(index)
                        .onAppear { edgeAppeared(index) }
                    }
                }
                .scrollTargetLayout()
                .padding(.top, proxy.size.height * Self.readingLine)
                .padding(.bottom, proxy.size.height * 0.6)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in metrics.offset = new }
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, new in metrics.viewport = new }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { model.userDidScroll() }
            }
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
            .typesettingLanguage(.init(languageCode: Locale.LanguageCode(String(document.map.locale.prefix(2)))))
            .onChange(of: model.scrollRequest) {
                // Najpierw akapit z nowym bieżącym zdaniem musi zgłosić jego położenie (następna klatka).
                let animated = !model.scrollIsJump
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(30))
                    scrollToCurrent(animated: animated)
                }
            }
            .task {
                metrics.viewport = proxy.size.height
                // Pierwsze ustawienie po ułożeniu tekstu.
                try? await Task.sleep(for: .milliseconds(60))
                scrollToCurrent(animated: false)
            }
        }
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

    private func edgeAppeared(_ index: Int) {
        guard !model.isFollowing else { return }
        if index == model.window.lowerBound { model.reachedWindowEdge(top: true) }
        if index == model.window.upperBound - 1 { model.reachedWindowEdge(top: false) }
    }

    private func sentenceMoved(_ top: CGFloat, paragraph: Int) {
        metrics.sentenceTop = top
        metrics.sentenceParagraph = paragraph
        if metrics.pendingRefine, paragraph == model.currentParagraph {
            metrics.pendingRefine = false
            // Po skoku do akapitu przesunięcie przewijania aktualizuje się chwilę później —
            // dociągnięcie do zdania dopiero w następnym przebiegu.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(40))
                scrollToCurrent(animated: false)
            }
        }
    }

    private func scrollToCurrent(animated: Bool) {
        guard model.isFollowing else { return }
        let target = model.currentParagraph ?? model.window.lowerBound
        if metrics.sentenceParagraph == target, let top = metrics.sentenceTop {
            let y = max(0, metrics.offset + top - metrics.viewport * Self.readingLine)
            guard abs(y - metrics.offset) > 1 else { return }
            if animated, !reduceMotion {
                withAnimation(.spring(duration: 0.7, bounce: 0.12)) { position.scrollTo(y: y) }
            } else {
                position.scrollTo(y: y)
            }
        } else {
            metrics.pendingRefine = true
            position.scrollTo(id: target, anchor: .top)
            // Gdyby akapit zgłosił położenie, zanim przewijanie się ustaliło — druga próba.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                if metrics.sentenceParagraph == target { metrics.pendingRefine = false; scrollToCurrent(animated: false) }
            }
        }
    }
}

private struct ParagraphText: View, @MainActor Equatable {
    let paragraph: TextSyncDocument.Paragraph
    let document: TextSyncDocument
    let highlight: Double
    let isCurrent: Bool
    let current: Int?
    let size: CGFloat
    let serif: Bool
    let dimmed: Double
    let glow: Bool
    let reduceMotion: Bool
    let onTap: (Int) -> Void
    let onSentenceTop: (CGFloat) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.paragraph == b.paragraph && a.highlight == b.highlight && a.isCurrent == b.isCurrent
            && (a.isCurrent ? a.current == b.current : true)
            && a.size == b.size && a.serif == b.serif && a.dimmed == b.dimmed && a.glow == b.glow && a.reduceMotion == b.reduceMotion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if paragraph.startsSection { SectionBreak(size: size) }
            text
                .font(font)
                .lineSpacing(lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .textRenderer(SentenceHighlight(active: highlight, dimmed: dimmed, glow: glow))
                .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: highlight)
                .padding(.leading, paragraph.kind == .quote || paragraph.kind == .listItem ? size : 0)
                .padding(.top, paragraph.isHeading ? size * 0.6 : 0)
                .padding(.bottom, paragraph.isHeading ? size * 0.3 : 0)
                .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                    GeometryReader { proxy in
                        let origin = layouts.first.map { proxy[$0.origin] } ?? .zero
                        let layout = layouts.first?.layout
                        let sentenceLine: CGFloat? = isCurrent ? current.flatMap { c in layout.flatMap { Self.lineTop(of: c, in: $0) } } : nil
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture(coordinateSpace: .local) { location in
                                if let layout, let sentence = Self.sentence(at: CGPoint(x: location.x - origin.x, y: location.y - origin.y), in: layout) {
                                    onTap(sentence)
                                }
                            }
                            .pointerStyle(.link)
                            .onGeometryChange(for: CGFloat?.self) { geometry in
                                guard let line = sentenceLine else { return nil }
                                return geometry.frame(in: .scrollView(axis: .vertical)).minY + origin.y + line
                            } action: { top in
                                if let top { onSentenceTop(top) }
                            }
                    }
                    .accessibilityHidden(true)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityRepresentation {
            VStack(alignment: .leading) {
                ForEach(Array(paragraph.sentences), id: \.self) { index in
                    Button(document.map.sentences[index].text) { onTap(index) }
                        .accessibilityHint(Text("Odtwarza od tego zdania"))
                        .accessibilityAddTraits(index == current ? .isSelected : [])
                        .accessibilityAddTraits(paragraph.isHeading ? .isHeader : [])
                }
            }
        }
        .help(paragraph.isHeading ? "" : "Kliknij zdanie, żeby słuchać od niego")
    }

    private var font: Font {
        let design: Font.Design = serif ? .serif : .default
        switch paragraph.kind {
        case .heading(1): return .system(size: size * 1.45, weight: .semibold, design: design)
        case .heading: return .system(size: size * 1.22, weight: .semibold, design: design)
        case .preformatted: return .system(size: size * 0.9, design: .monospaced)
        case .quote: return .system(size: size * 0.95, design: design).italic()
        default: return .system(size: size, design: design)
        }
    }

    private var lineSpacing: CGFloat { paragraph.isHeading ? size * 0.2 : size * 0.42 }

    private var text: Text {
        var result = Text(verbatim: "")
        for index in paragraph.sentences {
            let piece = Text(verbatim: document.displayText(ofSentence: index)).customAttribute(SentenceMark(index: index))
            result = index == paragraph.sentences.lowerBound ? piece : Text("\(result) \(piece)")
        }
        return result
    }

    static func sentence(at point: CGPoint, in layout: Text.Layout) -> Int? {
        var best: (distance: CGFloat, index: Int)?
        for line in layout {
            let bounds = line.typographicBounds.rect
            let dy = point.y < bounds.minY ? bounds.minY - point.y : max(0, point.y - bounds.maxY)
            for run in line {
                guard let mark = run[SentenceMark.self] else { continue }
                let rect = run.typographicBounds.rect
                let dx = point.x < rect.minX ? rect.minX - point.x : max(0, point.x - rect.maxX)
                let distance = dy * 3 + dx
                if best == nil || distance < best!.distance { best = (distance, mark.index) }
            }
        }
        return best.flatMap { $0.distance < 60 ? $0.index : nil }
    }

    static func lineTop(of sentence: Int, in layout: Text.Layout) -> CGFloat? {
        for line in layout {
            for run in line where run[SentenceMark.self]?.index == sentence {
                return line.typographicBounds.rect.minY
            }
        }
        return nil
    }
}

private struct SectionBreak: View {
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.6) {
            ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 4, height: 4) }
        }
        .opacity(0.35)
        .frame(maxWidth: .infinity)
        .padding(.vertical, size * 1.4)
        .accessibilityHidden(true)
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
