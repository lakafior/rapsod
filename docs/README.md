# Dokumentacja

Szczegóły techniczne Rapsodu (po polsku). Przegląd projektu jest w [README](../README.md), plan w [ROADMAP](../ROADMAP.md).

- [Budowanie i rozwój](development.md) — Praca z kodem: wymagania, budowanie serwera i ffmpeg, kopie testowe, podpis, podbijanie audiobookshelf i mapa kodu aplikacji na Maca.
- [Telefon i dostęp spoza domu](remote-access.md) — Łączenie telefonów z serwerem w sieci domowej i spoza domu (własny adres albo Cloudflare Tunnel) oraz API audiobookshelf, z którego korzysta aplikacja.
- [Aplikacja na Maca](mac-app.md) — Funkcje aplikacji na Maca opisane etapami: źródła metadanych, administracja serwera, ustawienia, natywna Biblioteka i odtwarzacz.
- [Klient iOS i wspólny pakiet](ios-and-shared.md) — Wspólny pakiet `AudiobookshelfKit`, klient iOS (parowanie, odtwarzacz, biblioteka, podcasty, pobieranie, czytnik) i tekst zsynchronizowany z nagraniem.
- [Segmenty sponsorowane w podcastach](sponsor-segments.md) — Oznaczanie i pomijanie reklam i autopromocji w podcastach: znaczniki bez modelu (13a) oraz transkrypcja i zdalny klasyfikator na Macu (13b), z pomiarami.
- [Wydanie i aktualizacje](release.md) — Budowanie podpisanego i notaryzowanego DMG, publikacja na GitHubie, wersje, automatyczne aktualizacje i zawartość paczki (Node, ffmpeg).
- [Licencja](licensing.md) — Licencje aplikacji i dołączonych komponentów oraz obowiązki przy rozprowadzaniu binarek.

Plany i przeglądy:

- [Przegląd pod kątem HIG (etap 14a)](hig-przeglad.md)
- [Nowy układ ustawień](ustawienia-nowy-uklad.md)
