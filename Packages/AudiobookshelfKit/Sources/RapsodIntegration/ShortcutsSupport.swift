// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 14e).

import Foundation

/// Kolejność wyników wyszukiwania dla Skrótów (wybór książki, podcastu, odcinka). Serwer zwraca
/// wyniki z kilku bibliotek osobno i bez wspólnej kolejności; tu najlepsze dopasowanie tytułu
/// trafia na górę, potem autor, a reszta (np. dopasowanie po lektorze) zostaje w kolejności serwera.
public enum MediaSearchRanking {
    public struct Candidate: Equatable, Sendable {
        public var id: String
        public var title: String
        public var author: String?

        public init(id: String, title: String, author: String?) {
            self.id = id
            self.title = title
            self.author = author
        }
    }

    public static func rank(_ candidates: [Candidate], query: String) -> [Candidate] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return unique(candidates) }
        let scored = unique(candidates).enumerated().map { index, candidate in
            (candidate, score(candidate, needle), index)
        }
        return scored.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0)
    }

    /// 0 — ten sam tytuł, 1 — tytuł zaczyna się od zapytania, 2 — któreś słowo tytułu,
    /// 3 — tytuł zawiera, 4 — autor zawiera, 5 — reszta.
    static func score(_ candidate: Candidate, _ needle: String) -> Int {
        let title = normalize(candidate.title)
        if title == needle { return 0 }
        if title.hasPrefix(needle) { return 1 }
        if title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(needle) }) { return 2 }
        if title.contains(needle) { return 3 }
        if let author = candidate.author.map(normalize), author.contains(needle) { return 4 }
        return 5
    }

    /// Bez wielkości liter i znaków diakrytycznych („Łódź” = „lodz”), bez skrajnych spacji.
    public static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "pl"))
            .replacingOccurrences(of: "ł", with: "l")
    }

    private static func unique(_ candidates: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.id).inserted }
    }
}

/// Odcinek do odtworzenia z powiadomienia o pobraniu: zdarzenie serwera nie niesie identyfikatora
/// odcinka, tylko `guid` z kanału i tytuł.
public enum EpisodeLookup {
    public struct Episode: Equatable, Sendable {
        public var id: String
        public var guid: String?
        public var title: String?

        public init(id: String, guid: String?, title: String?) {
            self.id = id
            self.guid = guid
            self.title = title
        }
    }

    public static func find(in episodes: [Episode], guid: String?, title: String?) -> String? {
        if let guid, !guid.isEmpty, let match = episodes.first(where: { $0.guid == guid }) { return match.id }
        if let title = title.map(MediaSearchRanking.normalize), !title.isEmpty {
            return episodes.last(where: { $0.title.map(MediaSearchRanking.normalize) == title })?.id
        }
        return nil
    }
}

/// Przeskok w odtwarzaczu ze Skrótów: liczba sekund z parametru albo domyślna, w rozsądnych granicach.
public enum SkipInterval {
    public static let range: ClosedRange<Double> = 1...3600

    public static func seconds(_ requested: Double?, default fallback: Double) -> Double {
        guard let requested, requested.isFinite, requested > 0 else { return fallback }
        return min(max(requested, range.lowerBound), range.upperBound)
    }
}

/// Czekanie na gotowość serwera, gdy Skrót uruchomił aplikację: serwer startuje kilka sekund,
/// więc akcja czeka, dopóki trwa start, ale nie dłużej niż `limit`.
public enum ReadinessWait {
    public enum State: Equatable, Sendable {
        case ready
        /// Serwer startuje albo konto się łączy — warto poczekać.
        case starting
        /// Nie ma na co czekać (serwer zatrzymany, błąd, brak konta słuchacza).
        case unavailable
    }

    /// Czeka, aż `state()` zwróci coś innego niż `.starting` albo minie `limit` sekund.
    public static func wait(limit: Double = 30, step: Double = 0.25, state: () async -> State) async -> State {
        var waited = 0.0
        while true {
            let current = await state()
            if current != .starting || waited >= limit { return current }
            try? await Task.sleep(for: .seconds(step))
            waited += step
            if Task.isCancelled { return await state() }
        }
    }
}
