# audiobookswift

Natywna aplikacja macOS (menu bar) uruchamiająca serwer [audiobookshelf](https://github.com/advplyr/audiobookshelf) bez Dockera, z prostym klientem iOS parowanym przez iCloud.

Serwer audiobookshelf jest dołączony jako git submodule (`vendor/audiobookshelf`) przypięty do tagu wydania i uruchamiany jako proces potomny aplikacji. Kod upstreamu nie jest modyfikowany.

## Budowanie i uruchamianie

Wymagania: Xcode 27 z zalogowanym kontem zespołu deweloperskiego `5TA8RF548P` (podpis i iCloud), ffmpeg i ffprobe z Homebrew (`brew install ffmpeg`), dostęp do sieci przy pierwszym budowaniu serwera.

```bash
git submodule update --init
scripts/build-server.sh
open AudiobookSwift/AudiobookSwift.xcodeproj
```

W Xcode uruchom schemat `AudiobookSwift`. Aplikacja nie ma ikony w Docku — pojawia się jako ikona książek na pasku menu. Serwer startuje razem z aplikacją; „Otwórz” pokazuje web UI audiobookshelf w oknie (zalogowane automatycznie).

### Codzienna obsługa

- **Pierwsze uruchomienie.** Na czystym serwerze aplikacja sama zakłada konto `root` z losowym hasłem zapisanym w pęku kluczy. Gdy serwer nie ma biblioteki, otwiera się ekran powitalny z przyciskiem wyboru folderu.
- **Dwa konta.** `root` służy tylko do obsługi serwera (biblioteki, klucze API). Do słuchania jest wymagane zwykłe konto użytkownika — formularz w oknie „Otwórz” i w oknie statusu (nazwa; hasło opcjonalne, puste = losowe w pęku kluczy; podanie hasła istniejącego konta je podpina). „Otwórz” loguje web UI na to konto, a klient iOS dostaje jego klucz API, więc postęp słuchania jest wspólny. **„Zarządzanie serwerem…”** w menu przełącza okno na konto root w sesji trzymanej tylko w pamięci; „Wróć do słuchania” albo zamknięcie okna kończy ten tryb.
- **Parowanie z iPhone’em** (okno statusu, domyślnie wyłączone) — zob. niżej.
- **Biblioteka.** „Dodaj folder z audiobookami…” (menu, ekran powitalny, okno statusu) otwiera systemowe okno wyboru folderu; aplikacja tworzy z niego bibliotekę typu „book” i czeka na koniec skanu. Kolejne foldery dają kolejne biblioteki.
- **Status i logi** (⌘L w menu): stan serwera, wersja audiobookshelf, adres, folder danych, biblioteki, log na żywo z kopiowaniem. Gdy serwer nie wstanie, okno otwiera się samo z czytelnym błędem (np. zajęty port 13378).
- **Uruchamiaj przy logowaniu** — przełącznik w menu i w oknie statusu (`SMAppService.mainApp`); odczytuje stan z systemu, więc zmiana w Ustawieniach systemowych → Ogólne → Rzeczy otwierane podczas logowania też jest widoczna.
- Jeśli serwer ma już konto root, a w pęku kluczy nie ma (aktualnego) hasła — np. folder danych zainicjalizowany wcześniej w web UI albo hasło zmienione w web UI — okno statusu prosi o nie i zapisuje je w pęku kluczy.

### Test na czystym folderze danych

Domyślny folder danych można podmienić argumentem uruchomienia (w Xcode: Edit Scheme → Run → Arguments):

```bash
open AudiobookSwift.app --args -ABSDataRoot /tmp/abs-test -ABSPort 13400
```

`-ABSPort` pozwala uruchomić test obok działającej kopii na 13378. Sekrety są w pęku kluczy pod kontem równym ścieżce folderu danych, a identyfikator serwera i ustawienia parowania w `pairing.json` w folderze danych, więc test nie nadpisze prawdziwych danych ani prawdziwego rekordu w iCloud.

### Podpis, iCloud i pęk kluczy

- Pakiet `net.smigi.abswift`, zespół `5TA8RF548P`, podpis automatyczny (`xcodebuild … -allowProvisioningUpdates` albo Xcode). Entitlements: kontener `iCloud.net.smigi.abswift` z usługą CloudKit i grupa pęku kluczy. Klient iOS użyje tego samego kontenera.
- Sekrety leżą w pęku kluczy z ochroną danych (dostęp wynika z podpisu, bez pytań po przebudowaniu): `net.smigi.abswift.server-root` (root), `.server-user` (użytkownik), `.pairing-token` (klucz API klienta iOS). Hasło roota z etapów 1–2 (klasyczny pęk, usługa `com.audiobookswift.server-root`) jest przenoszone przy pierwszym odczycie — macOS zapyta wtedy raz o zgodę.
- Zmiana identyfikatora pakietu oznacza, że „Uruchamiaj przy logowaniu” trzeba włączyć ponownie.
- Kompilacje deweloperskie używają środowiska **Development** CloudKit. Typ rekordu `Server` powstaje tam sam przy pierwszym zapisie; przed dystrybucją (etap 6) schemat trzeba wdrożyć do Production w konsoli CloudKit.

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
- `AudiobookSwift/AudiobookSwift/Pairing/` — parowanie: `PairingRecord.swift` (model rekordu i stałe, bez zależności od macOS), `PairingCloudStore.swift` (zapis, usuwanie i odczyt w CloudKit; też dla iOS), `PairingController.swift` (logika po stronie Maca), `BonjourAdvertiser.swift`, `LocalNetwork.swift`, `PairingSettings.swift`, `PairingSelfCheck.swift`.
- Serwer słucha na `http://127.0.0.1:13378/audiobookshelf/` (tylko pętla zwrotna), a przy włączonym parowaniu na wszystkich interfejsach. Aplikacja zawsze łączy się przez pętlę zwrotną.
- Dane serwera (baza, konfiguracja, metadane, logi): `~/Library/Application Support/AudiobookSwift/`.

## Parowanie z klientem iOS (etap 3)

Przełącznik „Udostępniaj serwer w sieci lokalnej i paruj przez iCloud” w oknie statusu (wymaga konta użytkownika) robi trzy rzeczy; wyłączenie cofa wszystkie:

1. **Sieć lokalna.** Serwer jest restartowany bez `HOST`, czyli słucha na wszystkich interfejsach. Ruch idzie zwykłym HTTP — token i treść są widoczne dla innych urządzeń w tej samej sieci (świadoma decyzja na tym etapie; HTTPS i dostęp spoza domu są poza zakresem). Po wyłączeniu serwer wraca na `127.0.0.1`.
2. **Token.** Aplikacja wydaje klucz API (`POST /api/api-keys`) dla konta użytkownika — nigdy roota. Klucz API w audiobookshelf ma dokładnie uprawnienia swojego użytkownika (brak zakresów), nie wygasa i przestaje działać po usunięciu. „Unieważnij…” usuwa klucz i wydaje nowy; wyłączenie parowania usuwa klucz.
3. **Rekord w iCloud i Bonjour.** Rekord jest zapisywany przy starcie, po zmianie sieci (z 2 s opóźnieniem), tokenu albo adresu zewnętrznego, a przy wyłączeniu parowania usuwany. Bez konta iCloud udostępnianie w sieci lokalnej i Bonjour działają dalej, a okno statusu mówi, co zrobić.

### Schemat rekordu (dla etapu 4)

Prywatna baza kontenera `iCloud.net.smigi.abswift`, strefa `Pairing`, typ rekordu `Server`, nazwa rekordu = identyfikator serwera. Klient pobiera rekordy przez `PairingCloudStore.fetchAll()` (zmiany strefy — bez indeksów i zapytań) i dostaje `PairingRecord`.

| Pole | Typ | Znaczenie |
| --- | --- | --- |
| *nazwa rekordu* | String | `serverID`: stały UUID serwera (jeden na folder danych) |
| `version` | Int | wersja schematu, obecnie `1`; rekordy w innej wersji klient pomija |
| `name` | String | nazwa Maca do pokazania użytkownikowi |
| `localHostName` | String | nazwa mDNS, np. `mini.local` (może być pusta) |
| `addresses` | [String] | adresy IPv4 Maca w sieci lokalnej (brak pola = brak adresów) |
| `port` | Int | port serwera |
| `basePath` | String | ścieżka bazowa, np. `/audiobookshelf` |
| `serverVersion` | String | wersja audiobookshelf |
| `username` | String | konto, do którego należy token |
| `externalURL` | String | pełny adres spoza sieci lokalnej razem ze ścieżką bazową; pusty, dopóki użytkownik go nie wpisze |
| `token` | String, **`encryptedValues`** | klucz API; nagłówek `Authorization: Bearer <token>` |
| `updatedAt` | Date | czas zapisu |

`PairingRecord.candidateURLs` zwraca adresy bazowe API w kolejności prób: `http://<localHostName>:<port><basePath>`, potem adresy IP, na końcu `externalURL`. Token sprawdza `GET <baza>/api/me` (`AudiobookshelfClient.me`): 401 oznacza, że został unieważniony i trzeba ponownie pobrać rekord.

**Bonjour:** usługa `_abswift._tcp` na porcie serwera, nazwa = nazwa komputera, TXT: `id=<serverID>`, `path=<basePath>`, `v=1`. Klient dopasowuje znalezioną usługę do rekordu po `id`; w TXT nie ma tokenu. Aplikacja iOS musi zadeklarować `NSBonjourServices` z `_abswift._tcp` i `NSLocalNetworkUsageDescription`.

### Niezależne sprawdzenie

```bash
AudiobookSwift.app/Contents/MacOS/AudiobookSwift -ABSPairingCheck YES
dns-sd -B _abswift._tcp local.
```

Pierwsze polecenie w osobnym procesie pobiera rekordy z CloudKit, wypisuje je bez tokenu i sprawdza tokenem każdy adres. Z dodatkowym `-ABSPairingCheckRevocation YES` czeka na zmianę tokenu w iCloud i pokazuje, że stary jest odrzucany (401), a nowy działa.

### API audiobookshelf, z którego korzystamy (v2.38.0)

Ustalone w kodzie upstreamu (`server/Server.js`, `server/Auth.js`, `server/auth/TokenManager.js`, `server/controllers/LibraryController.js`):

- `GET /status` — `serverVersion`, `isInit` (czy istnieje root). Bez uwierzytelnienia.
- `POST /init` z `{"newRoot": {"username", "password"}}` — tylko gdy nie ma roota.
- `POST /login` (`username`, `password`) — `user.accessToken` (JWT, 1 h). Z nagłówkiem `x-return-tokens: true` także `user.refreshToken` (30 dni); bez niego refresh token trafia do ciasteczka `refresh_token`. Refresh tokeny są rotowane przy `POST /auth/refresh`, więc web UI dostaje osobną sesję. Limit: 40 prób logowania na 10 minut.
- `POST /api/libraries` (admin) z `name`, `folders: [{fullPath}]`, `mediaType` — tworzy bibliotekę, ale **jej nie skanuje**.
- `POST /api/libraries/:id/scan` odpowiada od razu; skan trwa jako zadanie `library-scan` widoczne w `GET /api/tasks`, a po końcu znika z listy. Liczba pozycji: `GET /api/libraries/:id/items?limit=1` → `total`.
- `POST /api/users` (admin) z `username`, `password`, `type: "user"`, `isActive: true` — zwykłe konto (bez `isActive` powstaje nieaktywne). Zajęta nazwa: 400.
- `POST /api/api-keys` (admin) z `name`, `userId`, `isActive: true` — klucz API (JWT typu `api`, bez terminu, jeśli nie podać `expiresIn`); token jest w odpowiedzi tylko raz (`apiKey.apiKey`). Uwierzytelnia jako wskazany użytkownik (`server/auth/TokenManager.js`), także w gnieździe socket.io. `DELETE /api/api-keys/:id` unieważnia go natychmiast.
- `GET /api/me` — użytkownik, do którego należy token.
- Web UI trzyma access token w `localStorage['token']` i wczytuje użytkownika tylko na stronie `/login` (`checkAuth`), dlatego automatyczne logowanie ładuje `/login`.

## Licencja

audiobookshelf jest na licencji GPL-3.0.
