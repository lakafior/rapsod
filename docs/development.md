# Budowanie i rozwój

Praca z kodem: wymagania, budowanie serwera i ffmpeg, kopie testowe, podpis, podbijanie audiobookshelf i mapa kodu aplikacji na Maca.

## Budowanie i uruchamianie

Gotową aplikację pobiera się jako plik DMG (zob. „Wydanie”); ten rozdział dotyczy pracy z kodem.

Wymagania: Apple Silicon, Xcode 27 z zalogowanym kontem zespołu deweloperskiego `5TA8RF548P` (podpis), dostęp do sieci przy pierwszym budowaniu. Homebrew ani Node w systemie nie są potrzebne.

```bash
git submodule update --init
scripts/build-server.sh
scripts/build-ffmpeg.sh
open Rapsod/Rapsod.xcodeproj
```

Do pracy z Xcode wystarczą te dwa skrypty: aplikacja uruchomiona z Xcode używa oficjalnego Node z `build/node`. Odchudzony Node do paczki (`scripts/build-node.sh`, zob. „Node w paczce”) buduje dopiero `scripts/release.sh`.

`scripts/build-ffmpeg.sh` (ok. 1 minuty) można pominąć, jeśli jest ffmpeg z Homebrew — aplikacja uruchomiona z Xcode użyje wtedy `/opt/homebrew/bin/ffmpeg`. Ten z Homebrew nie ma jednak kodera WebP, więc miniatury okładek w web UI nie będą się generować.

W Xcode uruchom schemat `Rapsod`. Aplikacja działa jako ikona książek na pasku menu; ikona w Docku pojawia się tylko wtedy, gdy otwarte jest któreś z jej okien (zob. „Okna i Dock”). Serwer startuje razem z aplikacją; „Otwórz bibliotekę” otwiera natywne okno biblioteki (zob. „Natywne słuchanie i biblioteka”).

### Codzienna obsługa

- **Pierwsze uruchomienie.** Na czystym serwerze aplikacja sama zakłada konto `root` z losowym hasłem zapisanym w pęku kluczy. Gdy serwer nie ma biblioteki, otwiera się ekran powitalny z przyciskiem wyboru folderu.
- **Dwa konta.** `root` służy tylko do obsługi serwera (biblioteki, użytkownicy, edycja pozycji w oknie „Biblioteka”). Do słuchania jest wymagane zwykłe konto użytkownika, bez uprawnień administratora — formularz w oknie biblioteki i kafel „Utwórz konto tego Maca” w Ustawieniach → Użytkownicy (nazwa; hasło opcjonalne, puste = losowe w pęku kluczy; podanie hasła istniejącego zwykłego konta je podpina). Okno „Biblioteka” (i web UI słuchacza) używa tego konta („konto tego Maca”), a telefon podłączony do tego konta ma ten sam postęp słuchania. Inne osoby mogą mieć własne konta i własne telefony. **„Zarządzanie serwerem (web UI)…”** (w menu po przytrzymaniu Option, zamiast „Ustawień…”) przełącza okno (z tytułem „Zarządzanie serwerem” zamiast „Biblioteka”) na konto root w sesji trzymanej tylko w pamięci; „Wróć do słuchania” albo zamknięcie okna kończy ten tryb.
- **Dostęp zdalny** (ustawienia, dawne „Udostępnianie”) — przełącznik „Udostępniaj serwer w sieci domowej” (domyślnie wyłączony) z adresami do skopiowania, wybór „Dostęp spoza domu” (brak / własny adres / Cloudflare Tunnel) i skrót do „Kodu z adresami”. Telefony i dane logowania do innych aplikacji (adres, nazwa, hasło) są w profilu osoby na stronie „Użytkownicy”. Zob. niżej.
- **Ustawienia** (⌘, w menu): okno z paskiem bocznym i stronami: **Ogólne** (stan i sterowanie serwerem, adres, „Dziennik serwera” na żywo z kopiowaniem jako podstrona, start przy logowaniu, fragmenty sponsorowane; pod „Zaawansowane” wersja audiobookshelf, folder danych, poziom logu i język serwera), **Biblioteki** (lista ze „Skanuj” i wynikiem skanu, kolejność przeciąganiem wierszy, „Dodaj audiobooki…” i „Dodaj podcasty…” — typu biblioteki nie da się później zmienić, więc wybiera się go przy dodawaniu; podstrona każdej biblioteki; polskie źródła i własni dostawcy metadanych; pod „Zaawansowane” wspólne ustawienia skanera i pamięci podręcznej), **Użytkownicy** (siatka profili osób z telefonami, hasłem, rolą i dostępem, „słucha teraz” na kaflu, historia słuchania; konto root osobno — zob. „Ustawienia: nowy układ”), **Kopie zapasowe** (zob. „Administracja serwera”), **Dostęp zdalny** (sieć domowa, dostęp spoza domu, tunel). Strona, która wymaga działania, ma pomarańczowy znak na pasku bocznym. Okno pamięta ostatnią stronę także po ponownym uruchomieniu aplikacji. Gdy serwer nie wstanie, okno otwiera się samo na „Ogólne” z czytelnym błędem (np. zajęty port 13378).
- **Uruchamiaj przy logowaniu** — przełącznik w menu i na podstronie „Ogólne” (`SMAppService.mainApp`); odczytuje stan z systemu, więc zmiana w Ustawieniach systemowych → Ogólne → Rzeczy otwierane podczas logowania też jest widoczna.
- Jeśli serwer ma już konto root, a w pęku kluczy nie ma (aktualnego) hasła — np. folder danych zainicjalizowany wcześniej w web UI albo hasło zmienione w web UI — strona „Administrator serwera” w Ustawieniach → Użytkownicy (i „Biblioteki”) prosi o nie i zapisuje je w pęku kluczy; inne strony pokazują baner z przyciskiem do niej.
- **Okna i Dock.** Gdy otwarte jest jakiekolwiek okno aplikacji (biblioteka, zarządzanie serwerem, ustawienia, powitanie, „O programie”, także zminimalizowane), aplikacja ma ikonę w Docku i zwykłe menu główne (m.in. Ustawienia… ⌘,, Zamknij ⌘W, Edycja, Okno); po zamknięciu ostatniego okna ikona znika. Kliknięcie ikony wysuwa okna (i przywraca zminimalizowane). Reguła jest ogólna (`App/DockIcon.swift`): liczy się każde zwykłe okno z paskiem tytułu, bez listy okien.
- **⌘Q kończy aplikację razem z serwerem** (po jednym pytaniu, które można wyłączyć w Ogólne › Aplikacja); czerwony przycisk i ⌘W chowają okno, ⌥⌘W zamyka wszystkie okna, a serwer i ikona na pasku menu zostają.

### Test na czystym folderze danych

Domyślny folder danych można podmienić argumentem uruchomienia (w Xcode: Edit Scheme → Run → Arguments):

```bash
open Rapsod.app --args -ABSDataRoot /tmp/abs-test -ABSPort 13400
```

`-ABSPort` pozwala uruchomić test obok działającej kopii na 13378. Sekrety są w pęku kluczy pod kontem równym ścieżce folderu danych, a ustawienia udostępniania w `sharing.json` w folderze danych, więc test nie nadpisze prawdziwych (token tunelu trzeba więc wkleić osobno dla każdego folderu danych). `-ABSCloudflared /ścieżka` podmienia `cloudflared` — np. `/nonexistent` sprawdza zachowanie bez niego.

### Podpis i pęk kluczy

- Pakiet `net.smigi.rapsod`, zespół `5TA8RF548P`, podpis automatyczny (`xcodebuild … -allowProvisioningUpdates` albo Xcode). Jedyne uprawnienie w entitlements to grupa pęku kluczy; aplikacja nie używa iCloud.
- Sekrety leżą w pęku kluczy z ochroną danych (dostęp wynika z podpisu, bez pytań po przebudowaniu): `net.smigi.rapsod.server-root` (root), `.server-user` (użytkownik) i `.cloudflare-tunnel` (token tunelu, tylko gdy go wklejono).
- Zmiana identyfikatora pakietu oznacza, że „Uruchamiaj przy logowaniu” trzeba włączyć ponownie.

### Co robi `scripts/build-server.sh`

Wszystko trafia do ignorowanego katalogu `build/`; submodule pozostaje czysty.

1. Pobiera przypięty oficjalny Node.js 24 z nodejs.org do `build/node` (wersja i sumy SHA-256 w `scripts/node-version.sh`). Upstream celuje w Node 24; na Node 25+ serwer nie startuje. Ten Node buduje serwer (npm) i uruchamia go w trybie deweloperskim; do paczki trafia odchudzony build w tej samej wersji.
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

Po podbiciu sprawdź w upstreamie wersję Node (`Dockerfile`) i nazwy zmiennych środowiskowych (`index.js`, `server/managers/BinaryManager.js`). Zmiana wersji Node: `scripts/node-version.sh` (wersja i trzy sumy: dwie binarki i archiwum źródeł). Po zmianach w wywołaniach ffmpeg w upstreamie (`server/utils/ffmpegHelpers.js`, `server/objects/Stream.js`) uruchom test różnicowy z sekcji „ffmpeg”.

## Jak to działa

- `Rapsod/Rapsod/Server/ServerEnvironment.swift` — jedyne miejsce ze ścieżkami do Node, ffmpeg, kodu serwera i danych oraz z hostem, portem i zmiennymi środowiskowymi serwera. W wydaniu wszystko bierze z `Contents/Resources/Server` w paczce; uruchomiona z Xcode — z katalogu `build/` repozytorium (klucz `ABSDevelopmentRoot` w `Info.plist`, pusty w konfiguracji Release). Serwer dostaje `NODE_OPTIONS=--max-semi-space-size=1` (mniejsza młoda generacja sterty V8): na bibliotece 1200 pozycji Node zajmuje w spoczynku 63 zamiast 99 MB, a po skanie 238 zamiast 314 MB (`phys_footprint`); skan trwa ok. 5% dłużej.
- `Rapsod/Rapsod/Server/ServerSupervisor.swift` — uruchamia `node`, zbiera stdout/stderr, wykrywa gotowość po HTTP (`/healthcheck`) i nieoczekiwane zakończenie, zatrzymuje serwer przez SIGINT.
- `Rapsod/Rapsod/Resources/parent-watch.js` — ładowany przez `node --require`; wyłącza serwer, gdy aplikacja zniknie (także po `kill -9`), więc nie zostaje osierocony proces. Zapamiętuje też procesy uruchomione przez serwer (`child_process.spawn`: ffmpeg przy scalaniu do M4B, osadzaniu metadanych i pobieraniu podcastów, ffprobe) i zabija je przy wyjściu node — bez tego ffmpeg scalający M4B kodował dalej po `kill -9` aplikacji.
- `Packages/AudiobookshelfKit/` — wspólny pakiet Swift (etap 10a): klient HTTP API serwera (`AudiobookshelfClient`) z modelami i wszystkimi punktami API, zdarzenia serwera, odnawianie tokenów, pamięć okładek. Zob. „Wspólny pakiet AudiobookshelfKit”.
- `Rapsod/Rapsod/Server/ServerAccount.swift` — konto aplikacji na serwerze: zakłada roota, loguje się, tworzy biblioteki i czeka na skan. `CredentialStore.swift` trzyma dane roota w pęku kluczy.
- `Rapsod/Rapsod/App/LoginItem.swift` — start przy logowaniu.
- `Rapsod/Rapsod/UI/Settings/` — okno „Ustawienia”. Lista stron to enum `SettingsPage` w `SettingsWindow.swift` (tytuł, symbol, widok); nowa strona to nowy przypadek, a nowy model — pole w `AppModels`. Podstrony obiektów (osoba, root) to `SettingsDestination` na ścieżce `NavigationStack` w szczegółach. Menu i inne okna otwierają stronę albo podstronę przez `openWindow.openSettings(_:navigation:)`. Wspólne elementy (wiersz obiektu, „Zaawansowane”, harmonogram, wiersz hasła, baner) są w `SettingsComponents.swift`; strona „Użytkownicy” w `UI/Users/`. Argument `-ABSSettingsTour YES` (tylko testowa kopia) otwiera po kolei każdą stronę i podstronę i wypisuje `TOUR OK`.
- `Rapsod/Rapsod/App/DockIcon.swift` — ikona w Docku zależna od otwartych okien i obsługa ⌘Q (`AppQuit`).
- `Rapsod/Rapsod/Sharing/` — udostępnianie: `SharingController.swift` (przełącznik sieci lokalnej, adresy, tryb dostępu spoza domu i jedyne źródło „adresu zewnętrznego”), `SharingSettings.swift` (`sharing.json`, bez sekretów), `LocalNetwork.swift` (nazwa `.local` i adresy IPv4 Maca).
- `Rapsod/Rapsod/Tunnel/` — jedyne miejsce z kodem Cloudflare: `CloudflareTunnel.swift` (nadzór `cloudflared`, stan, adres z konfiguracji tunelu), `CloudflareTunnelToken.swift`, `CloudflareTunnelSection.swift` (UI). Zasoby: `Resources/tunnel-watch.sh` (pośrednik pilnujący `cloudflared`) i `Resources/cloudflared.yml` (pusty plik konfiguracyjny).
- Serwer słucha na `http://127.0.0.1:13378/audiobookshelf/` (tylko pętla zwrotna), a przy włączonym udostępnianiu na wszystkich interfejsach. Aplikacja zawsze łączy się przez pętlę zwrotną.
- Dane serwera (baza, konfiguracja, metadane, logi): `~/Library/Application Support/Rapsod/`.
