// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 14e).

import Foundation

/// Miejsce w aplikacji, do którego prowadzi kliknięcie powiadomienia (i przycisk „Odtwarzaj”).
/// Zapisywane w `userInfo` powiadomienia jako tekst JSON, bo powiadomienie przeżywa aplikację.
public enum NotificationRoute: Codable, Equatable, Sendable {
    /// Strona książki albo podcastu w oknie „Biblioteka”.
    case item(itemID: String, libraryID: String?)
    /// Odcinek podcastu. `episodeID` bywa nieznany (zdarzenie pobierania go nie niesie) — wtedy
    /// aplikacja szuka odcinka po `guid` albo tytule, a w ostateczności otwiera stronę podcastu.
    case episode(itemID: String, libraryID: String?, episodeID: String?, guid: String?, title: String?)
    /// Podstrona biblioteki w Ustawieniach (wynik skanu).
    case librarySettings(libraryID: String)
    /// Okno „Biblioteka” na tej bibliotece (wgrane książki).
    case library(libraryID: String?)
    /// Okno aktualizacji.
    case update(version: String)

    public static let userInfoKey = "rapsodRoute"

    public var userInfoValue: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    public init?(userInfoValue: Any?) {
        guard let text = userInfoValue as? String, let data = text.data(using: .utf8),
              let route = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = route
    }
}

/// Gotowe powiadomienie, niezależne od `UserNotifications` (aplikacja zamienia je na `UNNotificationRequest`).
public struct NotificationContent: Equatable, Sendable {
    /// Identyfikator żądania: to samo zdarzenie (np. późniejszy wynik tego samego skanu) zastępuje
    /// wcześniejsze powiadomienie zamiast dokładać drugie.
    public var identifier: String
    public var kind: NotificationKind
    public var title: String
    public var subtitle: String?
    public var body: String
    /// Wątek w Centrum powiadomień (grupowanie): biblioteka, podcast, aktualizacje.
    public var threadIdentifier: String
    public var route: NotificationRoute?

    public init(identifier: String, kind: NotificationKind, title: String, subtitle: String? = nil, body: String,
                threadIdentifier: String, route: NotificationRoute?) {
        self.identifier = identifier
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.threadIdentifier = threadIdentifier
        self.route = route
    }
}

/// Liczba mnoga po polsku: „1 odcinek”, „2 odcinki”, „5 odcinków”, „22 odcinki”, „12 odcinków”.
public enum PolishPlural {
    public static func form(_ count: Int, one: String, few: String, many: String) -> String {
        let n = abs(count)
        if n == 1 { return one }
        let lastTwo = n % 100, last = n % 10
        if (2...4).contains(last), !(12...14).contains(lastTwo) { return few }
        return many
    }

    public static func count(_ count: Int, one: String, few: String, many: String) -> String {
        "\(count) " + form(count, one: one, few: few, many: many)
    }
}

// MARK: - Treści

public enum NotificationTexts {
    /// Wynik skanu biblioteki. `nil`, gdy nie warto powiadamiać (zob. `ScanNotificationPolicy`).
    public static func scan(libraryID: String, libraryName: String, outcome: ScanOutcome, requestedHere: Bool) -> NotificationContent? {
        guard ScanNotificationPolicy.shouldNotify(outcome, requestedHere: requestedHere) else { return nil }
        let title: String
        let body: String
        switch outcome {
        case .failed(let message):
            title = "Skan nie powiódł się"
            body = message
        case .finished(let counts, _):
            title = "Skan zakończony"
            body = counts.map(scanSummary) ?? "Skan biblioteki zakończony."
        }
        return NotificationContent(identifier: "scan-\(libraryID)", kind: .libraryScan, title: title, subtitle: libraryName,
                                   body: body, threadIdentifier: "library-\(libraryID)", route: .librarySettings(libraryID: libraryID))
    }

    /// „Dodano 3 pozycje, zmieniono 1, brakuje 2.” albo „Bez zmian.”
    public static func scanSummary(_ counts: ScanCounts) -> String {
        var parts: [String] = []
        var nounUsed = false
        func noun(_ n: Int) -> String {
            defer { nounUsed = true }
            return nounUsed ? "\(n)" : PolishPlural.count(n, one: "pozycję", few: "pozycje", many: "pozycji")
        }
        if counts.added > 0 { parts.append("dodano \(noun(counts.added))") }
        if counts.updated > 0 { parts.append("zmieniono \(noun(counts.updated))") }
        if counts.missing > 0 {
            // „brakuje 1 pozycji” — dopełniacz po „brakuje” (jak „pozycji” przy 5).
            let text = nounUsed ? "\(counts.missing)" : PolishPlural.count(counts.missing, one: "pozycji", few: "pozycji", many: "pozycji")
            parts.append("brakuje \(text)")
        }
        guard !parts.isEmpty else { return "Bez zmian." }
        let sentence = parts.joined(separator: ", ") + "."
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    /// Nowe odcinki jednego podcastu (pobrane razem w krótkim czasie).
    public static func episodes(_ batch: EpisodeBatch) -> NotificationContent {
        let titles = batch.episodes.map(\.title)
        let body: String
        if titles.count == 1 {
            body = titles[0]
        } else {
            let heading = PolishPlural.count(titles.count, one: "nowy odcinek", few: "nowe odcinki", many: "nowych odcinków")
            body = heading + ": " + titles.prefix(3).joined(separator: ", ") + (titles.count > 3 ? "…" : "")
        }
        let newest = batch.episodes.last
        return NotificationContent(
            identifier: "episodes-\(batch.itemID)-\(newest?.downloadID ?? "")",
            kind: .newEpisodes,
            title: titles.count == 1 ? "Nowy odcinek" : "Nowe odcinki",
            subtitle: batch.podcastTitle,
            body: body,
            threadIdentifier: "podcast-\(batch.itemID)",
            route: .episode(itemID: batch.itemID, libraryID: batch.libraryID, episodeID: nil, guid: newest?.guid, title: newest?.title))
    }

    /// Koniec wgrywania z okna „Biblioteka”.
    public static func upload(libraryID: String, libraryName: String, uploadedTitles: [String], failures: Int) -> NotificationContent? {
        let uploaded = uploadedTitles.count
        guard uploaded + failures > 0 else { return nil }
        let title: String
        var body: String
        if uploaded == 0 {
            title = "Wgrywanie nie powiodło się"
            body = failures == 1 ? "Nie udało się wgrać książki." : "Nie udało się wgrać \(PolishPlural.count(failures, one: "książki", few: "książek", many: "książek"))."
        } else {
            title = failures == 0 ? "Wgrywanie zakończone" : "Wgrywanie zakończone z błędami"
            body = uploaded == 1 ? "Wgrano „\(uploadedTitles[0])”." : "Wgrano \(PolishPlural.count(uploaded, one: "książkę", few: "książki", many: "książek"))."
            if failures > 0 {
                body += " " + (failures == 1 ? "Jednej nie udało się wgrać." : "Nie udało się wgrać: \(failures).")
            }
        }
        return NotificationContent(identifier: "upload-\(libraryID)", kind: .uploads, title: title, subtitle: libraryName, body: body,
                                   threadIdentifier: "library-\(libraryID)", route: .library(libraryID: libraryID))
    }

    /// Koniec scalania do M4B. `failure` — opis błędu.
    public static func merge(itemID: String, libraryID: String?, itemTitle: String?, failure: String?) -> NotificationContent {
        NotificationContent(
            identifier: "merge-\(itemID)",
            kind: .uploads,
            title: failure == nil ? "Scalono do M4B" : "Scalanie do M4B nie powiodło się",
            subtitle: itemTitle,
            body: failure ?? "Książka ma teraz jeden plik M4B z rozdziałami.",
            threadIdentifier: libraryID.map { "library-\($0)" } ?? "merge",
            route: .item(itemID: itemID, libraryID: libraryID))
    }

    public static func update(version: String, title: String?) -> NotificationContent {
        let name = (title?.isEmpty == false ? title : nil) ?? "Rapsod \(version)"
        return NotificationContent(identifier: "update-\(version)", kind: .appUpdate, title: "Dostępna aktualizacja",
                                   subtitle: name, body: "Kliknij, żeby zobaczyć, co nowego, albo zainstaluj od razu.",
                                   threadIdentifier: "updates", route: .update(version: version))
    }

    public static func sponsorSegments(itemID: String, libraryID: String?, episodeID: String, podcastTitle: String?,
                                       episodeTitle: String?, count: Int) -> NotificationContent {
        let segments = PolishPlural.count(count, one: "segment sponsorowany", few: "segmenty sponsorowane", many: "segmentów sponsorowanych")
        let where_ = episodeTitle.map { " w odcinku „\($0)”" } ?? ""
        return NotificationContent(
            identifier: "sponsor-\(itemID)-\(episodeID)",
            kind: .sponsorSegments,
            title: "Wykryto \(segments)",
            subtitle: podcastTitle,
            body: "Znaleziono je\(where_); odtwarzanie postąpi z nimi zgodnie z ustawieniami.",
            threadIdentifier: "podcast-\(itemID)",
            route: .episode(itemID: itemID, libraryID: libraryID, episodeID: episodeID, guid: nil, title: episodeTitle))
    }
}
