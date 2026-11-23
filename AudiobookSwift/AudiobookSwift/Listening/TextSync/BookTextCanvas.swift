// Pochodzenie: kod własny projektu (etap 11d). Odpowiednik `iOS/AudiobookSwiftiOS/BookTextCanvas.swift`
// dla AppKit; skład, warstwy i ruch są we wspólnym `TextFlowController` (pakiet).

import AppKit
import AudiobookshelfKit
import AudiobookshelfPlayback
import SwiftUI

/// Tekst książki na Macu: `NSScrollView` z warstwami wierszy i ruchem ze wspólnego kontrolera.
/// Tu tylko przewijanie (kółko, gładzik, pasek), zegar ekranu, kliknięcie zdania, kursor
/// i elementy VoiceOver.
struct BookTextCanvas: NSViewRepresentable {
    let model: TextFollowModel
    let document: TextSyncDocument
    /// Odczytywane tu, żeby zmiana zdania, śledzenia albo prośba o przeskok wywołały `updateNSView`.
    let sentence: Int?
    let following: Bool
    let jump: Int
    let back: Int
    let size: CGFloat
    let serif: Bool
    let dimmed: Double
    let glow: Bool
    let columnWidth: CGFloat
    let reduceMotion: Bool
    let onTap: (Int) -> Void

    func makeNSView(context: Context) -> TextCanvasScrollView {
        let view = TextCanvasScrollView()
        view.controller.model = model
        return view
    }

    func updateNSView(_ view: TextCanvasScrollView, context: Context) {
        view.onTap = onTap
        view.model = model
        view.controller.model = model
        view.configuration = .init(document: document, style: style, reduceMotion: reduceMotion, dimmed: dimmed, glow: glow)
        view.controller.sync()
    }

    private var style: TextFlowStyle {
        func font(_ size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> CTFont {
            var descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
            if serif, let serifDescriptor = descriptor.withDesign(.serif) { descriptor = serifDescriptor }
            if italic { descriptor = descriptor.withSymbolicTraits(.italic) }
            return (NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)) as CTFont
        }
        return TextFlowStyle(
            body: font(size), heading1: font(size * 1.45, weight: .semibold), heading: font(size * 1.22, weight: .semibold),
            quote: font(size * 0.95, italic: true), preformatted: NSFont.monospacedSystemFont(ofSize: size * 0.9, weight: .regular) as CTFont,
            size: size, columnWidth: columnWidth, horizontalPadding: 20,
            language: String(document.map.locale.prefix(2)), key: "\(size)|\(serif)|\(columnWidth)")
    }
}

final class TextCanvasScrollView: NSScrollView {
    struct Configuration {
        var document: TextSyncDocument
        var style: TextFlowStyle
        var reduceMotion: Bool
        var dimmed: Double
        var glow: Bool
    }

    let controller = TextFlowController()
    weak var model: TextFollowModel?
    var onTap: ((Int) -> Void)?
    var configuration: Configuration? { didSet { apply() } }
    private let content = TextCanvasDocumentView()
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    /// Przesunięcie ustawiane z kodu — powiadomienia o przewinięciu nie są wtedy ruchem użytkownika.
    private var settingOffset = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        documentView = content
        content.canvas = self
        content.layer = CALayer()
        content.wantsLayer = true
        content.layer?.isGeometryFlipped = true
        content.layer?.addSublayer(controller.container)
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: self)
        controller.host = .init(
            offset: { [weak self] in self?.contentView.bounds.origin.y ?? 0 },
            setOffset: { [weak self] y in self?.setOffset(y) },
            setContentHeight: { [weak self] height in
                guard let self else { return }
                self.content.frame = NSRect(x: 0, y: 0, width: self.contentSize.width, height: max(height, self.contentSize.height))
            },
            setAnimating: { [weak self] on in self?.setAnimating(on) },
            visibleChanged: { [weak self] in self?.content.invalidateAccessibility() }
        )
        controller.host?.dissolve = { [weak self] in
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.2
            self?.layer?.add(transition, forKey: "jump")
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        apply()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        apply()
    }

    private func apply() {
        guard let configuration, contentSize.width > 0, contentSize.height > 0 else { return }
        var ink = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { ink = NSColor.labelColor.cgColor }
        let appearance = TextFlowController.Appearance(
            ink: ink, dimmed: configuration.dimmed,
            glow: configuration.glow ? NSColor.white.withAlphaComponent(0.22).cgColor : nil, glowRadius: 6,
            scale: window?.backingScaleFactor ?? 2, reduceMotion: configuration.reduceMotion)
        controller.configure(document: configuration.document, style: configuration.style, viewport: contentSize, appearance: appearance)
    }

    private func setOffset(_ y: CGFloat) {
        settingOffset = true
        contentView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
        settingOffset = false
    }

    // MARK: Zegar ekranu

    private func setAnimating(_ on: Bool) {
        if on, displayLink == nil {
            let link = displayLink(target: self, selector: #selector(frameTick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastFrame = 0
        } else if !on {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        let dt = lastFrame == 0 ? 1.0 / 60 : link.targetTimestamp - lastFrame
        lastFrame = link.targetTimestamp
        controller.tick(min(max(dt, 1.0 / 240), 0.1))
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { displayLink?.invalidate(); displayLink = nil }
    }

    // MARK: Przewijanie

    override func scrollWheel(with event: NSEvent) {
        // Kółko myszy albo gładzik (nie przewijanie z kodu) wstrzymuje śledzenie.
        userScrolled()
        super.scrollWheel(with: event)
    }

    @objc private func liveScrollStarted() {
        userScrolled()
    }

    private func userScrolled() {
        guard model?.isFollowing == true else { return }
        controller.userScrolled()
        model?.userDidScroll()
    }

    @objc private func boundsChanged() {
        controller.viewportScrolled()
        if !settingOffset { window?.invalidateCursorRects(for: content) }
    }

    func click(at point: NSPoint) {
        if let sentence = controller.sentence(at: point) { onTap?(sentence) }
    }

    func activate(sentence: Int) { onTap?(sentence) }
}

/// Treść przewijania: warstwy wierszy, kliknięcie zdania, kursor i elementy VoiceOver.
final class TextCanvasDocumentView: NSView {
    weak var canvas: TextCanvasScrollView?
    private var elements: [SentenceElement]?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Kliknij zdanie, żeby słuchać od niego"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 1 else { return }
        canvas?.click(at: convert(event.locationInWindow, from: nil))
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .pointingHand)
    }

    func invalidateAccessibility() { elements = nil }

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? { "Tekst książki" }

    override func accessibilityChildren() -> [Any]? {
        if let elements { return elements }
        guard let canvas, let model = canvas.model, let layout = canvas.controller.layout else { return [] }
        let built = canvas.controller.visibleSentences().map { item -> SentenceElement in
            let element = SentenceElement()
            element.sentence = item.sentence
            element.canvas = canvas
            element.view = self
            element.rect = item.frames.dropFirst().reduce(item.frames[0]) { $0.union($1) }
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(layout.document.map.sentences[item.sentence].text)
            element.setAccessibilityHelp("Odtwarza od tego zdania")
            element.setAccessibilitySelected(item.sentence == model.currentSentence)
            if let p = layout.document.paragraph(ofSentence: item.sentence), layout.document.paragraphs[p].isHeading {
                element.setAccessibilityRoleDescription("nagłówek")
            }
            return element
        }
        elements = built
        return built
    }
}

final class SentenceElement: NSAccessibilityElement {
    var sentence = 0
    var rect: NSRect = .zero
    weak var canvas: TextCanvasScrollView?
    weak var view: NSView?

    override func accessibilityFrame() -> NSRect {
        guard let view, let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(rect, to: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        canvas?.activate(sentence: sentence)
        return true
    }
}
