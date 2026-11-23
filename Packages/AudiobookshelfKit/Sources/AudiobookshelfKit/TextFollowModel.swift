// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 11b).

import Foundation
import Observation

/// Stan trybu „Tekst” w odtwarzaczu — wspólny dla Maca i iOS, bez zależności od widoków
/// i od konkretnego odtwarzacza: wczytanie mapy, bieżące zdanie dla czasu nagrania i stan
/// śledzenia (automatycznego przewijania).
///
/// Widok podaje czas z odtwarzacza (`update`), a obserwuje tylko to, co zmienia się rzadko:
/// bieżące zdanie, stan śledzenia i prośby o przeskok. Zegar odtwarzacza tyka dwa razy na
/// sekundę, więc granice zdań model wylicza sam (łańcuchem, także kilka krótkich zdań między
/// tyknięciami) i nie cofa podświetlenia, gdy tyknięcie przyjdzie odrobinę „za wcześnie”.
/// Czas między tyknięciami (`estimatedTime`) widok bierze do śledzenia wiersza w zdaniu.
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
    /// Rośnie przy nieciągłości czasu (przewinięcie suwaka, rozdział, dotknięcie zdania,
    /// pierwsze pokazanie): widok ustawia tekst od razu w nowym miejscu, zamiast czekać na wiersz.
    public private(set) var jumpRequest = 0
    /// Rośnie przy „Wróć do bieżącego miejsca” (także po wznowieniu odtwarzania).
    public private(set) var returnRequest = 0
    public private(set) var isPlaying = false
    public private(set) var rate: Double = 1

    @ObservationIgnored private var key: String?
    @ObservationIgnored private var source: TextSyncSource?
    @ObservationIgnored private var cache: TextSyncCache?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var boundary: Task<Void, Never>?
    @ObservationIgnored private var lastTime: Double = 0
    @ObservationIgnored private var lastStamp = ContinuousClock.now
    /// Początek zdania, na które model przełączył się sam między tyknięciami — tyknięcie
    /// z czasem tuż sprzed niego nie cofa podświetlenia.
    @ObservationIgnored private var floor: Double?

    /// Nieciągłość czasu większa niż to (s) to przeskok, nie zwykłe tykanie zegara.
    static let jumpThreshold = 1.5
    /// Najwyżej tyle (s) tyknięcie może „cofnąć się” za przewidziany początek zdania.
    static let jitter = 0.6
    /// Najdalsza ekstrapolacja czasu bez tyknięcia (s czasu rzeczywistego).
    static let maxExtrapolation = 0.6

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
                floor = nil
                refresh(time: lastTime, jump: true)
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
        floor = nil
        isFollowing = true
    }

    // MARK: - Odtwarzanie

    /// Czas nagrania teraz, między tyknięciami zegara odtwarzacza (przy pauzie — ostatni podany).
    public func estimatedTime(at now: ContinuousClock.Instant = .now) -> Double {
        guard isPlaying else { return lastTime }
        let elapsed = now - lastStamp
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        // Najwyżej trochę ponad jeden odstęp tyknięć (0,5 s): gdy zegar przestaje tykać (czekanie
        // na dane, ładowanie pliku), podświetlenie nie ucieka naprzód, żeby potem wracać.
        return lastTime + min(seconds, Self.maxExtrapolation) * rate
    }

    /// Czas z odtwarzacza (sekundy w całej książce), prędkość i stan.
    public func update(time: Double, rate: Float, isPlaying: Bool) {
        let resumed = isPlaying && !self.isPlaying
        let expected = estimatedTime()
        let jump = abs(time - expected) > (self.isPlaying ? Self.jumpThreshold : 0.3)
        let newRate = max(0.25, Double(rate))
        if newRate != self.rate { self.rate = newRate }
        if isPlaying != self.isPlaying { self.isPlaying = isPlaying }
        lastTime = time
        lastStamp = .now
        var effective = time
        if jump {
            floor = nil
        } else if let floor {
            // Tyknięcie odrobinę przed przewidzianą granicą zdania — zostajemy przy nowym zdaniu.
            if time < floor, floor - time < Self.jitter { effective = floor } else { self.floor = nil }
        }
        // Wznowienie odtwarzania przywraca śledzenie (jak po dotknięciu „Wróć do bieżącego miejsca”).
        if resumed, !isFollowing { resumeFollowing() }
        refresh(time: effective, jump: jump)
        scheduleBoundary()
    }

    private func refresh(time: Double, jump: Bool) {
        guard let document else { return }
        let sentence = document.sentence(at: time)
        if sentence != currentSentence {
            currentSentence = sentence
            currentParagraph = sentence.flatMap(document.paragraph(ofSentence:))
        }
        if jump, isFollowing { jumpRequest += 1 }
    }

    /// Zmiana podświetlenia na granicy zdania między tyknięciami zegara odtwarzacza; po każdej
    /// granicy planowana jest następna, więc kilka krótkich zdań w pół sekundy przechodzi na czas.
    private func scheduleBoundary() {
        boundary?.cancel()
        boundary = nil
        guard isPlaying, let document else { return }
        let now = estimatedTime()
        guard let next = document.nextStart(after: now) else { return }
        let delay = (next - now) / rate
        // Następne tyknięcie i tak przyjdzie za ok. 0,5 s — dalej nie planujemy.
        guard delay < 0.6 else { return }
        boundary = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay) + 0.005))
            guard !Task.isCancelled, let self, self.isPlaying else { return }
            // Zegar odtwarzacza stanął (ekstrapolacja doszła do granicy) — czekamy na tyknięcie.
            let now = self.estimatedTime()
            guard now >= next - 0.02 else { return }
            self.refresh(time: max(next, now), jump: false)
            // Dolna granica to początek zdania, na którym model faktycznie stanął (przy spóźnionym
            // wybudzeniu mogło to być kilka zdań dalej niż zaplanowana granica).
            self.floor = self.currentSentence.flatMap { document.map.sentences[$0].start } ?? next
            self.scheduleBoundary()
        }
    }

    // MARK: - Śledzenie

    /// Użytkownik przewinął tekst sam — przestajemy przewijać za odtwarzaniem.
    public func userDidScroll() {
        guard isFollowing, document != nil else { return }
        isFollowing = false
    }

    /// „Wróć do bieżącego miejsca”.
    public func resumeFollowing() {
        isFollowing = true
        returnRequest += 1
    }

    /// Czas, od którego odtwarzać po dotknięciu zdania; wraca też śledzenie.
    public func time(forSentence index: Int) -> Double? {
        guard let time = document?.startTime(ofSentence: index) else { return nil }
        isFollowing = true
        return time
    }

    /// Czas trwania zdania na osi nagrania (początek — początek następnego zdania z czasem,
    /// gdy mapa nie ma końca), do śledzenia wiersza, w którym jest lektor.
    public func span(ofSentence index: Int) -> ClosedRange<Double>? {
        guard let document, document.map.sentences.indices.contains(index), let start = document.map.sentences[index].start else { return nil }
        // Do końca zdania z mapy; gdy go nie ma — do początku następnego zdania.
        let end = document.map.sentences[index].end ?? document.nextStart(after: start) ?? start
        return start...max(start, end)
    }
}
