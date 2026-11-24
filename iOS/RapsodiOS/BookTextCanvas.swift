// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 11d).

import AudiobookshelfKit
import AudiobookshelfPlayback
import SwiftUI
import UIKit

/// Tekst książki na iOS (etap 11d): `UIScrollView` z warstwami wierszy i ruchem ze wspólnego
/// `TextFlowController`. Tu tylko to, co zależy od UIKit: przewijanie palcem, zegar ekranu,
/// dotknięcie zdania i elementy VoiceOver (każde zdanie osobno, jak w 11b).
struct BookTextCanvas: UIViewRepresentable {
    let model: TextFollowModel
    let document: TextSyncDocument
    /// Odczytywane tu, żeby zmiana zdania, śledzenia albo prośba o przeskok wywołały `updateUIView`.
    let sentence: Int?
    let following: Bool
    let jump: Int
    let back: Int
    let size: CGFloat
    let serif: Bool
    let dimmed: Double
    let columnWidth: CGFloat
    let reduceMotion: Bool
    let onTap: (Int) -> Void

    func makeUIView(context: Context) -> TextCanvasScrollView {
        let view = TextCanvasScrollView()
        view.controller.model = model
        return view
    }

    func updateUIView(_ view: TextCanvasScrollView, context: Context) {
        view.onTap = onTap
        view.model = model
        view.controller.model = model
        view.configuration = .init(document: document, style: style(scale: view.traitCollection.displayScale), reduceMotion: reduceMotion, dimmed: dimmed, scale: view.traitCollection.displayScale)
        view.controller.sync()
    }

    private func style(scale: CGFloat) -> TextFlowStyle {
        func font(_ size: CGFloat, weight: UIFont.Weight = .regular, italic: Bool = false) -> CTFont {
            var descriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
            if serif, let serifDescriptor = descriptor.withDesign(.serif) { descriptor = serifDescriptor }
            if italic, let italicDescriptor = descriptor.withSymbolicTraits(.traitItalic) { descriptor = italicDescriptor }
            return UIFont(descriptor: descriptor, size: size) as CTFont
        }
        return TextFlowStyle(
            body: font(size), heading1: font(size * 1.45, weight: .semibold), heading: font(size * 1.22, weight: .semibold),
            quote: font(size * 0.95, italic: true), preformatted: UIFont.monospacedSystemFont(ofSize: size * 0.9, weight: .regular) as CTFont,
            size: size, columnWidth: columnWidth, horizontalPadding: 28,
            language: String(document.map.locale.prefix(2)), key: "\(size)|\(serif)|\(columnWidth)")
    }
}

final class TextCanvasScrollView: UIScrollView, UIScrollViewDelegate {
    struct Configuration {
        var document: TextSyncDocument
        var style: TextFlowStyle
        var reduceMotion: Bool
        var dimmed: Double
        var scale: CGFloat
    }

    let controller = TextFlowController()
    weak var model: TextFollowModel?
    var onTap: ((Int) -> Void)?
    var configuration: Configuration? { didSet { setNeedsLayout(); apply() } }
    private let content = TextCanvasContentView()
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = true
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        addSubview(content)
        content.canvas = self
        content.layer.addSublayer(controller.container)
        content.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        controller.host = .init(
            offset: { [weak self] in self?.contentOffset.y ?? 0 },
            setOffset: { [weak self] y in self?.contentOffset = CGPoint(x: 0, y: y) },
            setContentHeight: { [weak self] height in
                guard let self else { return }
                self.contentSize = CGSize(width: self.bounds.width, height: height)
                self.content.frame = CGRect(x: 0, y: 0, width: self.bounds.width, height: height)
            },
            setAnimating: { [weak self] on in self?.setAnimating(on) },
            visibleChanged: { [weak self] in self?.content.invalidateAccessibility() }
        )
        controller.host?.dissolve = { [weak self] in
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.2
            self?.layer.add(transition, forKey: "jump")
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        apply()
    }

    private func apply() {
        guard let configuration, bounds.width > 0, bounds.height > 0 else { return }
        let appearance = TextFlowController.Appearance(
            ink: UIColor.white.cgColor, dimmed: configuration.dimmed,
            glow: UIColor.white.withAlphaComponent(0.28).cgColor, glowRadius: 7,
            scale: configuration.scale, reduceMotion: configuration.reduceMotion)
        controller.configure(document: configuration.document, style: configuration.style, viewport: bounds.size, appearance: appearance)
    }

    // MARK: Zegar ekranu

    private func setAnimating(_ on: Bool) {
        if on, displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
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

    override func removeFromSuperview() {
        displayLink?.invalidate()
        displayLink = nil
        super.removeFromSuperview()
    }

    // MARK: Przewijanie

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // Przeciągnięcie palcem (nie przewijanie z kodu) wstrzymuje śledzenie.
        controller.userScrolled()
        model?.userDidScroll()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        controller.viewportScrolled()
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        if let sentence = controller.sentence(at: recognizer.location(in: content)) { onTap?(sentence) }
    }

    func activate(sentence: Int) { onTap?(sentence) }
}

/// Treść przewijania: warstwy wierszy i elementy VoiceOver (zdania widocznych akapitów).
final class TextCanvasContentView: UIView {
    weak var canvas: TextCanvasScrollView?
    private var elements: [UIAccessibilityElement]?

    func invalidateAccessibility() { elements = nil }

    override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    override var accessibilityElements: [Any]? {
        get {
            if let elements { return elements }
            guard let canvas, let model = canvas.model, let layout = canvas.controller.layout else { return [] }
            let built = canvas.controller.visibleSentences().map { item -> UIAccessibilityElement in
                let element = SentenceElement(accessibilityContainer: self)
                element.sentence = item.sentence
                element.canvas = canvas
                element.accessibilityLabel = layout.document.map.sentences[item.sentence].text
                element.accessibilityHint = "Odtwarza od tego zdania"
                var traits: UIAccessibilityTraits = .button
                if item.sentence == model.currentSentence { traits.insert(.selected) }
                if let p = layout.document.paragraph(ofSentence: item.sentence), layout.document.paragraphs[p].isHeading { traits.insert(.header) }
                element.accessibilityTraits = traits
                element.accessibilityFrameInContainerSpace = item.frames.dropFirst().reduce(item.frames[0]) { $0.union($1) }
                return element
            }
            elements = built
            return built
        }
        set {}
    }
}

private final class SentenceElement: UIAccessibilityElement {
    var sentence = 0
    weak var canvas: TextCanvasScrollView?

    override func accessibilityActivate() -> Bool {
        canvas?.activate(sentence: sentence)
        return true
    }
}
