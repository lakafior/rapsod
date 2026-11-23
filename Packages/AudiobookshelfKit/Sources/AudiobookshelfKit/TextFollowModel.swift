// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 11b).

import Foundation
import Observation

/// Stan trybu „Tekst” w odtwarzaczu — wspólny dla Maca i iOS, bez zależności od widoków
/// i od konkretnego odtwarzacza (Mac ma własny): wczytanie mapy, bieżące zdanie dla czasu
/// nagrania, śledzenie (automatyczne przewijanie) i okno akapitów do pokazania.
///
/// Widok podaje czas z odtwarzacza (`update`), a obserwuje tylko to, co się zmienia rzadko:
/// bieżące zdanie i akapit, okno, stan śledzenia. Zegar odtwarzacza tyka dwa razy na sekundę,
/// więc granicę zdania model wylicza sam i przełącza podświetlenie dokładnie na czas.
@MainActor
@Observable
public final class TextFollowModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        case unavailable(TextSyncUnavailable)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var document: TextSyncDocument?
    /// Mapa powstała z innych plików audio albo innego e-booka niż obecne.
    public private(set) var isStale = false
    /// Mapa z urządzenia, serwer niedostępny.
    public private(set) var isOffline = false
    public private(set) var currentSentence: Int?
    public private(set) var currentParagraph: Int?
    /// Automatyczne przewijanie za odtwarzaniem; ręczne przewinięcie je wstrzymuje.
    public private(set) var isFollowing = true
    /// Akapity pokazane w widoku (leniwe okno wokół bieżącego miejsca, nie cała książka).
    public private(set) var window: Range<Int> = 0..<0
    /// Rośnie, gdy widok ma przewinąć do bieżącego zdania.
    public private(set) var scrollRequest = 0
    /// Ostatnia prośba to daleki przeskok (przewinięcie bez animacji).
    public private(set) var scrollIsJump = false

    @ObservationIgnored private var key: String?
    @ObservationIgnored private var source: TextSyncSource?
    @ObservationIgnored private var cache: TextSyncCache?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var boundary: Task<Void, Never>?
    @ObservationIgnored private var lastTime: Double = 0
    @ObservationIgnored private var lastStamp = ContinuousClock.now
    @ObservationIgnored private var rate: Double = 1
    @ObservationIgnored private var isPlaying = false

    /// Akapity przed i za bieżącym w oknie.
    public static let windowBefore = 40
    public static let windowAfter = 80
    static let windowLimit = 800

    public init() {}

    // MARK: - Wczytanie

    /// Wczytuje mapę pozycji `key` (ten sam klucz — nic nie robi, chyba że poprzednio się nie udało).
    public func load(key: String, source: TextSyncSource, cache: TextSyncCache) {
        if key == self.key, phase == .ready || phase == .loading { return }
        // Inna książka: stary tekst znika od razu (ta sama, np. po nowej synchronizacji — zostaje do podmiany).
        if let old = self.key, old.split(separator: "#").first != key.split(separator: "#").first {
            document = nil
            currentSentence = nil
            currentParagraph = nil
            window = 0..<0
            isFollowing = true
        }
        self.key = key
        self.source = source
        self.cache = cache
        start()
    }

    /// Ponowne wczytanie (np. po synchronizacji na Macu albo po powrocie sieci).
    public func reload() {
        guard source != nil else { return }
        start()
    }

    private func start() {
        guard let source, let cache else { return }
        loadTask?.cancel()
        if document == nil { phase = .loading }
        let key = self.key
        loadTask = Task { [weak self] in
            let result = await TextSyncLoader.load(source, cache: cache)
            guard let self, !Task.isCancelled, self.key == key else { return }
            self.apply(result)
        }
    }

    /// Wynik wczytania (publiczne dla podglądów i testów).
    public func apply(_ result: TextSyncLoadResult) {
        switch result {
        case .ready(let document, let stale, let offline):
            let same = self.document?.map == document.map
            self.document = document
            isStale = stale
            isOffline = offline
            phase = .ready
            if !same {
                currentSentence = nil
                currentParagraph = nil
                recenter(on: nil)
                refresh(time: lastTime, force: true)
            }
        case .unavailable(let reason):
            if document == nil || reason != .offline { document = nil; phase = .unavailable(reason) }
        case .failed(let message):
            if document == nil { phase = .failed(message) }
        }
    }

    /// Zwolnienie przy zmianie książki.
    public func reset() {
        loadTask?.cancel()
        boundary?.cancel()
        key = nil
        source = nil
        document = nil
        phase = .idle
        currentSentence = nil
        currentParagraph = nil
        window = 0..<0
        isFollowing = true
    }

    // MARK: - Odtwarzanie

    /// Czas z odtwarzacza (sekundy w całej książce), prędkość i stan.
    public func update(time: Double, rate: Float, isPlaying: Bool) {
        let resumed = isPlaying && !self.isPlaying
        self.rate = max(0.25, Double(rate))
        self.isPlaying = isPlaying
        lastTime = time
        lastStamp = .now
        // Wznowienie odtwarzania przywraca śledzenie (jak po dotknięciu „Wróć do bieżącego miejsca”).
        if resumed, !isFollowing { resumeFollowing() }
        refresh(time: time, force: false)
        scheduleBoundary()
    }

    private func refresh(time: Double, force: Bool) {
        guard let document else { return }
        let sentence = document.sentence(at: time)
        guard sentence != currentSentence || force else { return }
        let oldParagraph = currentParagraph
        currentSentence = sentence
        currentParagraph = sentence.flatMap(document.paragraph(ofSentence:))
        let target = currentParagraph ?? 0
        if isFollowing {
            let far = oldParagraph.map { abs($0 - target) > 6 } ?? true
            if !window.contains(target) || target >= window.upperBound - 20 || target < window.lowerBound + 3 {
                recenter(on: target)
            }
            scrollIsJump = far
            scrollRequest += 1
        }
    }

    /// Zmiana podświetlenia na granicy zdania między tyknięciami zegara odtwarzacza.
    private func scheduleBoundary() {
        boundary?.cancel()
        boundary = nil
        guard isPlaying, let document, let next = document.nextStart(after: lastTime) else { return }
        let delay = (next - lastTime) / rate
        // Następne tyknięcie i tak przyjdzie za ok. 0,5 s — dalej nie planujemy.
        guard delay > 0, delay < 0.6 else { return }
        boundary = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay + 0.01))
            guard !Task.isCancelled, let self, self.isPlaying else { return }
            let elapsed = (ContinuousClock.now - self.lastStamp)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            self.refresh(time: self.lastTime + seconds * self.rate, force: false)
        }
    }

    // MARK: - Śledzenie i okno

    /// Użytkownik przewinął tekst sam — przestajemy przewijać za odtwarzaniem.
    public func userDidScroll() {
        guard isFollowing, document != nil else { return }
        isFollowing = false
    }

    /// „Wróć do bieżącego miejsca”.
    public func resumeFollowing() {
        isFollowing = true
        let target = currentParagraph ?? 0
        if !window.contains(target) || target >= window.upperBound - 20 || target < window.lowerBound + 3 {
            recenter(on: target)
        }
        scrollIsJump = false
        scrollRequest += 1
    }

    /// Widok doszedł do brzegu okna przy ręcznym przewijaniu — dokładamy akapity.
    public func reachedWindowEdge(top: Bool) {
        guard let document else { return }
        let n = document.paragraphs.count
        var lower = window.lowerBound, upper = window.upperBound
        if top {
            guard lower > 0 else { return }
            lower = max(0, lower - 60)
            if upper - lower > Self.windowLimit { upper = lower + Self.windowLimit }
        } else {
            guard upper < n else { return }
            upper = min(n, upper + 60)
            if upper - lower > Self.windowLimit { lower = upper - Self.windowLimit }
        }
        window = lower..<upper
    }

    private func recenter(on paragraph: Int?) {
        guard let document else { window = 0..<0; return }
        let n = document.paragraphs.count
        let p = min(max(0, paragraph ?? 0), max(0, n - 1))
        window = Self.window(around: p, count: n)
    }

    static func window(around p: Int, count n: Int) -> Range<Int> {
        let lower = max(0, p - windowBefore)
        let upper = min(n, max(p + windowAfter, lower + windowBefore + windowAfter))
        return max(0, min(lower, upper - windowBefore - windowAfter))..<upper
    }

    /// Czas, od którego odtwarzać po dotknięciu zdania; wraca też śledzenie.
    public func time(forSentence index: Int) -> Double? {
        guard let time = document?.startTime(ofSentence: index) else { return nil }
        isFollowing = true
        return time
    }

    /// Wartość podświetlenia dla akapitu: indeks bieżącego zdania ograniczony do zakresu akapitu
    /// (o jedno poza nim, gdy bieżące zdanie jest gdzie indziej) — widok animuje ją płynnie.
    public func highlight(for paragraph: TextSyncDocument.Paragraph) -> Double {
        guard let current = currentSentence else { return Double(paragraph.sentences.lowerBound - 1) }
        if current < paragraph.sentences.lowerBound { return Double(paragraph.sentences.lowerBound - 1) }
        if current >= paragraph.sentences.upperBound { return Double(paragraph.sentences.upperBound) }
        return Double(current)
    }
}
