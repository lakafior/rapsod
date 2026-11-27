# Telefon i dostęp spoza domu

Łączenie telefonów z serwerem w sieci domowej i spoza domu (własny adres albo Cloudflare Tunnel) oraz API audiobookshelf, z którego korzysta aplikacja.

## Połączenie z telefonu (etap 3)

Dowolny klient audiobookshelf łączy się z serwerem, podając adres serwera oraz nazwę i hasło konta użytkownika. Aplikacja niczego nie ogłasza w sieci i niczego nie wysyła poza Maca.

- **Sieć lokalna.** Przełącznik „Udostępniaj serwer w sieci lokalnej” (wymaga konta użytkownika, więc także istniejącego roota) restartuje serwer bez `HOST`, czyli z nasłuchem na wszystkich interfejsach. Sekcja pokazuje wtedy adresy `http://<nazwa>.local:13378` i `http://<IPv4>:13378`, odświeżane po zmianie sieci. Ścieżki `/audiobookshelf` nie trzeba wpisywać: upstream sam dopisuje `ROUTER_BASE_PATH` do żądań, które jej nie mają (adres ze ścieżką też działa). Wyłączenie przywraca nasłuch tylko na `127.0.0.1`.
- **Zwykły HTTP.** Ruch w sieci lokalnej nie jest szyfrowany: hasło i treść są widoczne dla innych urządzeń w tej samej sieci (świadoma decyzja; HTTPS jest poza zakresem).
- **Dostęp spoza domu** — opisany niżej (etap 4).
- **Kod QR tylko dla własnej aplikacji.** Oficjalna aplikacja (`advplyr/audiobookshelf-app`, stan z 2026-11-19) nie ma dodawania serwera z kodu QR ani z linku — schemat `audiobookshelf://` obsługuje wyłącznie powrót z logowania OpenID. Inne klienty dostają więc adres, nazwę i hasło; własna aplikacja Rapsod na iOS paruje się kodem QR (etap 10b, niżej).

## Dostęp spoza domu (etap 4)

Opcjonalny i niezależny od dostawcy. W sekcji „Połącz telefon” wybiera się jeden z trybów; wynikiem jest jeden „adres spoza domu” pokazywany obok danych logowania:

- **Brak** (domyślnie) — tylko ten Mac i ewentualnie sieć lokalna.
- **Własny adres** — dowolny adres wpisany ręcznie (Tailscale, własny tunel, VPN). Aplikacja niczego pod nim nie zestawia.
- **Cloudflare Tunnel** — aplikacja sama uruchamia i pilnuje `cloudflared`. Tunel kieruje ruch na `127.0.0.1`, więc nie wymaga udostępniania w sieci lokalnej (oba ustawienia są niezależne).

Tryb jest zapisany w `sharing.json` (pole `externalAccess`; stary plik z wpisanym adresem oznacza „własny adres”).

### Cloudflare Tunnel: konfiguracja w panelu (raz)

Wariant: tunel zarządzany zdalnie, uruchamiany tokenem. Wymaga konta Cloudflare i domeny dodanej do Cloudflare (stały adres `https://<nazwa>.<twoja-domena>`). Szybkie tunele `trycloudflare.com` odpadają, bo adres zmienia się przy każdym starcie; tunel tworzony lokalnie (`cloudflared tunnel login`) trzyma poświadczenia w plikach w `~/.cloudflared`.

1. Zainstaluj `cloudflared`: oficjalny instalator `cloudflared-arm64.pkg` ze [strony wydań](https://github.com/cloudflare/cloudflared/releases) (instaluje do `/usr/local/bin`) albo `brew install cloudflared`. Aplikacja celowo nie zawiera własnej kopii — szuka go w `/usr/local/bin` i `/opt/homebrew/bin`; bez `cloudflared` opcja pokazuje tę wskazówkę, a reszta aplikacji działa.
2. Panel Cloudflare → **Networking → Tunnels → Create tunnel** → typ **Cloudflared**, dowolna nazwa (np. `rapsod`).
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
- `POST /api/users` (admin) z `username`, `password`, `type: "user"`, `isActive: true` — zwykłe konto (bez `isActive` powstaje nieaktywne). Zajęta nazwa: 400. Pozostałe punkty administracji (kopie, ustawienia, użytkownicy, skan) opisuje sekcja „Administracja serwera”.
- `GET /api/me` — użytkownik, do którego należy token (`type`: `root`, `admin`, `user`, `guest`).
- Web UI trzyma access token w `localStorage['token']` i wczytuje użytkownika tylko na stronie `/login` (`checkAuth`), dlatego automatyczne logowanie ładuje `/login`.
