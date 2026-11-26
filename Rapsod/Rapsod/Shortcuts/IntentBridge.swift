import AppIntents
import AudiobookshelfKit
import Foundation
import RapsodIntegration

/// Dostęp akcji Skrótów (etap 14e) do aplikacji. Akcje działają w procesie aplikacji — gdy Skrót
/// ją uruchamia, czekają chwilę, aż serwer wstanie i konto się połączy, a potem kończą się
/// czytelnym błędem zamiast wisieć.
@MainActor
enum IntentBridge {
    /// Ustawiane w `AppDelegate.init` — zanim system wykona pierwszą akcję.
    static weak var app: AppDelegate?
    /// Start aplikacji: przez pierwsze sekundy zatrzymany serwer znaczy „zaraz wystartuje”.
    static var launchDate = Date.now

    enum Requirement {
        /// Konto tego Maca do słuchania (odtwarzanie, wyszukiwanie, okno Biblioteka).
        case listener
        /// Konto root (skan, dodanie podcastu).
        case admin
    }

    /// Aplikacja gotowa do akcji albo błąd z wyjaśnieniem.
    static func ready(_ requirement: Requirement) async throws -> AppDelegate {
        var waited = 0.0
        while app == nil, waited < 10 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
        guard let app else { throw IntentError.appNotReady }
        let outcome = await ReadinessWait.wait(limit: 30) { state(app, requirement) }
        switch outcome {
        case .ready: return app
        case .starting: throw IntentError.stillStarting
        case .unavailable: throw failure(app, requirement)
        }
    }

    private static func state(_ app: AppDelegate, _ requirement: Requirement) -> ReadinessWait.State {
        let launching = Date.now.timeIntervalSince(launchDate) < 15
        switch app.supervisor.state {
        case .failed: return .unavailable
        case .stopped: return launching ? .starting : .unavailable
        case .starting: return .starting
        case .stopping: return .unavailable
        case .running: break
        }
        switch requirement {
        case .admin:
            switch app.account.state {
            case .ready: return .ready
            case .disconnected, .connecting: return .starting
            case .needsPassword, .failed: return .unavailable
            }
        case .listener:
            if app.listening.availability == .ready { return .ready }
            switch app.account.state {
            case .disconnected, .connecting: return .starting
            case .needsPassword, .failed: return .unavailable
            case .ready:
                if case .missing = app.account.userState { return .unavailable }
                return .starting
            }
        }
    }

    private static func failure(_ app: AppDelegate, _ requirement: Requirement) -> IntentError {
        switch app.supervisor.state {
        case .failed(let message): return .serverFailed(message)
        case .stopped, .stopping: return .serverStopped
        case .starting, .running: break
        }
        if case .needsPassword = app.account.state { return .adminUnavailable }
        if case .failed = app.account.state { return .adminUnavailable }
        return requirement == .admin ? .adminUnavailable : .noListener
    }

    // MARK: Wyszukiwanie

    /// Pozycje z bibliotek danego typu pasujące do zapytania (wyszukiwanie serwera, kolejność według tytułu).
    static func search(_ text: String, podcasts: Bool) async throws -> [AudiobookshelfClient.LibraryItem] {
        let app = try await ready(.listener)
        var found: [AudiobookshelfClient.LibraryItem] = []
        for library in app.listening.libraries where (library.mediaType == "podcast") == podcasts {
            let results = try await app.listening.api { try await $0.search(libraryID: library.id, query: text, token: $1) }
            found += ((podcasts ? results.podcast : results.book)?.elements ?? []).map(\.libraryItem)
        }
        return rank(found, query: text)
    }

    /// Odcinki pasujące do zapytania (tytuł odcinka albo podcastu).
    static func searchEpisodes(_ text: String) async throws -> [EpisodeEntity] {
        let app = try await ready(.listener)
        var found: [EpisodeEntity] = []
        for library in app.listening.libraries where library.mediaType == "podcast" {
            let results = try await app.listening.api { try await $0.search(libraryID: library.id, query: text, token: $1) }
            found += (results.episodes?.elements ?? []).compactMap { hit in
                hit.libraryItem.recentEpisode.map { EpisodeEntity(item: hit.libraryItem, episode: $0) }
            }
            // Podcast pasujący nazwą: jego najnowsze odcinki.
            for hit in (results.podcast?.elements ?? []).prefix(3) {
                if let item = try? await app.listening.api({ try await $0.item(id: hit.libraryItem.id, token: $1) }) {
                    found += (item.media.episodes?.elements ?? []).sorted { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) }
                        .prefix(10).map { EpisodeEntity(podcast: item, episode: $0) }
                }
            }
        }
        let ranked = MediaSearchRanking.rank(found.map { .init(id: $0.id, title: $0.title, author: $0.podcastTitle) }, query: text)
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ranked.compactMap { byID[$0.id] }
    }

    static func rank(_ items: [AudiobookshelfClient.LibraryItem], query: String) -> [AudiobookshelfClient.LibraryItem] {
        let ranked = MediaSearchRanking.rank(items.map { .init(id: $0.id, title: $0.title, author: $0.author) }, query: query)
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ranked.compactMap { byID[$0.id] }
    }

    /// Pozycje po identyfikatorach (zapisane w Skrócie). Usunięte z serwera po cichu pomija.
    static func items(_ ids: [String]) async throws -> [AudiobookshelfClient.ItemDetail] {
        let app = try await ready(.listener)
        var result: [AudiobookshelfClient.ItemDetail] = []
        for id in ids {
            if let item = try? await app.listening.api({ try await $0.item(id: id, token: $1) }) { result.append(item) }
        }
        return result
    }

    /// Zaczęte pozycje (propozycje w Skrótach): książki albo podcasty z odcinkiem.
    static func inProgress() async throws -> [AudiobookshelfClient.LibraryItem] {
        let app = try await ready(.listener)
        return try await app.listening.api { try await $0.itemsInProgress(token: $1) }
    }

    /// Pierwsze pozycje bibliotek danego typu według tytułu (propozycje, gdy nic nie jest zaczęte).
    static func firstItems(podcasts: Bool, limit: Int = 30) async throws -> [AudiobookshelfClient.LibraryItem] {
        let app = try await ready(.listener)
        var result: [AudiobookshelfClient.LibraryItem] = []
        for library in app.listening.libraries where (library.mediaType == "podcast") == podcasts {
            let page = try await app.listening.api {
                try await $0.itemsPage(libraryID: library.id, page: 0, limit: limit, sort: "media.metadata.title", descending: false, filter: nil, token: $1)
            }
            result += page.results.elements
        }
        return result
    }
}

/// Błędy akcji Skrótów — tekst trafia do okna Skrótów, więc mówi, co zrobić.
enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case stillStarting
    case serverStopped
    case serverFailed(String)
    case noListener
    case adminUnavailable
    case notFound
    case nothingToResume
    case nothingPlaying
    case noPodcastLibrary
    case playbackFailed(String)
    case podcastExists(String)
    case failed(String)
    case noFiles

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady: "Rapsod jeszcze się uruchamia. Spróbuj za chwilę."
        case .stillStarting: "Serwer Rapsodu jeszcze startuje. Spróbuj za chwilę."
        case .serverStopped: "Serwer Rapsodu jest zatrzymany. Uruchom go z menu Rapsodu na pasku menu."
        case .serverFailed(let message): "Serwer Rapsodu nie wystartował: \(message)"
        case .noListener: "Rapsod nie ma jeszcze konta do słuchania. Utwórz je w oknie Biblioteka albo w Ustawieniach › Użytkownicy."
        case .adminUnavailable: "Konto administratora serwera nie jest połączone. Podaj jego hasło w Ustawieniach › Użytkownicy › Administrator serwera."
        case .notFound: "Nie ma tej pozycji na serwerze — mogła zostać usunięta."
        case .nothingToResume: "Nie ma niczego do kontynuowania — żadna książka ani odcinek nie są zaczęte."
        case .nothingPlaying: "Nic nie jest teraz wczytane w odtwarzaczu."
        case .noPodcastLibrary: "Serwer nie ma biblioteki podcastów. Dodaj ją w Ustawieniach › Biblioteki."
        case .playbackFailed(let message): "Nie udało się odtworzyć: \(message)"
        case .podcastExists(let title): "Podcast „\(title)” już jest w bibliotece."
        case .failed(let message): "\(message)"
        case .noFiles: "Nie podano plików do wgrania."
        }
    }
}
