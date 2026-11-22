// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 11b).

import SwiftUI
import AudiobookshelfKit
import AudiobookshelfPlayback

// Tryb „Tekst” odtwarzacza (etap 11b): tekst książki z bieżącym zdaniem w pełnej jasności
// i resztą przygaszoną, przewijany tak, by bieżące zdanie stało w górnej jednej trzeciej
// ekranu. Akapit to jeden `Text` ze zdaniami oznaczonymi atrybutem: łamanie wierszy jak
// w książce, a podświetlenie przesuwa się zdanie po zdaniu (`SentenceHighlight` animuje
// indeks zdania). Położenie zdań w akapicie daje `Text.LayoutKey` — do dotknięć i przewijania.

/// Numer zdania w mapie, doczepiony do kawałka tekstu akapitu.
struct SentenceMark: TextAttribute {
    let index: Int
}

/// Rysuje akapit: zdanie o indeksie `active` w pełnej jasności, reszta przygaszona. `active`
/// jest animowalne — przejście z 4 na 5 to płynne przygaszenie jednego i rozjaśnienie drugiego.
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
                    // Lekka poświata bieżącego zdania na ciemnym tle.
                    ctx.addFilter(.shadow(color: .white.opacity(0.28 * weight), radius: 7))
                }
                ctx.draw(run)
            }
        }
    }
}

/// Ustawienia tekstu zapamiętane na urządzeniu.
enum BookTextSettings {
    static let serifKey = "bookText.serif"
    static let scaleKey = "bookText.scale"
    static let scales: [Double] = [0.8, 0.9, 1, 1.12, 1.25, 1.4, 1.6]
}

/// Tekst książki w odtwarzaczu: stany (wczytywanie, brak mapy, mapa nieaktualna) i przewijany tekst.
struct BookTextView: View {
    let model: TextFollowModel
    let player: AudiobookPlayer
    /// Wysokość wolnego miejsca pod tekstem (sterowanie) — przycisk powrotu stoi nad nim.
    var bottomInset: CGFloat = 0

    var body: some View {
        switch model.phase {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Wczytywanie tekstu…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let reason):
            ContentUnavailableView {
                Label("Brak tekstu", systemImage: "text.page.slash")
            } description: {
                Text(reason.message)
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Nie udało się wczytać tekstu", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Spróbuj ponownie") { model.reload() }
                    .buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if let document = model.document {
                BookTextScroll(model: model, document: document, player: player, bottomInset: bottomInset)
            }
        }
    }
}

/// Zwykła klasa (nie obserwowana): położenie przewijania zmienia się co klatkę, a widok
/// tekstu nie powinien się przez to przebudowywać.
private final class ScrollMetrics {
    var offset: CGFloat = 0
    var viewport: CGFloat = 0
    /// Górna krawędź bieżącego zdania we współrzędnych widocznej części przewijania.
    var sentenceTop: CGFloat?
    var sentenceParagraph: Int?
    /// Przewinięcie do akapitu poza ekranem czeka na jego układ, żeby dociągnąć do zdania.
    var pendingRefine = false
}

private struct BookTextScroll: View {
    let model: TextFollowModel
    let document: TextSyncDocument
    let player: AudiobookPlayer
    let bottomInset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(BookTextSettings.serifKey) private var serif = true
    @AppStorage(BookTextSettings.scaleKey) private var scale = 1.0
    @ScaledMetric(relativeTo: .body) private var baseSize: CGFloat = 21
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var metrics = ScrollMetrics()

    /// Bieżące zdanie stoi w tym miejscu ekranu (od góry).
    private static let readingLine: CGFloat = 0.3

    var body: some View {
        let size = baseSize * scale
        let dimmed = contrast == .increased ? 0.62 : 0.4
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
                            size: size, serif: serif, dimmed: dimmed, reduceMotion: reduceMotion,
                            onTap: play(sentence:),
                            onSentenceTop: { top in sentenceMoved(top, paragraph: index) }
                        )
                        // Kolumna z marginesem wewnątrz akapitu, a akapit na całą szerokość: przewijanie
                        // do akapitu (`scrollTo(id:)`) wyrównuje go z krawędzią widoku, więc margines
                        // poza akapitem przesuwał tekst w bok.
                        .frame(maxWidth: sizeClass == .regular ? 660 : 620, alignment: .leading)
                        .padding(.horizontal, 28)
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
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in metrics.offset = new }
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, new in metrics.viewport = new }
            .onScrollPhaseChange { _, phase in
                // Przeciągnięcie palcem (nie przewijanie z kodu) wstrzymuje śledzenie.
                if phase == .interacting { model.userDidScroll() }
            }
            .overlay(alignment: .bottom) {
                if !model.isFollowing {
                    Button {
                        model.resumeFollowing()
                    } label: {
                        Label("Wróć do bieżącego miejsca", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .padding(.bottom, 12 + bottomInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .top) { notices }
            // Przejście przycisku powrotu tylko z animacją; z „Ogranicz ruch” — samo pojawienie się.
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
        VStack(spacing: 6) {
            if model.isStale {
                Label("Nagranie albo e-book zmieniły się od synchronizacji — tekst może nie trafiać w audio. Zsynchronizuj e-book na Macu ponownie.", systemImage: "exclamationmark.triangle.fill")
            }
            if model.isOffline {
                Label("Tekst z urządzenia (bez połączenia z serwerem)", systemImage: "wifi.slash")
            }
        }
        .font(.footnote)
        .padding(10)
        .frame(maxWidth: 560)
        .glassEffect(in: .rect(cornerRadius: 14))
        .padding(.horizontal, 16)
        .opacity(model.isStale || model.isOffline ? 1 : 0)
        .accessibilityHidden(!(model.isStale || model.isOffline))
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

    /// Bieżące zdanie zgłasza swoje położenie (po układzie i przy przewijaniu).
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
        let animate = animated && !reduceMotion
        if metrics.sentenceParagraph == target, let top = metrics.sentenceTop {
            let y = max(0, metrics.offset + top - metrics.viewport * Self.readingLine)
            guard abs(y - metrics.offset) > 1 else { return }
            if animate {
                withAnimation(.spring(duration: 0.7, bounce: 0.12)) { position.scrollTo(y: y) }
            } else {
                position.scrollTo(y: y)
            }
        } else {
            // Akapitu nie ma jeszcze na ekranie (leniwy stos): najpierw do niego, potem do zdania.
            metrics.pendingRefine = true
            position.scrollTo(id: target, anchor: .top)
        }
    }
}

/// Jeden akapit (albo nagłówek) jako jeden tekst; dotknięcie zdania przenosi tam odtwarzanie.
private struct ParagraphText: View, @MainActor Equatable {
    let paragraph: TextSyncDocument.Paragraph
    let document: TextSyncDocument
    let highlight: Double
    let isCurrent: Bool
    let current: Int?
    let size: CGFloat
    let serif: Bool
    let dimmed: Double
    let reduceMotion: Bool
    let onTap: (Int) -> Void
    let onSentenceTop: (CGFloat) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.paragraph == b.paragraph && a.highlight == b.highlight && a.isCurrent == b.isCurrent
            && (a.isCurrent ? a.current == b.current : true)
            && a.size == b.size && a.serif == b.serif && a.dimmed == b.dimmed && a.reduceMotion == b.reduceMotion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if paragraph.startsSection { SectionBreak(size: size) }
            text
                .font(font)
                .lineSpacing(lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .textRenderer(SentenceHighlight(active: highlight, dimmed: dimmed, glow: true))
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
            // VoiceOver: każde zdanie osobno, bieżące zaznaczone, stuknięcie dwa razy — odtwarzanie od zdania.
            VStack(alignment: .leading) {
                ForEach(Array(paragraph.sentences), id: \.self) { index in
                    Button(document.map.sentences[index].text) { onTap(index) }
                        .accessibilityHint(Text("Odtwarza od tego zdania"))
                        .accessibilityAddTraits(index == current ? .isSelected : [])
                        .accessibilityAddTraits(paragraph.isHeading ? .isHeader : [])
                }
            }
        }
    }

    private var font: Font {
        let design: Font.Design = serif ? .serif : .default
        switch paragraph.kind {
        case .heading(1): return .system(size: size * 1.45, weight: .semibold, design: design)
        case .heading: return .system(size: size * 1.22, weight: .semibold, design: design)
        case .preformatted: return .system(size: size * 0.9, design: .monospaced)
        case .quote: return .system(size: size * 0.95, design: design).italic()
        default: return .system(size: size, weight: .regular, design: design)
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

    /// Zdanie pod punktem (współrzędne tekstu); między wierszami — najbliższy wiersz.
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

    /// Górna krawędź pierwszego wiersza zdania (współrzędne tekstu).
    static func lineTop(of sentence: Int, in layout: Text.Layout) -> CGFloat? {
        for line in layout {
            for run in line where run[SentenceMark.self]?.index == sentence {
                return line.typographicBounds.rect.minY
            }
        }
        return nil
    }
}

/// Przerwa przed nowym plikiem rozdziału EPUB-a.
private struct SectionBreak: View {
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.6) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().frame(width: 4, height: 4)
            }
        }
        .opacity(0.35)
        .frame(maxWidth: .infinity)
        .padding(.vertical, size * 1.4)
        .accessibilityHidden(true)
    }
}

/// Podaje modelowi czas z odtwarzacza. Osobny, pusty widok: tylko on obserwuje zegar
/// (dwa razy na sekundę), reszta trybu tekstu odświeża się, gdy zmieni się zdanie.
struct TextTimeFeed: View {
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

/// Menu „Aa”: krój i rozmiar tekstu.
struct BookTextSettingsMenu: View {
    @AppStorage(BookTextSettings.serifKey) private var serif = true
    @AppStorage(BookTextSettings.scaleKey) private var scale = 1.0

    var body: some View {
        Menu {
            Picker("Krój", selection: $serif) {
                Text("Szeryfowy").tag(true)
                Text("Bezszeryfowy").tag(false)
            }
            ControlGroup {
                Button("Mniejszy tekst", systemImage: "textformat.size.smaller") { step(-1) }
                    .disabled(scale <= BookTextSettings.scales.first!)
                Button("Większy tekst", systemImage: "textformat.size.larger") { step(1) }
                    .disabled(scale >= BookTextSettings.scales.last!)
            }
        } label: {
            Label("Wygląd tekstu", systemImage: "textformat.size")
        }
        .menuActionDismissBehavior(.disabled)
    }

    private func step(_ direction: Int) {
        let scales = BookTextSettings.scales
        let current = scales.firstIndex { $0 >= scale - 0.001 } ?? 2
        scale = scales[min(max(0, current + direction), scales.count - 1)]
    }
}
