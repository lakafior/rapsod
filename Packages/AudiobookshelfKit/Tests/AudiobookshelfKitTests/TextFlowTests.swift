// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreText
import Foundation
import Testing
@testable import AudiobookshelfKit
@testable import AudiobookshelfPlayback

/// Ruch trybu „Tekst” (etap 11d): sprężyna przewijania, wybór wiersza, przejście jasności, układ.
@Suite struct TextFlowTests {
    // MARK: - Sprężyna

    /// Przebieg kroku o `distance` przy 60 Hz: pozycje klatka po klatce.
    static func run(_ follower: inout ScrollFollower, frames: Int) -> [Double] {
        var positions: [Double] = []
        for _ in 0..<frames { follower.step(1.0 / 60); positions.append(follower.position) }
        return positions
    }

    @Test func followerStepIsSmoothWithoutOvershoot() {
        var follower = ScrollFollower(position: 0)
        follower.target = 34   // jeden wiersz
        let p = Self.run(&follower, frames: 120)
        // Łagodny początek: pierwsza klatka prawie w miejscu, potem stały wzrost bez cofania się.
        #expect(p[0] < 0.3)
        #expect(zip(p, p.dropFirst()).allSatisfy { $1 >= $0 - 0.0001 })
        #expect(p.max()! <= 34.0001)
        // Bez szarpnięcia: największy krok na klatkę mały, zmiana prędkości między klatkami też.
        let steps = zip(p, p.dropFirst()).map { $1 - $0 }
        #expect(steps.max()! < 2.5)
        let jerks = zip(steps, steps.dropFirst()).map { abs($1 - $0) }
        #expect(jerks.max()! < 0.35)
        // Dochodzi w czasie poniżej sekundy (ok. 0,8 s) i stoi.
        let reached = p.firstIndex { abs($0 - 34) < 0.5 }!
        print("dojście po klatkach:", reached, "maks. krok", steps.max()!, "maks. zmiana", jerks.max()!)
        #expect(reached > 30 && reached < 60)
        #expect(follower.isSettled)
    }

    @Test func followerRetargetKeepsVelocity() {
        var follower = ScrollFollower(position: 0)
        follower.target = 34
        var p = Self.run(&follower, frames: 20)
        // Następny wiersz, zanim skończył się ruch: prędkość się nie zrywa ani nie odwraca.
        follower.target = 68
        p += Self.run(&follower, frames: 100)
        let steps = zip(p, p.dropFirst()).map { $1 - $0 }
        #expect(steps.allSatisfy { $0 >= -0.0001 })
        let jerks = zip(steps, steps.dropFirst()).map { abs($1 - $0) }
        #expect(jerks.max()! < 0.35)
        #expect(abs(p.last! - 68) < 0.5)
    }

    @Test func followerShiftAndSnap() {
        var follower = ScrollFollower(position: 100)
        follower.target = 140
        _ = Self.run(&follower, frames: 10)
        let before = follower.target - follower.position
        follower.shift(by: -50)
        #expect(abs((follower.target - follower.position) - before) < 0.0001)
        follower.snap(to: 10)
        #expect(follower.position == 10 && follower.isSettled)
    }

    // MARK: - Wiersz lektora

    static let lines = [
        FollowPlanner.Line(top: 100, height: 30, from: 0, to: 0.3),
        FollowPlanner.Line(top: 142, height: 30, from: 0.3, to: 0.8),
        FollowPlanner.Line(top: 184, height: 30, from: 0.8, to: 1),
    ]

    @Test func plannerPicksSpokenLine() {
        let span = 10.0...20.0
        #expect(FollowPlanner.spokenFraction(time: 12, span: span) == 0.2)
        #expect(FollowPlanner.lineIndex(fraction: 0, in: Self.lines) == 0)
        #expect(FollowPlanner.lineIndex(fraction: 0.29, in: Self.lines) == 0)
        #expect(FollowPlanner.lineIndex(fraction: 0.3, in: Self.lines) == 1)
        #expect(FollowPlanner.lineIndex(fraction: 0.95, in: Self.lines) == 2)
        #expect(FollowPlanner.nextLineTime(after: 11, span: span, lines: Self.lines) == 13)
        #expect(FollowPlanner.nextLineTime(after: 13.5, span: span, lines: Self.lines) == 18)
        #expect(FollowPlanner.nextLineTime(after: 19, span: span, lines: Self.lines) == nil)
        // Wiersz na linii czytania (30% wysokości) i w granicach przewijania.
        #expect(FollowPlanner.offset(for: Self.lines[1], viewport: 400, range: 0...1000) == 22)
        #expect(FollowPlanner.offset(for: Self.lines[0], viewport: 400, range: 0...1000) == 0)
        #expect(FollowPlanner.shouldAnimate(from: 0, to: 500, viewport: 400, reduceMotion: false))
        #expect(!FollowPlanner.shouldAnimate(from: 0, to: 700, viewport: 400, reduceMotion: false))
        #expect(!FollowPlanner.shouldAnimate(from: 0, to: 10, viewport: 400, reduceMotion: true))
        #expect(FollowPlanner.shouldAnimateJump(from: 0, to: 200, viewport: 400, reduceMotion: false))
        #expect(FollowPlanner.shouldAnimateJump(from: 0, to: -100, viewport: 400, reduceMotion: false))
        #expect(!FollowPlanner.shouldAnimateJump(from: 0, to: 300, viewport: 400, reduceMotion: false))
        #expect(!FollowPlanner.shouldAnimateJump(from: 0, to: -200, viewport: 400, reduceMotion: false))
    }

    // MARK: - Jasność

    @Test func faderCrossfadesWithinDuration() {
        var fader = HighlightFader(duration: 0.45)
        fader.setCurrent(3, instant: true)
        #expect(fader.weight(of: 3) == 1)
        fader.setCurrent(4, instant: false)
        var changed = Set<Int>()
        var t = 0.0
        while fader.isAnimating, t < 2 { changed.formUnion(fader.step(1.0 / 60)); t += 1.0 / 60 }
        #expect(changed == [3, 4])
        #expect(abs(t - 0.45) < 0.05)
        #expect(fader.weight(of: 4) == 1 && fader.weight(of: 3) == 0)
        #expect(HighlightFader.eased(0.5) == 0.5)
    }

    // MARK: - Układ

    static func style(width: CGFloat = 400) -> TextFlowStyle {
        let font = CTFontCreateWithName("Times New Roman" as CFString, 18, nil)
        return TextFlowStyle(body: font, heading1: CTFontCreateWithName("Times New Roman" as CFString, 26, nil), heading: CTFontCreateWithName("Times New Roman" as CFString, 22, nil),
                             quote: font, preformatted: font, size: 18, columnWidth: width, horizontalPadding: 20, language: "pl", key: "t")
    }

    static func document() -> TextSyncDocument {
        var sentences: [TextSyncMap.Sentence] = []
        for block in 0..<200 {
            let count = block % 5 == 0 ? 1 : 3
            for k in 0..<count {
                let long = String(repeating: "słowo ", count: (block * 7 + k * 3) % 40 + 2)
                sentences.append(TextSyncDocumentTests.sentence("Zdanie \(block)-\(k) \(long)koniec.", href: block < 100 ? "a.xhtml" : "b.xhtml", block: block, Double(sentences.count) * 3, Double(sentences.count) * 3 + 2.5))
            }
        }
        return TextSyncDocument(map: TextSyncDocumentTests.map(sentences, blocks: [.init(href: "a.xhtml", block: 0, kind: "h1")]))
    }

    @Test func layoutIsExactAndStable() {
        let doc = Self.document()
        let layout = TextFlowLayout(document: doc, style: Self.style(), width: 440, topInset: 120, bottomInset: 240)
        #expect(layout.top(of: 0) == 120)
        let estimatedTop = layout.top(of: 150)
        // Dokładny układ akapitu nad 150 zmienia jego górę o dokładnie różnicę wysokości.
        let (_, delta) = layout.layout(10)
        #expect(abs(layout.top(of: 150) - (estimatedTop + delta)) < 0.001)
        // Drugie ułożenie nic nie zmienia.
        #expect(layout.layout(10).delta == 0)
        // Wiersze zdania: kolejno w dół, udziały od 0 do 1, w kolumnie.
        let sentence = doc.paragraphs[12].sentences.lowerBound + 2
        let lines = layout.lines(ofSentence: sentence)
        #expect(!lines.isEmpty)
        #expect(lines.first!.from == 0 && abs(lines.last!.to - 1) < 0.0001)
        #expect(zip(lines, lines.dropFirst()).allSatisfy { $1.top > $0.top })
        #expect(lines.allSatisfy { $0.top >= layout.top(of: 12) && $0.top < layout.top(of: 13) })
        // Wszystkie akapity ułożone: suma wysokości i odstępów = wysokość treści.
        for p in 0..<layout.count { layout.layout(p) }
        var y: CGFloat = 120
        for p in 0..<layout.count { #expect(abs(layout.top(of: p) - y) < 0.01); y += layout.height(of: p) + (p + 1 < layout.count ? 18 * 0.85 : 0) }
        #expect(abs(layout.contentHeight - (y + 240)) < 0.01, "\(layout.contentHeight) \(y + 240) \(layout.top(of: layout.count))")
        // Dotknięcie środka wiersza trafia w zdanie tego wiersza.
        let frame = layout.frames(ofSentence: sentence)[0]
        #expect(layout.sentence(at: CGPoint(x: frame.midX, y: frame.midY)) == sentence)
        // Przerwa rozdziału przed pierwszym akapitem pliku b.xhtml.
        #expect(layout.existingLayout(100)!.lines.first!.line == nil)
    }
}
