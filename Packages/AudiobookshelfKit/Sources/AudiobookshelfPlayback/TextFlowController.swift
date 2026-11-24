// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 11d).

import AudiobookshelfKit
import CoreGraphics
import CoreText
import Foundation
import QuartzCore
import os
let flowLog = Logger(subsystem: "net.smigi.rapsod.textflow", category: "Flow")

/// Rdzeń widoku tekstu książki (etap 11d), wspólny dla Maca i iOS. Widok platformy daje tylko
/// przewijanie (NSScrollView / UIScrollView), zegar klatek, dotyk i dostępność; tutaj jest
/// reszta: układ (`TextFlowLayout`), warstwy wierszy, przejście jasności i ruch śledzenia.
///
/// Dlaczego nie SwiftUI (`LazyVStack` + `ScrollPosition`), jak w 11b — nagrania pokazały:
/// animowane `scrollTo(y:)` na macOS w pierwszej klatce staje w celu i wraca; położenie zdania
/// przychodzi z opóźnieniem (preferencje + uśpienia), więc każde przewinięcie było liczone ze
/// starych danych; przesunięcie okna akapitów i szacowane wysokości dawały skoki treści.
/// Tu wszystko jest synchroniczne: położenie każdego wiersza jest znane przed klatką,
/// a przesunięcie przewijania ustawia wyłącznie ten kontroler.
///
/// Każdy wiersz to osobna warstwa z bitmapą całego wiersza w przygaszonym kolorze (przewijanie
/// przesuwa warstwy, bez rysowania). Bieżące zdanie to nakładka z tym samym tekstem w pełnej
/// jasności i z poświatą warstwy (GPU), a przejście jasności zmienia tylko jej krycie — żadnego
/// rysowania w trakcie animacji: przygaszone α + (1 − α)·w to dokładnie nałożenie nakładki o kryciu w.
@MainActor
public final class TextFlowController {
    public struct Appearance: Equatable {
        /// Kolor tekstu w pełnej jasności i krycie przygaszonych zdań.
        public var ink: CGColor
        public var dimmed: Double
        /// Poświata bieżącego zdania (na ciemnym tle) i jej promień w punktach.
        public var glow: CGColor?
        public var glowRadius: CGFloat
        public var scale: CGFloat
        public var reduceMotion: Bool

        public init(ink: CGColor, dimmed: Double, glow: CGColor?, glowRadius: CGFloat, scale: CGFloat, reduceMotion: Bool) {
            self.ink = ink; self.dimmed = dimmed; self.glow = glow; self.glowRadius = glowRadius
            self.scale = scale; self.reduceMotion = reduceMotion
        }
    }

    /// Połączenie z widokiem platformy.
    public struct Host {
        /// Bieżące przesunięcie przewijania (y lewego górnego rogu widocznej części treści).
        public var offset: @MainActor () -> CGFloat
        /// Ustawienie przesunięcia bez animacji (animację robi kontroler, klatka po klatce).
        public var setOffset: @MainActor (CGFloat) -> Void
        /// Nowa wysokość treści.
        public var setContentHeight: @MainActor (CGFloat) -> Void
        /// Włączenie / wyłączenie zegara klatek (`tick`).
        public var setAnimating: @MainActor (Bool) -> Void
        /// Zmieniło się, które zdania są widoczne (dostępność).
        public var visibleChanged: @MainActor () -> Void
        /// Krótkie przenikanie widoku przed natychmiastowym przeskokiem.
        public var dissolve: @MainActor () -> Void = {}

        public init(offset: @escaping @MainActor () -> CGFloat, setOffset: @escaping @MainActor (CGFloat) -> Void, setContentHeight: @escaping @MainActor (CGFloat) -> Void, setAnimating: @escaping @MainActor (Bool) -> Void, visibleChanged: @escaping @MainActor () -> Void) {
            self.offset = offset; self.setOffset = setOffset; self.setContentHeight = setContentHeight
            self.setAnimating = setAnimating; self.visibleChanged = visibleChanged
        }
    }

    /// Warstwa z wierszami — widok platformy wstawia ją do przewijanej treści (y w dół).
    public let container = CALayer()
    public private(set) var layout: TextFlowLayout?
    public var host: Host?
    public weak var model: TextFollowModel?

    private var appearance: Appearance?
    private var viewport: CGSize = .zero
    private var follower = ScrollFollower(position: 0)
    private var fader = HighlightFader()
    private var layers: [LineKey: TextLineLayer] = [:]
    private var pool: [TextLineLayer] = []
    private var lastSentence: Int?
    private var lastJump = -1
    private var lastReturn = -1
    private var following = true
    private var lineTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var animating = false
    /// Trwa aktualizacja warstw — zgłoszenia przewinięcia od własnego `setOffset` pomijamy.
    private var updating = false
    private var settingOffset = false
    /// Nowy układ (rozmiar okna, tekstu) — tekst staje od razu, bez przenikania (to nie przeskok w książce).
    private var relayouting = false
    /// Nakładki bieżącego (i gasnącego) zdania w widocznych wierszach.
    private var overlays: [LineKey: [Int: TextLineLayer]] = [:]
    /// Zdanie w pełnej jasności po zakończonym przejściu — warstwa bazowa go nie rysuje, więc
    /// w spoczynku tekst bieżącego zdania jest narysowany raz (bez podwójnego wygładzania krawędzi).
    private var solid: Int?
    /// Licznik przerysowań wierszy (pomiar w wersji Debug).
    public private(set) var redraws = 0

    struct LineKey: Hashable {
        let paragraph: Int
        let line: Int
    }

    /// Odstęp warstwy wiersza od tekstu (miejsce na poświatę).
    nonisolated static let pad: CGFloat = 12

    public init() {
        container.actions = Self.noActions
        container.anchorPoint = .zero
    }

    nonisolated(unsafe) static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull(),
        "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(), "hidden": NSNull(), "opacity": NSNull(),
    ]

    // MARK: - Konfiguracja

    /// Dokument, wygląd i rozmiar widoku. Zmiana szerokości, rozmiaru tekstu albo kroju układa
    /// tekst od nowa i zostawia w miejscu bieżące zdanie (albo — bez śledzenia — akapit u góry).
    public func configure(document: TextSyncDocument, style: TextFlowStyle, viewport: CGSize, appearance: Appearance) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        let relayout = layout == nil || layout!.document.map != document.map || layout!.style.key != style.key
            || abs(layout!.width - viewport.width) > 0.5 || abs(self.viewport.height - viewport.height) > 0.5
        let restyle = self.appearance != appearance
        self.appearance = appearance
        fader.duration = appearance.reduceMotion ? 0.15 : 0.45
        if relayout {
            flowLog.debug("relayout w=\(viewport.width) h=\(viewport.height) oldh=\(self.viewport.height) key=\(style.key, privacy: .public)")
            let documentChanged = layout?.document.map != document.map
            // Kotwica: akapit u góry i jak daleko w nim (gdy użytkownik czyta sam).
            var anchor: (paragraph: Int, fraction: CGFloat)?
            if let old = layout, !documentChanged {
                let y = (host?.offset() ?? 0) + self.viewport.height * FollowPlanner.readingLine
                let p = old.paragraph(atY: y)
                anchor = (p, (y - old.top(of: p)) / max(1, old.height(of: p)))
            }
            self.viewport = viewport
            layout = TextFlowLayout(document: document, style: style, width: viewport.width,
                                    topInset: viewport.height * FollowPlanner.readingLine, bottomInset: viewport.height * 0.6)
            removeAllLayers()
            container.frame = CGRect(x: 0, y: 0, width: viewport.width, height: layout!.contentHeight)
            host?.setContentHeight(layout!.contentHeight)
            if documentChanged { lastSentence = nil; fader.setCurrent(nil, instant: true) }
            if let anchor, !following, let layout {
                layout.layout(anchor.paragraph)
                let y = layout.top(of: anchor.paragraph) + anchor.fraction * layout.height(of: anchor.paragraph)
                setOffset(y - viewport.height * FollowPlanner.readingLine)
            }
            relayouting = true
            sync(forceJump: true)
            relayouting = false
            scheduleIdleLayout()
        } else if restyle {
            for layer in layers.values { layer.appearance = appearance }
            redrawAll()
        }
        updateLayers()
    }

    // MARK: - Stan z modelu

    /// Odczyt stanu modelu (wywoływane, gdy zmieni się zdanie, śledzenie albo przyjdzie prośba o przeskok).
    public func sync(forceJump: Bool = false) {
        guard let model, layout != nil else { return }
        let sentence = model.currentSentence
        let jump = forceJump || model.jumpRequest != lastJump
        let back = model.returnRequest != lastReturn
        lastJump = model.jumpRequest
        lastReturn = model.returnRequest
        if model.isFollowing != following {
            following = model.isFollowing
            if !following { stopFollowing() }
        }
        if sentence != lastSentence || jump {
            let instant = lastSentence == nil || appearance?.reduceMotion == true && jump
            lastSentence = sentence
            if solid != nil, solid != sentence { setSolid(nil) }
            fader.setCurrent(sentence, instant: instant)
            if instant { refreshOverlays() }
            host?.visibleChanged()
            startAnimating()
        }
        guard following else { return }
        if jump { follow(.jump) } else if back { follow(.back) } else { follow(.sentence) }
    }

    private enum Reason { case jump, back, sentence, line }

    /// Cel przewijania: wiersz bieżącego zdania, w którym jest teraz lektor, na linii czytania.
    private func follow(_ reason: Reason) {
        lineTask?.cancel()
        guard following, let model, let layout, let sentence = model.currentSentence else { return }
        // Akapity wokół bieżącego — dokładnie (różnicę nad ekranem kompensujemy), potem wiersze zdania.
        if let paragraph = layout.document.paragraph(ofSentence: sentence) { ensureExact(around: paragraph) }
        let lines = layout.lines(ofSentence: sentence)
        guard !lines.isEmpty else { return }
        let span = model.span(ofSentence: sentence)
        let now = model.estimatedTime()
        let index = FollowPlanner.lineIndex(fraction: FollowPlanner.spokenFraction(time: now, span: span), in: lines) ?? 0
        let target = FollowPlanner.offset(for: lines[index], viewport: viewport.height, range: 0...maxOffset)
        let current = Double(host?.offset() ?? CGFloat(follower.position))
        let reduce = appearance?.reduceMotion ?? false
        flowLog.debug("follow \(String(describing: reason), privacy: .public) s=\(sentence) line=\(index)/\(lines.count) cur=\(current) target=\(target) max=\(self.maxOffset) jumpReq=\(model.jumpRequest)")
        switch reason {
        case .jump, .back:
            let animate = reason == .jump
                ? FollowPlanner.shouldAnimateJump(from: current, to: target, viewport: viewport.height, reduceMotion: reduce)
                : FollowPlanner.shouldAnimate(from: current, to: target, viewport: viewport.height, reduceMotion: reduce)
            if animate {
                if follower.isSettled { follower.adopt(current) }
                follower.target = target
            } else {
                // Od razu w miejscu; krótkie przenikanie zamiast cięcia (gdy jest co przenikać).
                if abs(target - current) > 1, !relayouting { host?.dissolve() }
                follower.snap(to: target)
                setOffset(target)
            }
        case .sentence, .line:
            if reduce || abs(target - current) > viewport.height * 2 {
                follower.snap(to: target)
                setOffset(target)
            } else {
                if follower.isSettled, abs(follower.position - current) > 0.5 { follower.adopt(current) }
                follower.target = target
            }
        }
        startAnimating()
        // Następny wiersz zdania — krok przewijania dokładnie wtedy, gdy lektor do niego dojdzie.
        if model.isPlaying, let next = FollowPlanner.nextLineTime(after: now, span: span, lines: lines) {
            let delay = max(0.02, (next - now) / max(0.25, model.rate))
            lineTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(min(delay, 2)))
                guard !Task.isCancelled, let self else { return }
                self.follow(.line)
            }
        }
    }

    private func stopFollowing() {
        lineTask?.cancel()
        follower.adopt(Double(host?.offset() ?? CGFloat(follower.position)))
    }

    /// Użytkownik przewija sam (zgłasza widok platformy) — model dowie się osobno.
    public func userScrolled() {
        if following { following = false; stopFollowing() }
    }

    // MARK: - Klatki

    /// Jedna klatka (zegar ekranu); `false` — można zatrzymać zegar.
    @discardableResult
    public func tick(_ dt: Double) -> Bool {
        var busy = false
        if following, !follower.isSettled {
            follower.step(dt)
            setOffset(follower.position)
            busy = !follower.isSettled
        }
        let changed = fader.step(dt)
        if !changed.isEmpty { updateOverlays(sentences: changed) }
        if let current = fader.current, solid != current, fader.weight(of: current) >= 1 { setSolid(current) }
        busy = busy || fader.isAnimating
        if !busy { stopAnimating() }
        return busy
    }

    private func startAnimating() {
        guard !animating else { return }
        animating = true
        host?.setAnimating(true)
    }

    private func stopAnimating() {
        guard animating else { return }
        animating = false
        host?.setAnimating(false)
        scheduleIdleLayout()
    }

    // MARK: - Przewijanie i warstwy

    private var maxOffset: CGFloat {
        max(0, (layout?.contentHeight ?? 0) - viewport.height)
    }

    private func setOffset(_ value: CGFloat) {
        let scale = appearance?.scale ?? 2
        // Do pełnych pikseli ekranu — tekst ostry także w ruchu.
        let y = (min(max(0, value), maxOffset) * scale).rounded() / scale
        if abs((host?.offset() ?? 0) - y) > 0.001 {
            // Powiadomienie widoku o przewinięciu przyjdzie w trakcie — warstwy uzupełniamy raz, tutaj.
            settingOffset = true
            host?.setOffset(y)
            settingOffset = false
        }
        updateLayers()
    }

    /// Widok platformy przewinął się (palcem, kółkiem, paskiem albo przez `setOffset`).
    public func viewportScrolled() {
        if !settingOffset { updateLayers() }
    }

    /// Dokładny układ akapitów wokół `paragraph`; różnicę wysokości akapitów nad górną krawędzią
    /// ekranu kompensuje przesunięciem (treść na ekranie stoi w miejscu).
    private func ensureExact(around paragraph: Int) {
        guard let layout else { return }
        let lower = max(0, paragraph - 6), upper = min(layout.count, paragraph + 12)
        makeExact(lower..<upper)
    }

    private func makeExact(_ range: Range<Int>) {
        guard let layout, !range.isEmpty else { return }
        let offset = host?.offset() ?? 0
        let anchor = layout.paragraph(atY: offset)
        let anchorTop = layout.top(of: anchor)
        var changed = false
        for p in range where !layout.isExact(p) {
            layout.layout(p)
            changed = true
        }
        guard changed else { return }
        let delta = layout.top(of: anchor) - anchorTop
        container.frame.size.height = layout.contentHeight
        host?.setContentHeight(layout.contentHeight)
        if abs(delta) > 0.001 {
            follower.shift(by: delta)
            for (key, layer) in layers { layer.frame = frame(for: key) ?? layer.frame }
            host?.setOffset(offset + delta)
        }
    }

    private func frame(for key: LineKey) -> CGRect? {
        guard let layout, let paragraph = layout.existingLayout(key.paragraph), paragraph.lines.indices.contains(key.line) else { return nil }
        let line = paragraph.lines[key.line]
        let top = layout.top(of: key.paragraph) + line.top
        let width = line.line == nil ? layout.column.width : line.width
        let x = line.line == nil ? layout.column.x : line.x
        return CGRect(x: x - Self.pad, y: top - Self.pad, width: width + 2 * Self.pad, height: line.height + 2 * Self.pad)
    }

    private var visibleRange: Range<Int> = 0..<0

    /// Warstwy wierszy dla widocznej części z zapasem pół ekranu w każdą stronę.
    private func updateLayers() {
        guard !updating, let layout, let appearance, viewport.height > 0 else { return }
        updating = true
        defer { updating = false }
        let offset = host?.offset() ?? 0
        let y0 = offset - viewport.height * 0.5, y1 = offset + viewport.height * 1.5
        // Najpierw dokładny układ widocznych akapitów (może przesunąć treść — wtedy od nowa).
        for _ in 0..<3 {
            let first = layout.paragraph(atY: max(0, y0))
            var last = first
            while last + 1 < layout.count, layout.top(of: last + 1) < y1 { last += 1 }
            let range = first..<(last + 1)
            if range.allSatisfy(layout.isExact) { break }
            makeExact(range)
        }
        let offsetNow = host?.offset() ?? offset
        let top = offsetNow - viewport.height * 0.5, bottom = offsetNow + viewport.height * 1.5
        let first = layout.paragraph(atY: max(0, top))
        var wanted = Set<LineKey>()
        var p = first
        while p < layout.count, layout.top(of: p) < bottom {
            // Wysokość już dokładna, więc ponowny skład (po zwolnieniu pamięci) niczego nie przesuwa.
            if layout.isExact(p) {
                let paragraph = layout.layout(p).0
                let base = layout.top(of: p)
                for (index, line) in paragraph.lines.enumerated() where base + line.top + line.height >= top && base + line.top <= bottom {
                    wanted.insert(LineKey(paragraph: p, line: index))
                }
            }
            p += 1
        }
        let range = first..<p
        for (key, layer) in layers where !wanted.contains(key) {
            layer.removeFromSuperlayer()
            layer.line = nil
            pool.append(layer)
            layers[key] = nil
            for overlay in overlays[key]?.values ?? [:].values { overlay.removeFromSuperlayer() }
            overlays[key] = nil
        }
        for key in wanted where layers[key] == nil {
            guard let paragraph = layout.existingLayout(key.paragraph), let frame = frame(for: key) else { continue }
            let layer = pool.popLast() ?? TextLineLayer()
            layer.appearance = appearance
            layer.contentsScale = appearance.scale
            layer.line = paragraph.lines[key.line]
            layer.size = layout.style.size
            layer.only = nil
            layer.excluded = solid
            layer.frame = frame
            layer.setNeedsDisplay()
            redraws += 1
            container.addSublayer(layer)
            layers[key] = layer
            for run in paragraph.lines[key.line].runs where fader.weight(of: run.sentence) > 0 {
                setOverlay(key, sentence: run.sentence)
            }
        }
        if range != visibleRange {
            visibleRange = range
            // Pamięć: składy daleko od ekranu zwalniamy (dokładne wysokości zostają).
            layout.evict(keeping: max(0, range.lowerBound - 150)..<min(layout.count, range.upperBound + 150))
            host?.visibleChanged()
        }
    }

    /// Krycie nakładek zdań, których waga się zmieniła (tworzy brakujące, usuwa wygaszone).
    private func updateOverlays(sentences: Set<Int>) {
        guard let layout else { return }
        for sentence in sentences {
            guard let p = layout.document.paragraph(ofSentence: sentence), let paragraph = layout.existingLayout(p) else { continue }
            for index in paragraph.sentenceLines[sentence] ?? [] {
                let key = LineKey(paragraph: p, line: index)
                if layers[key] != nil { setOverlay(key, sentence: sentence) }
            }
        }
    }

    private func setOverlay(_ key: LineKey, sentence: Int) {
        guard let base = layers[key], let appearance else { return }
        let weight = fader.weight(of: sentence)
        if weight <= 0 {
            overlays[key]?[sentence]?.removeFromSuperlayer()
            overlays[key]?[sentence] = nil
            return
        }
        let overlay: TextLineLayer
        if let existing = overlays[key]?[sentence] {
            overlay = existing
        } else {
            overlay = TextLineLayer()
            overlay.appearance = appearance
            overlay.contentsScale = appearance.scale
            overlay.line = base.line
            overlay.size = base.size
            overlay.only = sentence
            overlay.frame = base.bounds
            if let glow = appearance.glow {
                overlay.shadowColor = glow.copy(alpha: 1)
                overlay.shadowOpacity = Float(glow.alpha)
                overlay.shadowRadius = appearance.glowRadius
                overlay.shadowOffset = .zero
            }
            overlay.setNeedsDisplay()
            redraws += 1
            base.addSublayer(overlay)
            overlays[key, default: [:]][sentence] = overlay
        }
        overlay.opacity = Float(HighlightFader.eased(weight) * coverage(sentence))
    }

    /// Krycie nakładki, gdy pod nią jest jeszcze przygaszone zdanie z warstwy bazowej: tak, by
    /// suma przy pełnej wadze równała się samej nakładce (bez skoku jasności, gdy warstwa bazowa
    /// przestaje rysować bieżące zdanie). Przy kolorze bez przezroczystości (iOS) — 1.
    private func coverage(_ sentence: Int) -> Double {
        guard let appearance, solid != sentence else { return 1 }
        let a = Double(appearance.ink.alpha), b = appearance.dimmed * a
        guard a > 0, b < 1 else { return 1 }
        return max(0, min(1, (a - b) / (a * (1 - b))))
    }

    /// Bieżące zdanie bez warstwy bazowej (`sentence`) albo z powrotem w niej (`nil`).
    private func setSolid(_ sentence: Int?) {
        let changed = [solid, sentence].compactMap { $0 }
        solid = sentence
        guard let layout else { return }
        defer { for item in changed { updateOverlays(sentences: [item]) } }
        for item in changed {
            guard let p = layout.document.paragraph(ofSentence: item), let paragraph = layout.existingLayout(p) else { continue }
            for index in paragraph.sentenceLines[item] ?? [] {
                guard let layer = layers[LineKey(paragraph: p, line: index)] else { continue }
                layer.excluded = sentence
                layer.setNeedsDisplay()
                redraws += 1
            }
        }
    }

    private func redrawAll() {
        for layer in layers.values { layer.setNeedsDisplay() }
        refreshOverlays()
    }

    private func refreshOverlays() {
        for (key, layer) in layers {
            for overlay in overlays[key]?.values ?? [:].values { overlay.removeFromSuperlayer() }
            overlays[key] = nil
            if let line = layer.line {
                for run in line.runs where fader.weight(of: run.sentence) > 0 { setOverlay(key, sentence: run.sentence) }
            }
        }
    }

    private func removeAllLayers() {
        for layer in layers.values { layer.removeFromSuperlayer() }
        layers.removeAll()
        overlays.removeAll()
        pool.removeAll()
        visibleRange = 0..<0
    }

    /// W czasie bez ruchu układa po trochu dalsze akapity (szacunek → dokładna wysokość), żeby
    /// pasek przewijania i ręczne przewijanie daleko trafiały w prawdziwe położenia.
    private func scheduleIdleLayout() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, !Task.isCancelled, !self.animating, let layout = self.layout else { return }
                guard layout.exactCount < layout.count else { return }
                let center = self.visibleRange.lowerBound
                var picked: [Int] = []
                var distance = 0
                while picked.count < 24, distance < layout.count {
                    for p in [center - distance, center + distance] where p >= 0 && p < layout.count && !layout.isExact(p) && !picked.contains(p) {
                        picked.append(p)
                    }
                    distance += 1
                }
                guard let low = picked.min(), let high = picked.max() else { return }
                self.makeExact(low..<(high + 1))
                let visible = self.visibleRange
                layout.evict(keeping: max(0, visible.lowerBound - 150)..<min(layout.count, visible.upperBound + 150))
            }
        }
    }

    // MARK: - Dotyk i dostępność

    /// Zdanie pod punktem treści.
    public func sentence(at point: CGPoint) -> Int? {
        layout?.sentence(at: point)
    }

    /// Zdania widocznych akapitów z prostokątami (współrzędne treści) — elementy VoiceOver.
    public func visibleSentences(margin: Int = 40) -> [(sentence: Int, frames: [CGRect])] {
        guard let layout, !visibleRange.isEmpty else { return [] }
        let lower = max(0, visibleRange.lowerBound - margin), upper = min(layout.count, visibleRange.upperBound + margin)
        makeExact(lower..<upper)
        var result: [(Int, [CGRect])] = []
        for p in lower..<upper {
            for sentence in layout.document.paragraphs[p].sentences {
                let frames = layout.frames(ofSentence: sentence)
                if !frames.isEmpty { result.append((sentence, frames)) }
            }
        }
        return result
    }

    deinit {
        MainActor.assumeIsolated {
            lineTask?.cancel()
            idleTask?.cancel()
        }
    }
}

/// Warstwa jednego wiersza: rysuje kawałki zdań z jasnością zależną od wagi zdania.
final class TextLineLayer: CALayer {
    var line: ParagraphLayout.Line?
    var appearance: TextFlowController.Appearance?
    var size: CGFloat = 17
    /// Nakładka jednego zdania w pełnej jasności; `nil` — cały wiersz przygaszony.
    var only: Int?
    /// Zdanie pominięte w warstwie bazowej (rysuje je nakładka).
    var excluded: Int?

    override init() {
        super.init()
        actions = TextFlowController.noActions
        anchorPoint = .zero
        isOpaque = false
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override func action(forKey event: String) -> (any CAAction)? { nil }

    override func draw(in ctx: CGContext) {
        guard let line, let appearance else { return }
        let pad = TextFlowController.pad
        ctx.saveGState()
        // Rysujemy w układzie „y w dół” niezależnie od platformy.
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        guard let ctLine = line.line else {
            // Przerwa rozdziału: trzy kropki pośrodku.
            ctx.setFillColor(appearance.ink.copy(alpha: 0.35) ?? appearance.ink)
            let gap = size * 0.6, dot: CGFloat = 4
            let total = 3 * dot + 2 * gap
            var x = bounds.width / 2 - total / 2
            for _ in 0..<3 {
                ctx.fillEllipse(in: CGRect(x: x, y: bounds.height / 2 - dot / 2, width: dot, height: dot))
                x += dot + gap
            }
            ctx.restoreGState()
            return
        }
        _ = ctLine
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setAllowsFontSmoothing(true)
        let alpha = only == nil ? appearance.dimmed * appearance.ink.alpha : appearance.ink.alpha
        ctx.setFillColor(appearance.ink.copy(alpha: alpha) ?? appearance.ink)
        for run in line.runs where only == nil ? run.sentence != excluded : run.sentence == only {
            ctx.textPosition = CGPoint(x: pad, y: pad + line.ascent)
            CTRunDraw(run.run, ctx, CFRange(location: 0, length: 0))
        }
        ctx.restoreGState()
    }
}
