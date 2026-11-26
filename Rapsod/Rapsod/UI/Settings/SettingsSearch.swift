import Foundation

/// Wyszukiwanie w oknie „Ustawienia” (część 7 planu `docs/ustawienia-nowy-uklad.md`): pole na pasku
/// bocznym znajduje ustawienia po nazwie, po słowach kluczowych i po dawnych nazwach stron
/// („Udostępnianie”, „Konta”, „Aktywność”, „Sparuj”…), żeby stare wskazówki (np. w starszej wersji
/// aplikacji na iPhonie) dalej prowadziły do właściwego miejsca.
struct SettingsSearchEntry: Identifiable {
    enum Target {
        case page(SettingsPage)
        /// Strona z rozwiniętym „Zaawansowane” (tylko strony, które to obsługują: Biblioteki, Dostęp zdalny).
        case advanced(SettingsPage)
        case subpage(SettingsDestination)
    }

    let title: String
    /// Gdzie to jest, np. „Dostęp zdalny › Zaawansowane”.
    let path: String
    let terms: [String]
    let target: Target

    var id: String { path + "|" + title }

    static let all: [SettingsSearchEntry] = [
        // Ogólne
        .init(title: "Stan serwera, uruchom i zatrzymaj", path: "Ogólne › Serwer",
              terms: ["serwer", "uruchom", "zatrzymaj", "restart", "port", "błąd startu", "adres na tym macu"], target: .page(.general)),
        .init(title: "Dziennik serwera", path: "Ogólne › Dziennik serwera",
              terms: ["log", "log serwera", "dziennik", "kopiuj log"], target: .subpage(.serverLog)),
        .init(title: "Uruchamiaj przy logowaniu", path: "Ogólne › Aplikacja",
              terms: ["logowaniu", "start", "autostart"], target: .page(.general)),
        .init(title: "„Podłącz telefon…” w menu na pasku menu", path: "Ogólne › Aplikacja",
              terms: ["pasek menu", "menu", "skrót"], target: .page(.general)),
        .init(title: "Sprawdzaj aktualizacje automatycznie", path: "Ogólne › Aplikacja",
              terms: ["aktualizacje", "aktualizacja", "nowa wersja", "github", "sprawdź teraz"], target: .page(.general)),
        .init(title: "Web UI audiobookshelf", path: "Ogólne › Web UI",
              terms: ["web ui", "przeglądarka", "zarządzanie serwerem", "root", "strona www"], target: .page(.general)),
        .init(title: "Fragmenty sponsorowane w podcastach", path: "Ogólne › Fragmenty sponsorowane",
              terms: ["sponsor", "reklama", "reklamy", "autopromocja", "pomijaj", "model językowy", "llm", "openai", "mistral", "gemini", "klucz api modelu", "transkrypcja", "zgoda"],
              target: .subpage(.sponsorDetection)),
        .init(title: "Wersja, folder danych, poziom logu, język serwera", path: "Ogólne › Zaawansowane",
              terms: ["wersja", "audiobookshelf", "folder danych", "poziom logu", "język", "ustawienia serwera"], target: .page(.general)),
        // Użytkownicy
        .init(title: "Osoby i ich konta", path: "Użytkownicy",
              terms: ["konta", "konto", "osoba", "użytkownik", "dodaj osobę", "hasło", "zmień hasło", "awatar", "rola", "administrator", "gość", "uprawnienia", "dostęp do bibliotek", "tagi", "usuń konto", "słucha teraz"],
              target: .page(.users)),
        .init(title: "Telefony: podłącz, odłącz, kod z adresami", path: "Użytkownicy › profil osoby › Telefony",
              terms: ["telefon", "iphone", "sparuj", "parowanie", "podłącz telefon", "odłącz", "qr", "aplikacja na telefonie"], target: .page(.users)),
        .init(title: "Administrator serwera (root)", path: "Użytkownicy › Administrator serwera",
              terms: ["root", "hasło roota", "reset hasła", "zaloguj ponownie", "konta"], target: .subpage(.root)),
        .init(title: "Historia słuchania wszystkich", path: "Użytkownicy › Historia słuchania",
              terms: ["aktywność", "sesje", "sesja", "historia", "kto słucha", "otwarte sesje"], target: .subpage(.history(userID: nil))),
        // Biblioteki
        .init(title: "Biblioteki: dodawanie, skan, kolejność", path: "Biblioteki",
              terms: ["biblioteka", "skanuj", "skan", "pełny skan", "dopasuj wszystkie", "folder", "dodaj audiobooki", "dodaj podcasty", "podcast", "audiobook", "kolejność", "harmonogram skanu", "usuń bibliotekę"],
              target: .page(.libraries)),
        .init(title: "Metadane: polskie źródła i własni dostawcy", path: "Biblioteki › Metadane",
              terms: ["metadane", "źródła metadanych", "lubimyczytać", "audioteka", "storytel", "audible", "dostawca", "własny dostawca"], target: .page(.libraries)),
        .init(title: "Skaner, okładki, sortowanie, pamięć podręczna", path: "Biblioteki › Zaawansowane",
              terms: ["skaner", "okładki", "okładka", "obserwuj foldery", "obserwator", "metadata.json", "sortowanie", "przedrostki", "pamięć podręczna", "cache", "wyczyść", "ustawienia serwera"],
              target: .advanced(.libraries)),
        // Dostęp zdalny
        .init(title: "Sieć domowa i dostęp spoza domu", path: "Dostęp zdalny",
              terms: ["udostępnianie", "sieć domowa", "sieć lokalna", "wifi", "adres", "spoza domu", "własny adres", "vpn", "tailscale", "skąd można słuchać"], target: .page(.sharing)),
        .init(title: "Cloudflare Tunnel", path: "Dostęp zdalny › Spoza domu",
              terms: ["cloudflare", "tunel", "token tunelu"], target: .page(.sharing)),
        .init(title: "Kod z adresami dla telefonów", path: "Dostęp zdalny",
              terms: ["kod z adresami", "adresy na telefonach", "zmiana adresu"], target: .page(.sharing)),
        .init(title: "Klucze API, logowanie (SSO, OpenID), kanały RSS, log tunelu", path: "Dostęp zdalny › Zaawansowane",
              terms: ["klucz api", "klucze", "api", "sso", "openid", "logowanie", "rss", "kanał", "kanały", "dostęp", "log tunelu"],
              target: .advanced(.sharing)),
        // Powiadomienia
        .init(title: "Powiadomienia (Apprise)", path: "Powiadomienia",
              terms: ["powiadomienia", "apprise", "discord", "telegram", "ntfy", "nowe powiadomienie", "powiadomienia i e-mail"], target: .page(.notifications)),
        .init(title: "E-mail na czytniki i serwer poczty (SMTP)", path: "Powiadomienia",
              terms: ["e-mail", "email", "smtp", "poczta", "kindle", "czytnik", "czytniki", "wyślij na czytnik"], target: .page(.notifications)),
        // Kopie zapasowe
        .init(title: "Kopie zapasowe", path: "Kopie zapasowe",
              terms: ["kopia", "kopie", "backup", "przywróć", "wgraj z pliku", "automatyczne kopie", "folder kopii", "limit rozmiaru"], target: .page(.backups)),
    ]

    /// Wpisy pasujące do zapytania: każde słowo zapytania musi wystąpić w tytule, ścieżce albo słowach kluczowych
    /// (bez znaczenia wielkość liter i polskie znaki).
    static func results(for query: String) -> [SettingsSearchEntry] {
        let words = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return all.filter { entry in
            let haystack = normalized(([entry.title, entry.path] + entry.terms).joined(separator: " "))
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
    }
}

extension SettingsNavigation {
    /// Przechodzi do miejsca znalezionego w wyszukiwaniu.
    func open(_ target: SettingsSearchEntry.Target) {
        switch target {
        case .page(let page):
            self.page = page
            path = []
        case .advanced(let page):
            // Strona czyta `pendingAdvanced` przy pojawieniu się, a gdy już jest widoczna — przy jego zmianie.
            pendingAdvanced = page
            self.page = page
            path = []
        case .subpage(let destination):
            show(destination)
        }
    }
}
