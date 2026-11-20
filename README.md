# audiobookswift

Natywna aplikacja macOS (menu bar) uruchamiająca serwer [audiobookshelf](https://github.com/advplyr/audiobookshelf) bez Dockera. Na telefonie słucha się dowolnym istniejącym klientem audiobookshelf (oficjalna aplikacja, Plappa, ShelfPlayer…).

Serwer audiobookshelf jest dołączony jako git submodule (`vendor/audiobookshelf`) przypięty do tagu wydania i uruchamiany jako proces potomny aplikacji. Kod upstreamu nie jest modyfikowany.

## Budowanie i uruchamianie

Gotową aplikację pobiera się jako plik DMG (zob. „Wydanie”); ten rozdział dotyczy pracy z kodem.

Wymagania: Apple Silicon, Xcode 27 z zalogowanym kontem zespołu deweloperskiego `5TA8RF548P` (podpis), dostęp do sieci przy pierwszym budowaniu. Homebrew ani Node w systemie nie są potrzebne.

```bash
git submodule update --init
scripts/build-server.sh
scripts/build-ffmpeg.sh
open AudiobookSwift/AudiobookSwift.xcodeproj
```

Do pracy z Xcode wystarczą te dwa skrypty: aplikacja uruchomiona z Xcode używa oficjalnego Node z `build/node`. Odchudzony Node do paczki (`scripts/build-node.sh`, zob. „Node w paczce”) buduje dopiero `scripts/release.sh`.

`scripts/build-ffmpeg.sh` (ok. 1 minuty) można pominąć, jeśli jest ffmpeg z Homebrew — aplikacja uruchomiona z Xcode użyje wtedy `/opt/homebrew/bin/ffmpeg`. Ten z Homebrew nie ma jednak kodera WebP, więc miniatury okładek w web UI nie będą się generować.

W Xcode uruchom schemat `AudiobookSwift`. Aplikacja nie ma ikony w Docku — pojawia się jako ikona książek na pasku menu. Serwer startuje razem z aplikacją; „Otwórz” pokazuje web UI audiobookshelf w oknie (zalogowane automatycznie).

### Codzienna obsługa

- **Pierwsze uruchomienie.** Na czystym serwerze aplikacja sama zakłada konto `root` z losowym hasłem zapisanym w pęku kluczy. Gdy serwer nie ma biblioteki, otwiera się ekran powitalny z przyciskiem wyboru folderu.
- **Dwa konta.** `root` służy tylko do obsługi serwera (biblioteki, użytkownicy). Do słuchania jest wymagane zwykłe konto użytkownika, bez uprawnień administratora — formularz w oknie „Otwórz” i w oknie statusu (nazwa; hasło opcjonalne, puste = losowe w pęku kluczy; podanie hasła istniejącego zwykłego konta je podpina). „Otwórz” loguje web UI na to konto i na to samo konto loguje się telefon, więc postęp słuchania jest wspólny. **„Zarządzanie serwerem…”** w menu przełącza okno na konto root w sesji trzymanej tylko w pamięci; „Wróć do słuchania” albo zamknięcie okna kończy ten tryb.
- **Połącz telefon** (okno statusu) — przełącznik „Udostępniaj serwer w sieci lokalnej” (domyślnie wyłączony), wybór „Dostęp spoza domu” (brak / własny adres / Cloudflare Tunnel) oraz wszystko, co trzeba przepisać do klienta na telefonie: adresy serwera, nazwa użytkownika i hasło, każde z przyciskiem „Kopiuj”. Zob. niżej.
- **Status i logi** (⌘L w menu): stan serwera, wersja audiobookshelf, adres, folder danych, biblioteki, log na żywo z kopiowaniem. Gdy serwer nie wstanie, okno otwiera się samo z czytelnym błędem (np. zajęty port 13378).
- **Uruchamiaj przy logowaniu** — przełącznik w menu i w oknie statusu (`SMAppService.mainApp`); odczytuje stan z systemu, więc zmiana w Ustawieniach systemowych → Ogólne → Rzeczy otwierane podczas logowania też jest widoczna.
- Jeśli serwer ma już konto root, a w pęku kluczy nie ma (aktualnego) hasła — np. folder danych zainicjalizowany wcześniej w web UI albo hasło zmienione w web UI — okno statusu prosi o nie i zapisuje je w pęku kluczy.

### Test na czystym folderze danych

Domyślny folder danych można podmienić argumentem uruchomienia (w Xcode: Edit Scheme → Run → Arguments):

```bash
open AudiobookSwift.app --args -ABSDataRoot /tmp/abs-test -ABSPort 13400
```

`-ABSPort` pozwala uruchomić test obok działającej kopii na 13378. Sekrety są w pęku kluczy pod kontem równym ścieżce folderu danych, a ustawienia udostępniania w `sharing.json` w folderze danych, więc test nie nadpisze prawdziwych (token tunelu trzeba więc wkleić osobno dla każdego folderu danych). `-ABSCloudflared /ścieżka` podmienia `cloudflared` — np. `/nonexistent` sprawdza zachowanie bez niego.

### Podpis i pęk kluczy

- Pakiet `net.smigi.abswift`, zespół `5TA8RF548P`, podpis automatyczny (`xcodebuild … -allowProvisioningUpdates` albo Xcode). Jedyne uprawnienie w entitlements to grupa pęku kluczy; aplikacja nie używa iCloud.
- Sekrety leżą w pęku kluczy z ochroną danych (dostęp wynika z podpisu, bez pytań po przebudowaniu): `net.smigi.abswift.server-root` (root), `.server-user` (użytkownik) i `.cloudflare-tunnel` (token tunelu, tylko gdy go wklejono). Hasło roota z etapów 1–2 (klasyczny pęk, usługa `com.audiobookswift.server-root`) jest przenoszone przy pierwszym odczycie — macOS zapyta wtedy raz o zgodę.
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

- `AudiobookSwift/AudiobookSwift/Server/ServerEnvironment.swift` — jedyne miejsce ze ścieżkami do Node, ffmpeg, kodu serwera i danych oraz z hostem, portem i zmiennymi środowiskowymi serwera. W wydaniu wszystko bierze z `Contents/Resources/Server` w paczce; uruchomiona z Xcode — z katalogu `build/` repozytorium (klucz `ABSDevelopmentRoot` w `Info.plist`, pusty w konfiguracji Release). Serwer dostaje `NODE_OPTIONS=--max-semi-space-size=1` (mniejsza młoda generacja sterty V8): na bibliotece 1200 pozycji Node zajmuje w spoczynku 63 zamiast 99 MB, a po skanie 238 zamiast 314 MB (`phys_footprint`); skan trwa ok. 5% dłużej.
- `AudiobookSwift/AudiobookSwift/Server/ServerSupervisor.swift` — uruchamia `node`, zbiera stdout/stderr, wykrywa gotowość po HTTP (`/healthcheck`) i nieoczekiwane zakończenie, zatrzymuje serwer przez SIGINT.
- `AudiobookSwift/AudiobookSwift/Resources/parent-watch.js` — ładowany przez `node --require`; wyłącza serwer, gdy aplikacja zniknie (także po `kill -9`), więc nie zostaje osierocony proces.
- `AudiobookSwift/AudiobookSwift/Server/AudiobookshelfClient.swift` — mały klient HTTP API serwera.
- `AudiobookSwift/AudiobookSwift/Server/ServerAccount.swift` — konto aplikacji na serwerze: zakłada roota, loguje się, tworzy biblioteki i czeka na skan. `CredentialStore.swift` trzyma dane roota w pęku kluczy.
- `AudiobookSwift/AudiobookSwift/App/LoginItem.swift` — start przy logowaniu.
- `AudiobookSwift/AudiobookSwift/Sharing/` — udostępnianie: `SharingController.swift` (przełącznik sieci lokalnej, adresy, tryb dostępu spoza domu i jedyne źródło „adresu zewnętrznego”), `SharingSettings.swift` (`sharing.json`, bez sekretów), `LocalNetwork.swift` (nazwa `.local` i adresy IPv4 Maca).
- `AudiobookSwift/AudiobookSwift/Tunnel/` — jedyne miejsce z kodem Cloudflare: `CloudflareTunnel.swift` (nadzór `cloudflared`, stan, adres z konfiguracji tunelu), `CloudflareTunnelToken.swift`, `CloudflareTunnelSection.swift` (UI). Zasoby: `Resources/tunnel-watch.sh` (pośrednik pilnujący `cloudflared`) i `Resources/cloudflared.yml` (pusty plik konfiguracyjny).
- Serwer słucha na `http://127.0.0.1:13378/audiobookshelf/` (tylko pętla zwrotna), a przy włączonym udostępnianiu na wszystkich interfejsach. Aplikacja zawsze łączy się przez pętlę zwrotną.
- Dane serwera (baza, konfiguracja, metadane, logi): `~/Library/Application Support/AudiobookSwift/`.

## Połączenie z telefonu (etap 3)

Nie ma własnego klienta ani parowania: telefon łączy się istniejącą aplikacją audiobookshelf, podając adres serwera oraz nazwę i hasło konta użytkownika. Aplikacja niczego nie ogłasza w sieci i niczego nie wysyła poza Maca.

- **Sieć lokalna.** Przełącznik „Udostępniaj serwer w sieci lokalnej” (wymaga konta użytkownika, więc także istniejącego roota) restartuje serwer bez `HOST`, czyli z nasłuchem na wszystkich interfejsach. Sekcja pokazuje wtedy adresy `http://<nazwa>.local:13378` i `http://<IPv4>:13378`, odświeżane po zmianie sieci. Ścieżki `/audiobookshelf` nie trzeba wpisywać: upstream sam dopisuje `ROUTER_BASE_PATH` do żądań, które jej nie mają (adres ze ścieżką też działa). Wyłączenie przywraca nasłuch tylko na `127.0.0.1`.
- **Zwykły HTTP.** Ruch w sieci lokalnej nie jest szyfrowany: hasło i treść są widoczne dla innych urządzeń w tej samej sieci (świadoma decyzja; HTTPS jest poza zakresem).
- **Dostęp spoza domu** — opisany niżej (etap 4).
- **Bez kodu QR.** Oficjalna aplikacja (`advplyr/audiobookshelf-app`, stan z 2026-11-19) nie ma dodawania serwera z kodu QR ani z linku — schemat `audiobookshelf://` obsługuje wyłącznie powrót z logowania OpenID (`audiobookshelf://oauth`). Dlatego nie wymyślamy własnego formatu.

## Dostęp spoza domu (etap 4)

Opcjonalny i niezależny od dostawcy. W sekcji „Połącz telefon” wybiera się jeden z trybów; wynikiem jest jeden „adres spoza domu” pokazywany obok danych logowania:

- **Brak** (domyślnie) — tylko ten Mac i ewentualnie sieć lokalna.
- **Własny adres** — dowolny adres wpisany ręcznie (Tailscale, własny tunel, VPN). Aplikacja niczego pod nim nie zestawia.
- **Cloudflare Tunnel** — aplikacja sama uruchamia i pilnuje `cloudflared`. Tunel kieruje ruch na `127.0.0.1`, więc nie wymaga udostępniania w sieci lokalnej (oba ustawienia są niezależne).

Tryb jest zapisany w `sharing.json` (pole `externalAccess`; stary plik z wpisanym adresem oznacza „własny adres”).

### Cloudflare Tunnel: konfiguracja w panelu (raz)

Wariant: tunel zarządzany zdalnie, uruchamiany tokenem. Wymaga konta Cloudflare i domeny dodanej do Cloudflare (stały adres `https://<nazwa>.<twoja-domena>`). Szybkie tunele `trycloudflare.com` odpadają, bo adres zmienia się przy każdym starcie; tunel tworzony lokalnie (`cloudflared tunnel login`) trzyma poświadczenia w plikach w `~/.cloudflared`.

1. Zainstaluj `cloudflared`: oficjalny instalator `cloudflared-arm64.pkg` ze [strony wydań](https://github.com/cloudflare/cloudflared/releases) (instaluje do `/usr/local/bin`) albo `brew install cloudflared`. Aplikacja celowo nie zawiera własnej kopii — szuka go w `/usr/local/bin` i `/opt/homebrew/bin`; bez `cloudflared` opcja pokazuje tę wskazówkę, a reszta aplikacji działa.
2. Panel Cloudflare → **Networking → Tunnels → Create tunnel** → typ **Cloudflared**, dowolna nazwa (np. `audiobookswift`).
3. Na ekranie instalacji skopiuj polecenie z tokenem (`… service install eyJ…`) — **nie uruchamiaj go**, tylko wklej w aplikacji w pole „Token tunelu” (całe polecenie albo sam token). Token trafia wyłącznie do pęku kluczy.
4. W tunelu, zakładka **Routes → Add route → Published application**: subdomena i domena (np. `ksiazki.example.com`), usługa **HTTP**, adres `127.0.0.1:13378`. Cloudflare sam utworzy rekord DNS.
5. Aplikacja łączy się, odczytuje opublikowaną nazwę z konfiguracji tunelu i pokazuje `https://ksiazki.example.com` w „Połącz telefon”. Jeśli trasa wskazuje inny port albo jej brak, okno to mówi.
6. Zalecane (zob. „Bezpieczeństwo”): w strefie domeny **Security → Security rules → Create rule → Rate limiting rules**, wyrażenie `(http.host eq "ksiazki.example.com" and http.request.uri.path in {"/login" "/audiobookshelf/login"} and http.request.method eq "POST")`, liczenie po IP, np. 5 żądań na 10 s, akcja Block na 10 s (na planie Free okres i czas blokady to 10 s).

Token zmienia się przyciskiem „Zapisz” z nowym tokenem, usuwa „Usuń token”. Tunel w panelu usuwa się ręcznie.

### Jak aplikacja pilnuje `cloudflared`

- Uruchamia `/bin/sh Resources/tunnel-watch.sh <cloudflared> tunnel --config Resources/cloudflared.yml … run`. Pierwsza linia stdin to token, przekazywany dalej przez `--token-file /dev/stdin` — tokenu nie ma w argumentach (`ps`), w środowisku procesu (`ps -E`), w plikach ani w logu (linie wyglądające na token są dodatkowo maskowane).
- Potem aplikacja trzyma potok stdin otwarty. Gdy go zamknie (zatrzymanie) albo zniknie (także `kill -9`), strażnik w skrypcie dostaje EOF i wysyła `cloudflared` SIGTERM, a po 5 s SIGKILL. Sam `cloudflared` nie reaguje na zamknięcie stdin, stąd pośrednik; to ten sam pomysł co `parent-watch.js` dla Node.
- Własny, prawie pusty `cloudflared.yml`, bo bez `--config` `cloudflared` wczytałby `~/.cloudflared/config.yml` (np. innego tunelu użytkownika).
- Tunel startuje, gdy jest wybrany, jest token, a serwer działa i ma konto root; zatrzymuje się razem z serwerem (także przy restarcie po zmianie sieci lokalnej) i przy wyjściu z aplikacji. Stan: łączenie / połączony / błąd z powodem (np. odrzucony token kończy tunel błędem zamiast ponawiać), log tunelu w sekcji.

### Jeśli masz już własny tunel lokalny

Zamiast tunelu z tokenem można dopisać serwer do istniejącego tunelu tworzonego lokalnie i wybrać „Własny adres” (wtedy aplikacja tego tunelu nie pilnuje):

1. W `~/.cloudflared/config.yml` dopisz regułę **przed** końcowym `- service: http_status:404`:
   ```yaml
     - hostname: ksiazki.example.com
       service: http://127.0.0.1:13378
   ```
2. `cloudflared tunnel route dns <nazwa-tunelu> ksiazki.example.com`
3. Uruchom ponownie swój `cloudflared` (proces albo usługę, którą go uruchamiasz).
4. W aplikacji: „Dostęp spoza domu” → „Własny adres” → `https://ksiazki.example.com`.

Nie uruchamiaj tego samego tunelu dwa razy (z aplikacji i ręcznie): dwie kopie `cloudflared` jednego tunelu działają jak repliki i Cloudflare rozdziela między nie ruch.

### Warunki Cloudflare dla audio (stan z 2026-11-20)

- Warunki usług Cloudflare, sekcja „Content Delivery Network (Free, Pro, or Business)” (aktualizacja 2026-09-28): poza planem Enterprise do serwowania wideo i innych dużych plików trzeba używać określonych płatnych usług; Cloudflare może ograniczyć lub wyłączyć dostęp, jeśli CDN bez nich serwuje wideo albo „nieproporcjonalny odsetek” zdjęć, **plików audio** lub innych dużych plików.
- Strona „Delivering videos with Cloudflare” (zmiana 2026-08-25): publiczne trasy Cloudflare Tunnel na planach Free/Pro/Business **podlegają tym samym zasadom**; nie dotyczą one tras sieci prywatnej (wymagają klienta Cloudflare One/WARP na telefonie — poza zakresem).
- Nie ustaliliśmy żadnego progu ani tego, czy prywatne słuchanie przez jedną osobę zwraca uwagę. Ryzykiem jest ograniczenie lub zablokowanie adresu. Kto chce mieć pewność, ma Tailscale przez „Własny adres”.

### Bezpieczeństwo przy wystawieniu do internetu

- Root ma losowe hasło (32 znaki, pęk kluczy); telefon używa zwykłego konta bez uprawnień administratora. Tunel (jak sieć lokalna) da się wybrać dopiero przy działającym serwerze z kontem root i kontem użytkownika — niezainicjalizowany serwer pozwala każdemu założyć roota.
- Telefon ↔ Cloudflare idzie po HTTPS; Cloudflare ↔ `cloudflared` szyfrowanym tunelem; `cloudflared` → serwer po pętli zwrotnej.
- **Limit logowania upstreamu da się obejść przez tunel.** `server/utils/rateLimiterFactory.js` liczy 40 prób na 10 min według adresu z `server/libs/requestIp`, który najpierw czyta `X-Forwarded-For` (pierwszy adres), a dopiero potem `CF-Connecting-IP`. Cloudflare dopisuje się do istniejącego `X-Forwarded-For`, więc klient może przy każdej próbie podać inny adres. Przy losowym haśle bez znaczenia; przy własnym, krótkim — tak. Dlatego okno ostrzega przy haśle krótszym niż 16 znaków, a punkt 6 konfiguracji zaleca regułę limitu w WAF Cloudflare (liczy po prawdziwym adresie).
- Cloudflare Access (logowanie przed serwerem) celowo pominięty: natywne klienty audiobookshelf nie przejdą jego ekranu logowania.

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

## Źródła metadanych (etap 7)

Opcjonalne i domyślnie wyłączone: LubimyCzytać, Audioteka, Storytel i Audible jako jedno źródło w oknie dopasowywania książki w audiobookshelf, bez osobnego kontenera i bez wpisywania czegokolwiek w ustawieniach serwera. Kod źródeł to agregator [aio-abs-providers](https://github.com/lakafior/aio-abs-providers) (GPL-3.0), dołączony jako drugi submodule (`vendor/aio-abs-providers`) przypięty do commita i niemodyfikowany.

```bash
git submodule update --init
scripts/build-server.sh      # daje też Node w build/node
scripts/build-providers.sh   # eksport submodule do build/aio-abs-providers + npm ci --omit=dev
```

Bez zbudowanego agregatora aplikacja działa normalnie, a sekcja pokazuje, czego brakuje. Aktualizacja źródeł = przesunięcie przypięcia submodule, `scripts/build-providers.sh` i nowe wydanie aplikacji.

### Obsługa

Okno statusu, sekcja **Źródła metadanych**: przełącznik, stan (wyłączone / uśpione / uruchamianie / działa / błąd z powodem), stan wpisu w audiobookshelf, przyciski **Konfiguracja…** i **Wyszukiwarka…** oraz log. Przyciski otwierają w oknie aplikacji strony samego agregatora (`/admin`: które źródła, język, scalanie wyników; `/search-ui`: próbne wyszukiwanie). Zmiany zapisane na stronie konfiguracji działają od następnego wyszukiwania.

W audiobookshelf źródło pojawia się jako „Źródła metadanych (AudiobookSwift)” na liście dostawców w oknie dopasowywania (Match). Aplikacja ustawia go też jako domyślnego dostawcę bibliotek z książkami (`PATCH /api/libraries/:id`), więc „Quick match” i dopasowanie całej biblioteki pytają właśnie te źródła. Każdej bibliotece ustawia go raz — przy włączeniu funkcji albo gdy biblioteka jest nowa — i nie nadpisuje dostawcy zmienionego później w ustawieniach biblioteki. Po wyłączeniu funkcji upstream sam przestawia biblioteki na `google` (nie na wcześniejszy wybór).

### Jak to działa

- **Uruchamianie na żądanie.** Audiobookshelf dostaje stały adres `http://127.0.0.1:13379` (port serwera + 1; `-ABSMetadataPort` go zmienia). Pod tym adresem nasłuchuje sama aplikacja (`MetadataSources/LoopbackProxy.swift`, przekaźnik TCP na pętli zwrotnej). Pierwsze połączenie uruchamia agregator na wolnym porcie (`PORT=0`), aplikacja czeka na jego `/healthz` i dopiero wtedy przekazuje ruch — zapytanie z audiobookshelf po prostu trwa o ok. 0,3 s dłużej. Po 5 minutach bez połączeń (`-ABSMetadataIdle <sekundy>`) agregator jest zatrzymywany; otwarte okno jego stron wstrzymuje usypianie. W spoczynku nie działa żaden dodatkowy proces, a przy wyłączonej funkcji aplikacja nie nasłuchuje wcale.
- **Nadzór procesu** (`MetadataSources/AggregatorProcess.swift`): jawne środowisko (`HOST=127.0.0.1`, `CONFIG_PATH`, `API_KEY`, `EXIT_ON_STDIN_CLOSE=1`), bufor logu, stan. Aplikacja trzyma potok stdin agregatora; jego zamknięcie (zatrzymanie, wyjście, także `kill -9` aplikacji) kończy proces, więc nie zostaje osierocony.
- **Klucz.** Losowy klucz API (32 znaki) leży w pęku kluczy (`net.smigi.abswift.metadata-sources`, konto = ścieżka folderu danych). Agregator dostaje go przez środowisko, audiobookshelf jako `authHeaderValue` wpisu (upstream trzyma go w swojej bazie), strony w oknie aplikacji — w adresie (`?key=…`), dlatego to okno nie loguje adresów i ma nietrwały magazyn danych. Bez klucza `/search` i `/admin` odpowiadają 401.
- **Wpis w audiobookshelf** (`MetadataSources/MetadataSourcesController.swift`): po włączeniu aplikacja dodaje dostawcę przez `POST /api/custom-metadata-providers`, po wyłączeniu usuwa. Przy każdym połączeniu z serwerem uzgadnia stan: brak wpisu przy włączonej funkcji → dodaje; wpis ze starym adresem lub kluczem → zastępuje (upstream nie ma edycji wpisu); wpis przy wyłączonej funkcji → usuwa. Własny wpis rozpoznaje po zapamiętanym identyfikatorze albo po dokładnie swoim adresie, więc dostawców dodanych ręcznie nie rusza. Usuwając wpis, upstream przestawia biblioteki, które miały go jako domyślnego dostawcę, na `google` — dlatego przy zastępowaniu aplikacja najpierw dodaje nowy wpis, przenosi na niego biblioteki ze starego i dopiero wtedy stary usuwa.
- **Pliki** w folderze danych (osobne dla każdego `-ABSDataRoot`): `metadata-sources/settings.json` (przełącznik i identyfikator wpisu, bez sekretów) oraz `metadata-sources/config.json` (konfiguracja agregatora; tworzy ją i zmienia on sam, format opisuje `vendor/aio-abs-providers/docs/CONFIG.md`).
- **Ścieżki** są w wydzielonym bloku `ServerEnvironment.swift`: z Xcode `build/node` i `build/aio-abs-providers`, w wydaniu `Contents/Resources/Server/node` i `Contents/Resources/Server/aio-abs-providers`.

## Wydanie

Wydanie to plik `AudiobookSwift-<wersja>.dmg`: aplikacja podpisana Developer ID z hardened runtime, notaryzowana, z biletem zszytym z aplikacją i z obrazem dysku. Zawiera Node, serwer audiobookshelf z klientem web, ffmpeg, ffprobe i rozszerzenie SQLite — działa bez repozytorium, Homebrew i Node w systemie. Tylko Apple Silicon, macOS 27 lub nowszy (`MACOSX_DEPLOYMENT_TARGET`).

### Jednorazowa konfiguracja

1. W pęku kluczy musi być tożsamość „Developer ID Application: … (5TA8RF548P)” (Xcode → Settings → Accounts → Manage Certificates → „+” → Developer ID Application).
2. Konto zespołu zalogowane w Xcode — eksport z podpisem automatycznym tworzy przy pierwszym wydaniu profil aprowizacji Developer ID dla `net.smigi.abswift` (grupa pęku kluczy jest uprawnieniem wymagającym profilu).
3. Profil `notarytool`:
   - na [account.apple.com](https://account.apple.com) → Logowanie i bezpieczeństwo → Hasła do aplikacji utwórz hasło (np. o nazwie `notarytool`);
   - zapisz je w pęku kluczy — polecenie zapyta o hasło, nie podawaj go w argumentach:
     ```bash
     xcrun notarytool store-credentials audiobookswift-notary --apple-id <twój Apple ID> --team-id 5TA8RF548P
     ```
   Inną nazwę profilu podaje się zmienną `ABS_NOTARY_PROFILE`.

### Zrobienie wydania

```bash
git submodule update --init
scripts/release.sh
```

Czas: za pierwszym razem na danym Macu ok. 45 minut, z czego ok. 30 minut to kompilacja Node; potem ok. 10 minut, w większości czekanie na notaryzację. Szczegóły w krokach:

1. buduje serwer (`scripts/build-server.sh`, ok. 1–2 minut, potem pomijany), Node do paczki (`scripts/build-node.sh`, ok. 30 minut raz na wersję Node, potem kopia z pamięci podręcznej) i ffmpeg (`scripts/build-ffmpeg.sh`, ok. 1 minuty, potem pomijany) — pobierane pliki są przypięte do wersji i sprawdzane sumą SHA-256;
2. składa `Contents/Resources/Server`: `node`, `ffmpeg/bin` (ffmpeg, ffprobe), `ffmpeg/lib` (ich wspólne biblioteki) odchudzony `aio-abs-providers` (kod agregatora źródeł metadanych i jego zależności produkcyjne) i odchudzony `abs-server` (skompilowany kod, `client/dist`, zależności produkcyjne bez map źródeł, typów TypeScript, `node-gyp`, źródeł SQLite i alternatywnych kopii pakietów, których serwer nie ładuje — źródeł ES i paczek dla przeglądarki `moment`, `validator`, `jose`, `node-unrar-js`, `lodash/fp`; pliki licencji pakietów zostają);
3. podpisuje każdą binarkę Mach-O w tym folderze (w tym biblioteki ffmpeg, moduł natywny `node_sqlite3.node` i `libnusqlite3.dylib`), sprawdza, że podpisany Node ładuje sqlite3 z rozszerzeniem i wszystkie zależności produkcyjne serwera;
4. archiwizuje aplikację w konfiguracji Release i eksportuje ją z podpisem Developer ID;
5. wstawia serwer i folder `Licenses` do paczki, podpisuje aplikację od nowa z uprawnieniami z eksportu;
6. notaryzuje aplikację i zszywa bilet, tworzy DMG (aplikacja + skrót do `/Applications`), podpisuje, notaryzuje i zszywa bilet z DMG;
7. sprawdza wynik: `codesign --verify --deep --strict`, `stapler validate`, `spctl --assess` dla aplikacji i DMG.

Wynik: `build/release/AudiobookSwift-<wersja>.dmg` (pliku nie commitujemy). `scripts/release.sh --skip-notarize` robi wszystko poza notaryzacją — do testów lokalnych, nie do publikacji.

### Wersje

- Wersja aplikacji to `MARKETING_VERSION` w projekcie (własna numeracja, niezależna od audiobookshelf). Numer builda to liczba commitów (`ABS_BUILD_NUMBER` go nadpisuje).
- Wersję audiobookshelf pokazuje okno statusu i „O programie”; dokładne wersje wszystkich składników są w `Contents/Resources/Licenses/VERSIONS.txt`.
- Nowa wersja audiobookshelf u użytkowników = nowe wydanie aplikacji po „Podbiciu wersji audiobookshelf” (wyżej). Aktualizacji automatycznych nie ma: użytkownik pobiera nowy DMG i podmienia aplikację; dane w `~/Library/Application Support/AudiobookSwift/` i pęk kluczy zostają.
- Migracje bazy uruchamia sam upstream przy starcie (`server/managers/MigrationManager.js`): przed migracją kopiuje bazę do `absdatabase.backup.sqlite`, a przy błędzie przywraca kopię, zostawia nieudaną jako `absdatabase.failed.sqlite` i kończy proces. Starsza wersja serwera na nowszej bazie wykonuje migracje wstecz. Automatyczne kopie zapasowe upstreamu są domyślnie wyłączone — włącza się je w web UI („Zarządzanie serwerem…” → Settings → Backups).

### Podpis i uprawnienia runtime

- Aplikacja: hardened runtime, bez sandboxa; uprawnienia tylko te, które nadaje profil (identyfikator aplikacji, zespół, grupa pęku kluczy `5TA8RF548P.net.smigi.abswift`). Ta sama grupa co w buildach z Xcode, więc wydana aplikacja czyta istniejące pozycje pęku kluczy.
- `node`: jedno uprawnienie, `com.apple.security.cs.allow-jit` (`packaging/node.entitlements`). Silnik V8 rezerwuje pamięć wykonywalną dla JIT; bez tego uprawnienia Node pod hardened runtime kończy się przy starcie błędem „Failed to reserve virtual memory for CodeRange”. Pozostałe uprawnienia z oficjalnej binarki Node (`allow-unsigned-executable-memory`, `disable-executable-page-protection`, `disable-library-validation`, `allow-dyld-environment-variables`) nie są potrzebne: moduł `node_sqlite3.node` i `libnusqlite3.dylib` są podpisane tym samym zespołem, więc przechodzą walidację bibliotek.
- `ffmpeg`, `ffprobe`, biblioteki w `ffmpeg/lib`, `node_sqlite3.node`, `libnusqlite3.dylib`: hardened runtime bez uprawnień. Biblioteki ffmpeg są podpisane tym samym zespołem co binarki, więc przechodzą walidację bibliotek bez `disable-library-validation`.

### Node w paczce

`scripts/build-node.sh` kompiluje Node.js (wersja z `scripts/node-version.sh`) z niezmienionych źródeł z nodejs.org z mniejszym zestawem składników: dane ICU tylko dla angielskiego i polskiego (`--with-intl=small-icu --with-icu-locales=en,pl`), bez inspektora (`--inspect`) i bez npm, corepack, amaro i `node:sqlite`, a potem `strip -x`. Wynik: ok. 62 MB zamiast 122 MB oficjalnej binarki.

Co zostaje, bo serwer tego używa (sprawdzone w kodzie upstreamu i testem porównawczym z oficjalną binarką): `Intl.Collator` z opcjami `numeric` i `sensitivity` (sortowanie w pamięci, porównanie wersji przy migracjach), `normalize` (NFC nazw plików, usuwanie diakrytyków przy dopasowaniu metadanych), strefa czasowa systemu, OpenSSL (JWT, OIDC, TLS dla podcastów i dostawców metadanych), WebAssembly (`node-unrar-js`, libarchive dla komiksów), `worker_threads`, zlib i N-API (moduł `sqlite3`). Polski jest w danych ICU, bo aplikacja przekazuje serwerowi `LANG` użytkownika, a serwer sortuje według domyślnego języka procesu. Pełny `strip` (zamiast `strip -x`) usuwa symbole N-API i moduł `sqlite3` przestaje się ładować.

Czysta kompilacja trwa ok. 30 minut (10 rdzeni) i wymaga Pythona 3.9–3.14 (wystarczy systemowy `/usr/bin/python3`). Wynik trafia do pamięci podręcznej wspólnej dla wszystkich kopii repozytorium, `~/Library/Caches/AudiobookSwift-build/node-<wersja>-<skrót opcji>` (inne miejsce: zmienna `ABS_BUILD_CACHE`), a stamtąd do `build/node-runtime`. Kolejne wydania i nowe worktree tylko kopiują plik; kompilacja wraca po zmianie wersji Node, opcji albo kompilatora. `scripts/build-node.sh --clean` wymusza ją od razu.

### ffmpeg

`scripts/build-ffmpeg.sh` kompiluje ffmpeg 9.0.2 z niezmienionych źródeł, z libwebp 1.6.0 i zlib; bez `--enable-gpl`, więc na LGPL 2.1+. Build ma tylko składniki, których używa serwer (`--disable-everything` i lista w skrypcie, opisana w komentarzu), w bibliotekach wspólnych dla ffmpeg i ffprobe (`bin/` i `lib/`; binarki szukają bibliotek w `@executable_path/../lib`). Razem ok. 9 MB zamiast 45 MB dwóch pełnych statycznych binarek; ten sam zestaw składników statycznie zajmowałby 18 MB. Czas budowania ok. 1 minuty.

Lista wynika z wywołań w upstreamie: strumień HLS (demuxer concat, segmenty MPEG-TS, kopia albo koder `aac`), okładki (wyciąganie z pliku, zmiana rozmiaru do WebP/JPEG/PNG), osadzanie metadanych i rozdziałów (`ffmetadata`, muxer dla każdego obsługiwanego rozszerzenia), scalanie do M4B (kodery `aac` i `opus` z opcji w kliencie), podcasty (wejście przez potok, nie przez sieć — protokoły http/https są wyłączone), ffprobe. Dekodery obejmują formaty z `SupportedAudioTypes` (MP3, AAC/ALAC w MP4, FLAC, Opus, Vorbis, WMA, PCM, AC-3/E-AC-3, AMR, MP2) oraz obrazy i najczęstsze strumienie wideo, z których upstream bierze okładkę plików `.mp4/.webm/.mpg`. AudioToolbox i SecureTransport nie są już potrzebne.

**Test różnicowy** (przy zmianie listy składników albo wersji ffmpeg): `scripts/ffmpeg-diff/make-corpus.sh` tworzy pliki we wszystkich obsługiwanych formatach (wymaga ffmpeg z Homebrew), a `scripts/ffmpeg-diff/ffdiff.sh` uruchamia na nich wywołania takie jak w upstreamie. Wyniki pełnego buildu (np. dotychczasowego, zbudowanego bez `--disable-everything`) i odchudzonego porównuje się `diff`-em plików `results.txt`; muszą być identyczne. Dla 9.0.2 identyczne są wszystkie 264 testy (kody wyjścia i wyjście ffprobe).

Upstream oczekuje ffmpeg 5.1 (`BinaryManager.js`), ale przez API serwera sprawdzone na tym buildzie: skan i metadane (ffprobe), miniatury okładek WebP/JPEG, strumień HLS z kopiowaniem i z kodowaniem do AAC, osadzanie metadanych, scalanie do M4B (AAC). Nie działa opcja „OPUS” w narzędziu M4B: upstream wywołuje eksperymentalny koder `opus` bez `-strict -2`, co kończy się błędem na każdym ffmpeg.

## Licencja

AudiobookSwift jest wolnym oprogramowaniem na licencji **GPL-3.0-or-later** (plik `LICENSE`). To nie jest porada prawna, tylko przyjęte rozwiązanie: aplikacja jest rozprowadzana w jednej paczce z serwerem audiobookshelf (GPL-3.0), a jej skrypt `parent-watch.js` działa w procesie serwera.

Wydana paczka zawiera niezmienione komponenty innych autorów (Node.js i FFmpeg zbudowane z niezmienionych źródeł z mniejszym zestawem składników): audiobookshelf (GPL-3.0) z pakietami npm, Node.js (MIT i licencje dołączonych bibliotek), FFmpeg (LGPL-2.1+), libwebp (BSD-3-Clause), nunicode-sqlite (MIT). Lista jest w `AudiobookSwift/AudiobookSwift/Resources/THIRD-PARTY-NOTICES.txt` i w oknie „O programie”; pełne teksty licencji, adresy źródeł, sumy kontrolne i opcje budowania Node i ffmpeg trafiają do `Contents/Resources/Licenses` w paczce.

Rozprowadzanie binarek na GPL/LGPL wymaga udostępnienia odpowiadającego im kodu źródłowego. Dlatego **przed publikacją wydania** to repozytorium (z przypiętym submodule i skryptami budowania) musi być publicznie dostępne, a jego adres wpisany w klucz `ABSSourceURL` w `AudiobookSwift/Info.plist` — pokazuje go „O programie”, a `scripts/release.sh` ostrzega, gdy jest pusty.

Lista zgodności na [ffmpeg.org/legal.html](https://ffmpeg.org/legal.html) zaleca ponadto, by źródła FFmpeg leżały na tym samym serwerze co binarka. Obok pliku DMG warto więc opublikować archiwa `ffmpeg-9.0.2.tar.xz` i `libwebp-1.6.0.tar.gz` (adresy i sumy są w `scripts/build-ffmpeg.sh`), a nie tylko wskazać ffmpeg.org.
