# audiobookswift

Natywna aplikacja macOS (menu bar) uruchamiająca serwer [audiobookshelf](https://github.com/advplyr/audiobookshelf) bez Dockera. Na telefonie słucha się dowolnym istniejącym klientem audiobookshelf (oficjalna aplikacja, Plappa, ShelfPlayer…).

Serwer audiobookshelf jest dołączony jako git submodule (`vendor/audiobookshelf`) przypięty do tagu wydania i uruchamiany jako proces potomny aplikacji. Kod upstreamu nie jest modyfikowany.

## Budowanie i uruchamianie

Wymagania: Xcode 27 z zalogowanym kontem zespołu deweloperskiego `5TA8RF548P` (podpis), ffmpeg i ffprobe z Homebrew (`brew install ffmpeg`), dostęp do sieci przy pierwszym budowaniu serwera.

```bash
git submodule update --init
scripts/build-server.sh
open AudiobookSwift/AudiobookSwift.xcodeproj
```

W Xcode uruchom schemat `AudiobookSwift`. Aplikacja nie ma ikony w Docku — pojawia się jako ikona książek na pasku menu. Serwer startuje razem z aplikacją; „Otwórz” pokazuje web UI audiobookshelf w oknie (zalogowane automatycznie).

### Codzienna obsługa

- **Pierwsze uruchomienie.** Na czystym serwerze aplikacja sama zakłada konto `root` z losowym hasłem zapisanym w pęku kluczy. Gdy serwer nie ma biblioteki, otwiera się ekran powitalny z przyciskiem wyboru folderu.
- **Dwa konta.** `root` służy tylko do obsługi serwera (biblioteki, użytkownicy). Do słuchania jest wymagane zwykłe konto użytkownika, bez uprawnień administratora — formularz w oknie „Otwórz” i w oknie statusu (nazwa; hasło opcjonalne, puste = losowe w pęku kluczy; podanie hasła istniejącego zwykłego konta je podpina). „Otwórz” loguje web UI na to konto i na to samo konto loguje się telefon, więc postęp słuchania jest wspólny. **„Zarządzanie serwerem…”** w menu przełącza okno na konto root w sesji trzymanej tylko w pamięci; „Wróć do słuchania” albo zamknięcie okna kończy ten tryb.
- **Połącz telefon** (okno statusu) — przełącznik „Udostępniaj serwer w sieci lokalnej” (domyślnie wyłączony) oraz wszystko, co trzeba przepisać do klienta na telefonie: adresy serwera, nazwa użytkownika i hasło, każde z przyciskiem „Kopiuj”. Zob. niżej.
- **Status i logi** (⌘L w menu): stan serwera, wersja audiobookshelf, adres, folder danych, biblioteki, log na żywo z kopiowaniem. Gdy serwer nie wstanie, okno otwiera się samo z czytelnym błędem (np. zajęty port 13378).
- **Uruchamiaj przy logowaniu** — przełącznik w menu i w oknie statusu (`SMAppService.mainApp`); odczytuje stan z systemu, więc zmiana w Ustawieniach systemowych → Ogólne → Rzeczy otwierane podczas logowania też jest widoczna.
- Jeśli serwer ma już konto root, a w pęku kluczy nie ma (aktualnego) hasła — np. folder danych zainicjalizowany wcześniej w web UI albo hasło zmienione w web UI — okno statusu prosi o nie i zapisuje je w pęku kluczy.

### Test na czystym folderze danych

Domyślny folder danych można podmienić argumentem uruchomienia (w Xcode: Edit Scheme → Run → Arguments):

```bash
open AudiobookSwift.app --args -ABSDataRoot /tmp/abs-test -ABSPort 13400
```

`-ABSPort` pozwala uruchomić test obok działającej kopii na 13378. Sekrety są w pęku kluczy pod kontem równym ścieżce folderu danych, a ustawienia udostępniania w `sharing.json` w folderze danych, więc test nie nadpisze prawdziwych.

### Podpis i pęk kluczy

- Pakiet `net.smigi.abswift`, zespół `5TA8RF548P`, podpis automatyczny (`xcodebuild … -allowProvisioningUpdates` albo Xcode). Jedyne uprawnienie w entitlements to grupa pęku kluczy; aplikacja nie używa iCloud.
- Sekrety leżą w pęku kluczy z ochroną danych (dostęp wynika z podpisu, bez pytań po przebudowaniu): `net.smigi.abswift.server-root` (root) i `.server-user` (użytkownik). Hasło roota z etapów 1–2 (klasyczny pęk, usługa `com.audiobookswift.server-root`) jest przenoszone przy pierwszym odczycie — macOS zapyta wtedy raz o zgodę.
- Zmiana identyfikatora pakietu oznacza, że „Uruchamiaj przy logowaniu” trzeba włączyć ponownie.

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
- `AudiobookSwift/AudiobookSwift/Server/AudiobookshelfClient.swift` — mały klient HTTP API serwera (tylko Foundation; w etapie 4 trafi też do iOS).
- `AudiobookSwift/AudiobookSwift/Server/ServerAccount.swift` — konto aplikacji na serwerze: zakłada roota, loguje się, tworzy biblioteki i czeka na skan. `CredentialStore.swift` trzyma dane roota w pęku kluczy.
- `AudiobookSwift/AudiobookSwift/App/LoginItem.swift` — start przy logowaniu.
- `AudiobookSwift/AudiobookSwift/Sharing/` — udostępnianie w sieci lokalnej: `SharingController.swift` (przełącznik, adresy, adres zewnętrzny), `SharingSettings.swift` (`sharing.json`), `LocalNetwork.swift` (nazwa `.local` i adresy IPv4 Maca).
- Serwer słucha na `http://127.0.0.1:13378/audiobookshelf/` (tylko pętla zwrotna), a przy włączonym udostępnianiu na wszystkich interfejsach. Aplikacja zawsze łączy się przez pętlę zwrotną.
- Dane serwera (baza, konfiguracja, metadane, logi): `~/Library/Application Support/AudiobookSwift/`.

## Połączenie z telefonu (etap 3)

Nie ma własnego klienta ani parowania: telefon łączy się istniejącą aplikacją audiobookshelf, podając adres serwera oraz nazwę i hasło konta użytkownika. Aplikacja niczego nie ogłasza w sieci i niczego nie wysyła poza Maca.

- **Sieć lokalna.** Przełącznik „Udostępniaj serwer w sieci lokalnej” (wymaga konta użytkownika, więc także istniejącego roota) restartuje serwer bez `HOST`, czyli z nasłuchem na wszystkich interfejsach. Sekcja pokazuje wtedy adresy `http://<nazwa>.local:13378/audiobookshelf` i `http://<IPv4>:13378/audiobookshelf`, odświeżane po zmianie sieci. Wyłączenie przywraca nasłuch tylko na `127.0.0.1`.
- **Zwykły HTTP.** Ruch w sieci lokalnej nie jest szyfrowany: hasło i treść są widoczne dla innych urządzeń w tej samej sieci (świadoma decyzja; HTTPS jest poza zakresem).
- **Adres zewnętrzny.** Opcjonalne pole na adres własnego tunelu lub VPN (Tailscale, Cloudflare Tunnel, cokolwiek). To zwykłe ustawienie lokalne w `sharing.json`: aplikacja niczego pod nim nie zestawia, tylko pokazuje go obok danych logowania. Integracja z konkretnym dostawcą to osobny, późniejszy etap.
- **Bez kodu QR.** Oficjalna aplikacja (`advplyr/audiobookshelf-app`, stan z 2026-11-19) nie ma dodawania serwera z kodu QR ani z linku — schemat `audiobookshelf://` obsługuje wyłącznie powrót z logowania OpenID (`audiobookshelf://oauth`). Dlatego nie wymyślamy własnego formatu.

### API audiobookshelf, z którego korzystamy (v2.38.0)

Ustalone w kodzie upstreamu (`server/Server.js`, `server/Auth.js`, `server/auth/TokenManager.js`, `server/controllers/LibraryController.js`):

- `GET /status` — `serverVersion`, `isInit` (czy istnieje root). Bez uwierzytelnienia.
- `POST /init` z `{"newRoot": {"username", "password"}}` — tylko gdy nie ma roota.
- `POST /login` (`username`, `password`) — `user.accessToken` (JWT, 1 h). Z nagłówkiem `x-return-tokens: true` także `user.refreshToken` (30 dni); bez niego refresh token trafia do ciasteczka `refresh_token`. Refresh tokeny są rotowane przy `POST /auth/refresh`, więc web UI dostaje osobną sesję. Limit: 40 prób logowania na 10 minut.
- `POST /api/libraries` (admin) z `name`, `folders: [{fullPath}]`, `mediaType` — tworzy bibliotekę, ale **jej nie skanuje**.
- `POST /api/libraries/:id/scan` odpowiada od razu; skan trwa jako zadanie `library-scan` widoczne w `GET /api/tasks`, a po końcu znika z listy. Liczba pozycji: `GET /api/libraries/:id/items?limit=1` → `total`.
- `POST /api/users` (admin) z `username`, `password`, `type: "user"`, `isActive: true` — zwykłe konto (bez `isActive` powstaje nieaktywne). Zajęta nazwa: 400.
- `GET /api/me` — użytkownik, do którego należy token (`type`: `root`, `admin`, `user`, `guest`).
- Web UI trzyma access token w `localStorage['token']` i wczytuje użytkownika tylko na stronie `/login` (`checkAuth`), dlatego automatyczne logowanie ładuje `/login`.

## Licencja

audiobookshelf jest na licencji GPL-3.0.
