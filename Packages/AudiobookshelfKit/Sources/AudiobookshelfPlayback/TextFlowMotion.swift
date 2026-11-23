// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 11d).

import Foundation

/// Ruch przewijania w trybie „Tekst” (etap 11d): jedna ciągła, sterowana klatka po klatce
/// pozycja, która podąża za celem bez przeskoków.
///
/// Dwa stopnie: cel najpierw wygładzany (opóźnienie pierwszego rzędu), potem tłumiona krytycznie
/// sprężyna dochodzi do wygładzonego celu. Ruch zaczyna się z zerowym przyspieszeniem, nie
/// przestrzeliwuje i — co najważniejsze — zmiana celu w trakcie ruchu (kolejny wiersz, zanim
/// skończył się poprzedni ruch) tylko łagodnie go wydłuża: prędkość się nie zrywa.
public struct ScrollFollower: Sendable, Equatable {
    public private(set) var position: Double
    public private(set) var velocity: Double = 0
    /// Wygładzony cel, do którego dochodzi sprężyna.
    public private(set) var smoothed: Double
    public var target: Double

    /// Sztywność sprężyny (rad/s) i stała czasowa wygładzania celu (s). Domyślne: krok o jeden
    /// wiersz trwa ok. 0,8 s, z łagodnym początkiem i końcem.
    public var stiffness: Double
    public var smoothing: Double

    public init(position: Double, stiffness: Double = 9, smoothing: Double = 0.12) {
        self.position = position
        self.smoothed = position
        self.target = position
        self.stiffness = stiffness
        self.smoothing = smoothing
    }

    /// Ruch zakończony (poniżej pół punktu i prawie bez prędkości).
    public var isSettled: Bool {
        abs(target - position) < 0.5 && abs(target - smoothed) < 0.5 && abs(velocity) < 2
    }

    /// Krok symulacji o `dt` sekund (dzielony na małe kroki — stabilnie także przy 30 Hz).
    public mutating func step(_ dt: Double) {
        guard dt > 0 else { return }
        if isSettled {
            position = target; smoothed = target; velocity = 0
            return
        }
        var left = min(dt, 0.1)
        while left > 0 {
            let h = min(left, 1.0 / 240)
            smoothed += (target - smoothed) * (1 - exp(-h / smoothing))
            let w = stiffness
            let acceleration = w * w * (smoothed - position) - 2 * w * velocity
            velocity += acceleration * h
            position += velocity * h
            left -= h
        }
    }

    /// Natychmiast w miejscu (przeskok, „Ogranicz ruch”).
    public mutating func snap(to value: Double) {
        position = value; smoothed = value; target = value; velocity = 0
    }

    /// Przesunięcie całego układu współrzędnych (np. dokładna wysokość akapitu nad ekranem
    /// zastąpiła szacunek) — ruch trwa dalej, tylko w nowych współrzędnych.
    public mutating func shift(by delta: Double) {
        position += delta; smoothed += delta; target += delta
    }

    /// Przejęcie bieżącej pozycji z zewnątrz (np. użytkownik przewinął) bez ruchu.
    public mutating func adopt(_ value: Double) {
        snap(to: value)
    }
}

/// Decyzje śledzenia, wspólne dla Maca i iOS: który wiersz bieżącego zdania jest czytany,
/// gdzie ma stać i czy dojechać płynnie, czy przeskoczyć.
public enum FollowPlanner {
    /// Bieżące zdanie stoi tyle od góry widocznej części tekstu.
    public static let readingLine = 0.3

    /// Wiersz zdania z udziałem w jego długości (część znaków zdania w tym wierszu).
    public struct Line: Sendable, Equatable {
        public var top: Double
        public var height: Double
        /// Początek i koniec wiersza jako ułamek długości zdania (0…1).
        public var from: Double
        public var to: Double
        public init(top: Double, height: Double, from: Double, to: Double) {
            self.top = top; self.height = height; self.from = from; self.to = to
        }
    }

    /// Ułamek zdania już przeczytany w chwili `time` (liniowo po czasie; mowa jest mniej
    /// więcej proporcjonalna do liczby znaków).
    public static func spokenFraction(time: Double, span: ClosedRange<Double>?) -> Double {
        guard let span, span.upperBound > span.lowerBound else { return 0 }
        return min(1, max(0, (time - span.lowerBound) / (span.upperBound - span.lowerBound)))
    }

    /// Wiersz, w którym jest lektor. Nowy wiersz zaczyna się, gdy lektor do niego dojdzie.
    public static func lineIndex(fraction: Double, in lines: [Line]) -> Int? {
        guard !lines.isEmpty else { return nil }
        return lines.lastIndex { $0.from <= fraction + 0.0001 } ?? 0
    }

    /// Czas (na osi nagrania), w którym lektor zacznie następny wiersz zdania — do zaplanowania
    /// kolejnego kroku przewijania bez ciągłego odpytywania.
    public static func nextLineTime(after time: Double, span: ClosedRange<Double>?, lines: [Line]) -> Double? {
        guard let span, span.upperBound > span.lowerBound else { return nil }
        let fraction = spokenFraction(time: time, span: span)
        guard let next = lines.first(where: { $0.from > fraction + 0.0001 }) else { return nil }
        return span.lowerBound + next.from * (span.upperBound - span.lowerBound)
    }

    /// Przesunięcie przewijania, przy którym wiersz `line` stoi na linii czytania.
    public static func offset(for line: Line, viewport: Double, range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, line.top - viewport * readingLine))
    }

    /// Dojazd płynny tylko wtedy, gdy cel jest blisko — dalej tekst ustawia się od razu
    /// (śledzenie oczami ponad półtora ekranu tekstu i tak traci sens, a długa animacja to szum).
    public static func shouldAnimate(from current: Double, to target: Double, viewport: Double, reduceMotion: Bool) -> Bool {
        !reduceMotion && abs(target - current) <= viewport * 1.5
    }

    /// Przeskok (suwak, rozdział, dotknięcie zdania) dojeżdża płynnie tylko wtedy, gdy wiersz
    /// docelowy już jest na ekranie — wzrok może go śledzić. Inaczej tekst staje od razu w miejscu.
    public static func shouldAnimateJump(from current: Double, to target: Double, viewport: Double, reduceMotion: Bool) -> Bool {
        let delta = target - current
        return !reduceMotion && delta >= -viewport * readingLine && delta <= viewport * (1 - readingLine) * 0.9
    }
}

/// Przejście jasności zdań: każde zdanie ma wagę 0…1 (1 — bieżące), która płynnie dochodzi
/// do celu. Zmienia się tylko kolor tekstu, układ zostaje ten sam.
public struct HighlightFader: Sendable {
    public private(set) var weights: [Int: Double] = [:]
    public private(set) var current: Int?
    /// Czas przejścia (s) — przy „Ogranicz ruch” krótszy.
    public var duration: Double

    public init(duration: Double = 0.45) {
        self.duration = duration
    }

    public func weight(of sentence: Int) -> Double { weights[sentence] ?? 0 }

    public var isAnimating: Bool {
        weights.contains { key, value in key == current ? value < 1 : value > 0 }
    }

    /// Nowe bieżące zdanie; `instant` — bez przejścia (pierwsze pokazanie, przeskok).
    public mutating func setCurrent(_ sentence: Int?, instant: Bool) {
        current = sentence
        if instant {
            weights = sentence.map { [$0: 1] } ?? [:]
        } else if let sentence, weights[sentence] == nil {
            weights[sentence] = 0
        }
    }

    /// Krok przejścia; zwraca zdania, których waga się zmieniła (do przerysowania).
    public mutating func step(_ dt: Double) -> Set<Int> {
        var changed = Set<Int>()
        let delta = duration <= 0 ? 1 : dt / duration
        for (key, value) in weights {
            let goal: Double = key == current ? 1 : 0
            let next = goal > value ? min(goal, value + delta) : max(goal, value - delta)
            guard next != value else { continue }
            changed.insert(key)
            if next == 0, key != current { weights[key] = nil } else { weights[key] = next }
        }
        return changed
    }

    /// Wygładzenie (ease-in-out) liniowej wagi do rysowania.
    public static func eased(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }
}
