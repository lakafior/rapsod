# Roadmapa

Stan na 2026-11-20. Wydana wersja: 1.0.0.

## Zrobione

1. Powłoka macOS: serwer audiobookshelf jako submodule, nadzór procesu, web UI w oknie.
2. Folder biblioteki z natywnego okna, start przy logowaniu, okno statusu z logiem.
3. Dostęp dla istniejących klientów: udostępnianie w sieci lokalnej, konto dla telefonu, sekcja „Połącz telefon”.
4. Opcjonalny Cloudflare Tunnel z tokenem.
5. Samodzielna paczka: wbudowany Node i ffmpeg, podpis Developer ID, notaryzacja, DMG.

Po 1.0.0: ikona aplikacji, usuwanie biblioteki z okna statusu.

## Zasoby i rozmiar

- **6a. Pamięć — zrobione.** Web UI i okno statusu zwalniane po zamknięciu: aplikacja w spoczynku 18–50 MB (wcześniej 26–56 MB), procesy WebKit po zamknięciu web UI 0 MB (wcześniej 158 MB). Największą pozycją zostaje serwer Node (64–97 MB).
- **6b. Agent w tle — odrzucone.** Przeniesienie nadzoru serwera do lekkiego procesu oszczędziłoby tylko 10–40 MB: tyle zostaje po aplikacji w spoczynku po 6a (18–50 MB), a samodzielny proces nadzorcy też zajmuje pamięć. Zysk niewart drugiego procesu, komunikacji między procesami i podwójnego podpisywania.
- **6c. Rozmiar paczki — zrobione (do sprawdzenia na podpisanym, notaryzowanym wydaniu).** Własny build Node (small-icu en+pl, bez inspektora i dołączonych narzędzi): 122 → 62 MB. ffmpeg i ffprobe tylko z potrzebnymi składnikami, we wspólnych bibliotekach: 45 → 9 MB. `abs-server` bez zbędnych kopii pakietów: 51 → 43 MB. Zawartość `Server` 210 → 111 MB, aplikacja ok. 215 → 115 MB, DMG ok. 75 → 40 MB (szacunek z obrazu samego `Server`). Do tego `NODE_OPTIONS=--max-semi-space-size=1`: Node w spoczynku 99 → 63 MB, po skanie 1200 pozycji 314 → 238 MB, skan ok. 5% dłuższy.

## Źródła metadanych

### Wbudowane źródła metadanych — zrobione

LubimyCzytać, Audioteka, Storytel i Audible jako jedno opcjonalne źródło w oknie dopasowywania książki, bez osobnego kontenera i ręcznej konfiguracji serwera.

- **Kod:** agregator [aio-abs-providers](https://github.com/lakafior/aio-abs-providers) (GPL-3.0) jako drugi submodule przypięty do commita. Aktualizacja źródeł to przesunięcie przypięcia i nowe wydanie aplikacji.
- **Uruchamianie na żądanie:** aplikacja nasłuchuje na stałym porcie pętli zwrotnej i budzi agregator przy pierwszym zapytaniu (start ok. 0,3 s), a po 5 minutach bezczynności go wyłącza. W spoczynku nie zajmuje pamięci.
- **Rejestracja:** aplikacja sama dodaje i usuwa wpis dostawcy w audiobookshelf oraz ustawia go raz jako domyślne źródło bibliotek z książkami.
- **Konfiguracja i wyszukiwarka:** strony agregatora pokazywane w oknie aplikacji.
- **Do sprawdzenia przed publikacją:** źródła pobierają dane ze stron serwisów, więc trzeba przejrzeć ich regulaminy pod kątem dystrybucji w publicznej aplikacji.

## Planowane

### Bardziej natywna aplikacja

- Angielska wersja językowa (dziś interfejs jest tylko po polsku).
- Okno Ustawień pod ⌘, z zakładkami zamiast jednego okna statusu.
- Integracja z systemem: powiadomienie po zakończeniu skanu, akcje dla Skrótów, upuszczenie folderu na ikonę w pasku menu.
- Automatyczne aktualizacje (Sparkle).
- Natywna biblioteka i odtwarzacz w SwiftUI — osobna, duża decyzja.

## Poza zakresem

- Własny klient iOS (używamy istniejących klientów audiobookshelf).
- Parowanie przez iCloud i Bonjour.
- Odtwarzanie mechanizmów Tailscale/WireGuard w aplikacji; dostęp spoza domu pozostaje opcjonalny i niezależny od dostawcy.
