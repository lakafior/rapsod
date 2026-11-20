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

## Planowane

### Wbudowane źródła metadanych

Polskie źródła metadanych dostępne bez osobnego kontenera i ręcznej konfiguracji: LubimyCzytać, Audioteka, Storytel (oraz Audible z tego samego agregatora).

- **Źródło kodu:** [aio-abs-providers](https://github.com/lakafior/aio-abs-providers) (GPL-3.0) — jeden serwer Node łączący wszystkie źródła, z rankingiem i scalaniem wyników. Zastępuje osobne `lubimyczytac-abs`, `audioteka-abs` i `abs-storytel-provider`. Dołączany jako drugi submodule przypięty do commita, tak jak upstream.
- **Rejestracja w serwerze:** aplikacja dodaje dostawcę przez `POST /api/custom-metadata-providers` z adresem na pętli zwrotnej i usuwa go po wyłączeniu funkcji. Upstream odpytuje wtedy `GET <adres>/search`.
- **Opcjonalne:** domyślnie wyłączone, z przełącznikiem i ustawieniami w aplikacji (które źródła, język, scalanie wyników) zamiast strony `/admin` agregatora.
- **Do rozstrzygnięcia: jak go uruchamiać.**
  - osobny proces Node — najprostsze i odizolowane, ale ok. 50 MB pamięci przez cały czas;
  - wewnątrz procesu serwera (`node --require`, jak `parent-watch.js`) — bez dodatkowego procesu, ale błąd w dostawcy może wyłączyć serwer;
  - na żądanie — aplikacja nasłuchuje na porcie dostawcy i uruchamia go przy pierwszym zapytaniu, a wyłącza po bezczynności. Zerowy koszt w spoczynku, najwięcej pracy.
- **Do sprawdzenia przed wydaniem:** źródła pobierają dane ze stron serwisów, więc trzeba przejrzeć ich regulaminy pod kątem dystrybucji w publicznej aplikacji i zadbać o limity zapytań.

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
