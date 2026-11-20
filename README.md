# audiobookswift

Natywna aplikacja macOS (menu bar) uruchamiająca serwer [audiobookshelf](https://github.com/advplyr/audiobookshelf) bez Dockera, z prostym klientem iOS parowanym przez iCloud.

Serwer audiobookshelf jest dołączony jako git submodule (`vendor/audiobookshelf`) przypięty do tagu wydania i uruchamiany jako proces potomny aplikacji. Kod upstreamu nie jest modyfikowany.

## Budowanie i uruchamianie

Wymagania: Xcode 27, ffmpeg i ffprobe z Homebrew (`brew install ffmpeg`), dostęp do sieci przy pierwszym budowaniu serwera.

```bash
git submodule update --init
scripts/build-server.sh
open AudiobookSwift/AudiobookSwift.xcodeproj
```

W Xcode uruchom schemat `AudiobookSwift`. Aplikacja nie ma ikony w Docku — pojawia się jako ikona książek na pasku menu. Serwer startuje razem z aplikacją; „Otwórz” pokazuje web UI audiobookshelf w oknie.

### Co robi `scripts/build-server.sh`

Wszystko trafia do ignorowanego katalogu `build/`; submodule pozostaje czysty.

1. Pobiera przypięty Node.js 24 z nodejs.org do `build/node` (weryfikacja SHA-256). Upstream celuje w Node 24; na Node 25+ serwer nie startuje.
2. Eksportuje źródła submodule (`git archive`) do `build/abs-server`.
3. Buduje klienta web (`nuxt generate`) i serwer (`tsc` → `dist-server/`), zostawia tylko zależności produkcyjne.
4. Pobiera rozszerzenie SQLite `libnusqlite3` 1.2 (to samo, którego używa obraz Dockera upstreamu; weryfikacja SHA-256) — daje wyszukiwanie bez znaków diakrytycznych.

Skrypt pomija pracę, jeśli `build/abs-server` odpowiada bieżącemu commitowi submodule; `--clean` wymusza pełną przebudowę.

### Podbicie wersji audiobookshelf

```bash
git -C vendor/audiobookshelf fetch --tags
git -C vendor/audiobookshelf checkout vX.Y.Z
scripts/build-server.sh
git add vendor/audiobookshelf
```

Po podbiciu sprawdź w upstreamie wersję Node (`Dockerfile`) i nazwy zmiennych środowiskowych (`index.js`, `server/managers/BinaryManager.js`).

## Jak to działa

- `AudiobookSwift/AudiobookSwift/Server/ServerEnvironment.swift` — jedyne miejsce ze ścieżkami do Node, ffmpeg, kodu serwera i danych oraz z hostem, portem i zmiennymi środowiskowymi serwera.
- `AudiobookSwift/AudiobookSwift/Server/ServerSupervisor.swift` — uruchamia `node`, zbiera stdout/stderr, wykrywa gotowość po HTTP (`/healthcheck`) i nieoczekiwane zakończenie, zatrzymuje serwer przez SIGINT.
- `AudiobookSwift/AudiobookSwift/Resources/parent-watch.js` — ładowany przez `node --require`; wyłącza serwer, gdy aplikacja zniknie (także po `kill -9`), więc nie zostaje osierocony proces.
- Serwer słucha na `http://127.0.0.1:13378/audiobookshelf/` (tylko pętla zwrotna).
- Dane serwera (baza, konfiguracja, metadane, logi): `~/Library/Application Support/AudiobookSwift/`.

## Licencja

audiobookshelf jest na licencji GPL-3.0.
