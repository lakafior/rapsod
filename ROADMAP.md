# Roadmapa

Stan na 2026-11-20. Wydana wersja: 1.0.0.

## Zrobione

1. Powłoka macOS: serwer audiobookshelf jako submodule, nadzór procesu, web UI w oknie.
2. Folder biblioteki z natywnego okna, start przy logowaniu, okno statusu z logiem.
3. Dostęp dla istniejących klientów: udostępnianie w sieci lokalnej, konto dla telefonu, sekcja „Połącz telefon”.
4. Opcjonalny Cloudflare Tunnel z tokenem.
5. Samodzielna paczka: wbudowany Node i ffmpeg, podpis Developer ID, notaryzacja, DMG.

Po 1.0.0: ikona aplikacji, usuwanie biblioteki z okna statusu.

## W toku: zasoby i rozmiar

- **6a. Pamięć.** Pomiar zużycia, zwalnianie web UI po zamknięciu okna, tanie poprawki w aplikacji.
- **6b. Agent w tle.** Nadzór serwera w lekkim procesie, aplikacja z menu i oknami tylko na żądanie. Decyzja po liczbach z 6a.
- **6c. Rozmiar paczki.** Własny build Node (bez pełnych danych językowych i debuggera), ffmpeg tylko z kodekami audio i wspólnymi bibliotekami.

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
