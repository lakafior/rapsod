# Wydanie i aktualizacje

Budowanie podpisanego i notaryzowanego DMG, publikacja na GitHubie, wersje, automatyczne aktualizacje i zawartość paczki (Node, ffmpeg).

## Wydanie

Wydanie to plik `Rapsod-<wersja>.dmg`: aplikacja podpisana Developer ID z hardened runtime, notaryzowana, z biletem zszytym z aplikacją i z obrazem dysku. Zawiera Node, serwer audiobookshelf z klientem web, ffmpeg, ffprobe i rozszerzenie SQLite — działa bez repozytorium, Homebrew i Node w systemie. Tylko Apple Silicon, macOS 27 lub nowszy (`MACOSX_DEPLOYMENT_TARGET`).

### Jednorazowa konfiguracja

1. W pęku kluczy musi być tożsamość „Developer ID Application: … (5TA8RF548P)” (Xcode → Settings → Accounts → Manage Certificates → „+” → Developer ID Application).
2. Konto zespołu zalogowane w Xcode — eksport z podpisem automatycznym tworzy przy pierwszym wydaniu profil aprowizacji Developer ID dla `net.smigi.rapsod` (grupa pęku kluczy jest uprawnieniem wymagającym profilu).
3. Profil `notarytool`:
   - na [account.apple.com](https://account.apple.com) → Logowanie i bezpieczeństwo → Hasła do aplikacji utwórz hasło (np. o nazwie `notarytool`);
   - zapisz je w pęku kluczy — polecenie zapyta o hasło, nie podawaj go w argumentach:
     ```bash
     xcrun notarytool store-credentials rapsod-notary --apple-id <twój Apple ID> --team-id 5TA8RF548P
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
7. sprawdza wynik: `codesign --verify --deep --strict`, `stapler validate`, `spctl --assess` dla aplikacji i DMG;
8. zapisuje sumę SHA-256 obok DMG (`Rapsod-<wersja>.dmg.sha256`, format `shasum -a 256`);
9. z `--publish`: tworzy wydanie `v<wersja>` w `lakafior/rapsod` (`gh release create`) z DMG i plikiem sumy — z niego aplikacje pobierają aktualizację (zob. „Aktualizacje aplikacji”).

Wynik: `build/release/Rapsod-<wersja>.dmg` i `.dmg.sha256` (plików nie commitujemy). `scripts/release.sh --skip-notarize` robi wszystko poza notaryzacją — do testów lokalnych, nie do publikacji. `ABS_MARKETING_VERSION=1.0.1 scripts/release.sh` buduje inną wersję bez zmiany projektu (np. wydanie testowe aktualizacji).

Publikacja (wymaga `gh` zalogowanego do GitHuba, czystego drzewa, wypchniętego commita i nowej wersji w `MARKETING_VERSION`):

```bash
ABS_RELEASE_NOTES=zmiany.md scripts/release.sh --publish
```

Opis zmian w Markdown z `ABS_RELEASE_NOTES` trafia do okna aktualizacji w aplikacji; bez niego GitHub składa notatki z commitów. Skrypt sprawdza warunki publikacji przed buildem, odmawia z `--skip-notarize` i przy istniejącym znaczniku. Inne repozytorium wydań: `ABS_RELEASE_REPO`.

### Wersje

- Wersja aplikacji to `MARKETING_VERSION` w projekcie (własna numeracja, niezależna od audiobookshelf). Numer builda to liczba commitów (`ABS_BUILD_NUMBER` go nadpisuje).
- Wersję audiobookshelf pokazują ustawienia (podstrona „Ogólne”) i „O programie”; dokładne wersje wszystkich składników są w `Contents/Resources/Licenses/VERSIONS.txt`.
- Nowa wersja audiobookshelf u użytkowników = nowe wydanie aplikacji po „Podbiciu wersji audiobookshelf” (wyżej), które aplikacja zainstaluje sama (zob. niżej); dane w `~/Library/Application Support/Rapsod/` i pęk kluczy zostają.
- Aplikacja porównuje tylko wersję (`CFBundleShortVersionString` ze znacznikiem `v<wersja>`), więc każde publikowane wydanie potrzebuje nowej `MARKETING_VERSION`; sam numer builda nie wystarczy.
- Migracje bazy uruchamia sam upstream przy starcie (`server/managers/MigrationManager.js`): przed migracją kopiuje bazę do `absdatabase.backup.sqlite`, a przy błędzie przywraca kopię, zostawia nieudaną jako `absdatabase.failed.sqlite` i kończy proces. Starsza wersja serwera na nowszej bazie wykonuje migracje wstecz. Automatyczne kopie zapasowe upstreamu są domyślnie wyłączone — włącza się je w Ustawieniach aplikacji → Kopie zapasowe.

### Aktualizacje aplikacji (etap 14b)

Własny mechanizm bez Sparkle i bez zależności: kod w `Rapsod/Rapsod/Updates/` i części testowalnej `RapsodUpdates` w pakiecie `Packages/AudiobookshelfKit` (wersje, odpowiedź API, wybór zasobu, plik sumy, skrypt podmiany; `swift test --filter 'AppVersion|AppUpdate|Checksum|UpdatePolicy|SwapScript'`).

- **Źródło:** `https://api.github.com/repos/lakafior/rapsod/releases/latest`, anonimowo. **Repozytorium musi być publiczne** — prywatnego wydania anonimowe API nie zwraca (404, aplikacja uznaje to za „brak wydań”). Wydania próbne i szkice są pomijane.
- **Kiedy:** przy starcie (po 15 s) i raz na dobę, jeśli włączone „Sprawdzaj aktualizacje automatycznie” w Ustawieniach → Ogólne → Aplikacja (domyślnie tak); na żądanie „Sprawdź aktualizacje…” w menu aplikacji i w menu na pasku menu. Gdy czeka nowa wersja, ta sama pozycja menu brzmi „Zainstaluj Rapsod <wersja>…”.
- **Okno „Aktualizacja Rapsodu”:** opis zmian z wydania (Markdown: nagłówki, listy, formatowanie w wierszu), „Zainstaluj i uruchom ponownie”, „Przypomnij później” (automatycznie znów po dobie), „Pomiń tę wersję” (automatycznie nie wraca; ręczne sprawdzenie pokazuje ją dalej). Automatyczne sprawdzenie otwiera okno samo. Powiadomienie systemowe zostawia etap 14e: punktem zaczepienia jest `UpdateController.onUpdateFound`.
- **Wymagania wydania** (spełnia je `scripts/release.sh --publish`): znacznik `v<wersja>`, zasób `Rapsod-<wersja>.dmg` i `Rapsod-<wersja>.dmg.sha256` (albo `SHA256SUMS`). Plik z dopiskiem `-nienotaryzowany` nigdy nie jest brany.
- **Weryfikacja przed instalacją** (każdy krok musi przejść): suma SHA-256 z pliku sumy; podpis DMG certyfikatem Developer ID tego samego zespołu (Team ID odczytany z podpisu uruchomionej aplikacji, `SecCodeCopySelf`) i `spctl --assess --type open` (notaryzacja); po zamontowaniu (`hdiutil attach -nobrowse -readonly`) i skopiowaniu `ditto` obok bieżącej aplikacji jako ukryte `.Rapsod-aktualizacja.app` — na kopii: `SecStaticCodeCheckValidity` ściśle, z kodem zagnieżdżonym, z wymaganiem jak wyznaczone w wydaniu (identyfikator `net.smigi.rapsod`, Developer ID, zespół), `spctl --assess --type execute`, identyfikator pakietu i wersja z `Info.plist` równa wersji wydania i wyższa od uruchomionej. Build bez Team ID (podpis ad hoc) nie instaluje niczego.
- **Podmiana:** po weryfikacji aplikacja kończy się jak zwykłe „Zakończ” (pozycja słuchania, tunel, źródła metadanych i serwer zatrzymane). W `applicationWillTerminate` startuje `/bin/sh` ze skryptem `SwapScript` (ścieżki jako argumenty pozycyjne): czeka na koniec procesu (do 2 minut), przenosi bieżący pakiet na `.Rapsod-poprzednia.app`, nową kopię na jego miejsce (oba `rename` w tym samym folderze; gdy drugi zawiedzie — przywraca poprzedni), usuwa stary i uruchamia aplikację `open -n` z tymi samymi argumentami. Log: `~/Library/Logs/Rapsod/aktualizacja.log`. Atrybutów nie dodajemy ani nie zdejmujemy: pobranie przez `URLSession` nie nakłada kwarantanny, `ditto` zachowuje podpis i bilet notaryzacji, więc Gatekeeper nie pyta przy ponownym uruchomieniu.
- **Kiedy się nie da:** aplikacja uruchomiona z miejsca tymczasowego (App Translocation, czyli prosto z pobranego pliku), z obrazu dysku albo woluminu tylko do odczytu, albo bez prawa zapisu do folderu aplikacji (np. konto standardowe i `/Applications`) — okno mówi, co zrobić, i podaje stronę wydania do ręcznej instalacji.
- **Test bez GitHuba:** argument `-RapsodUpdateFeedURL http://127.0.0.1:<port>/latest.json` zmienia tylko źródło odpowiedzi API (np. plik JSON z `python3 -m http.server`, adresy zasobów też lokalne); weryfikacja zostaje taka sama, więc DMG musi być notaryzowany. Przebieg sprawdzony 2026-11-26 — zob. ROADMAP, wpis 14b.

### Podpis i uprawnienia runtime

- Aplikacja: hardened runtime, bez sandboxa; uprawnienia tylko te, które nadaje profil (identyfikator aplikacji, zespół, grupa pęku kluczy `5TA8RF548P.net.smigi.rapsod`). Ta sama grupa co w buildach z Xcode, więc wydana aplikacja czyta istniejące pozycje pęku kluczy.
- `node`: jedno uprawnienie, `com.apple.security.cs.allow-jit` (`packaging/node.entitlements`). Silnik V8 rezerwuje pamięć wykonywalną dla JIT; bez tego uprawnienia Node pod hardened runtime kończy się przy starcie błędem „Failed to reserve virtual memory for CodeRange”. Pozostałe uprawnienia z oficjalnej binarki Node (`allow-unsigned-executable-memory`, `disable-executable-page-protection`, `disable-library-validation`, `allow-dyld-environment-variables`) nie są potrzebne: moduł `node_sqlite3.node` i `libnusqlite3.dylib` są podpisane tym samym zespołem, więc przechodzą walidację bibliotek.
- `ffmpeg`, `ffprobe`, biblioteki w `ffmpeg/lib`, `node_sqlite3.node`, `libnusqlite3.dylib`: hardened runtime bez uprawnień. Biblioteki ffmpeg są podpisane tym samym zespołem co binarki, więc przechodzą walidację bibliotek bez `disable-library-validation`.

### Node w paczce

`scripts/build-node.sh` kompiluje Node.js (wersja z `scripts/node-version.sh`) z niezmienionych źródeł z nodejs.org z mniejszym zestawem składników: dane ICU tylko dla angielskiego i polskiego (`--with-intl=small-icu --with-icu-locales=en,pl`), bez inspektora (`--inspect`) i bez npm, corepack, amaro i `node:sqlite`, a potem `strip -x`. Wynik: ok. 62 MB zamiast 122 MB oficjalnej binarki.

Co zostaje, bo serwer tego używa (sprawdzone w kodzie upstreamu i testem porównawczym z oficjalną binarką): `Intl.Collator` z opcjami `numeric` i `sensitivity` (sortowanie w pamięci, porównanie wersji przy migracjach), `normalize` (NFC nazw plików, usuwanie diakrytyków przy dopasowaniu metadanych), strefa czasowa systemu, OpenSSL (JWT, OIDC, TLS dla podcastów i dostawców metadanych), WebAssembly (`node-unrar-js`, libarchive dla komiksów), `worker_threads`, zlib i N-API (moduł `sqlite3`). Polski jest w danych ICU, bo aplikacja przekazuje serwerowi `LANG` użytkownika, a serwer sortuje według domyślnego języka procesu. Pełny `strip` (zamiast `strip -x`) usuwa symbole N-API i moduł `sqlite3` przestaje się ładować.

Czysta kompilacja trwa ok. 30 minut (10 rdzeni) i wymaga Pythona 3.9–3.14 (wystarczy systemowy `/usr/bin/python3`). Wynik trafia do pamięci podręcznej wspólnej dla wszystkich kopii repozytorium, `~/Library/Caches/Rapsod-build/node-<wersja>-<skrót opcji>` (inne miejsce: zmienna `ABS_BUILD_CACHE`), a stamtąd do `build/node-runtime`. Kolejne wydania i nowe worktree tylko kopiują plik; kompilacja wraca po zmianie wersji Node, opcji albo kompilatora. `scripts/build-node.sh --clean` wymusza ją od razu.

### ffmpeg

`scripts/build-ffmpeg.sh` kompiluje ffmpeg 9.0.2 z niezmienionych źródeł, z libwebp 1.6.0 i zlib; bez `--enable-gpl`, więc na LGPL 2.1+. Build ma tylko składniki, których używa serwer (`--disable-everything` i lista w skrypcie, opisana w komentarzu), w bibliotekach wspólnych dla ffmpeg i ffprobe (`bin/` i `lib/`; binarki szukają bibliotek w `@executable_path/../lib`). Razem ok. 9 MB zamiast 45 MB dwóch pełnych statycznych binarek; ten sam zestaw składników statycznie zajmowałby 18 MB. Czas budowania ok. 1 minuty.

Lista wynika z wywołań w upstreamie: strumień HLS (demuxer concat, segmenty MPEG-TS, kopia albo koder `aac`), okładki (wyciąganie z pliku, zmiana rozmiaru do WebP/JPEG/PNG), osadzanie metadanych i rozdziałów (`ffmetadata`, muxer dla każdego obsługiwanego rozszerzenia), scalanie do M4B (kodery `aac` i `opus` z opcji w kliencie), podcasty (wejście przez potok, nie przez sieć — protokoły http/https są wyłączone), ffprobe. Dekodery obejmują formaty z `SupportedAudioTypes` (MP3, AAC/ALAC w MP4, FLAC, Opus, Vorbis, WMA, PCM, AC-3/E-AC-3, AMR, MP2) oraz obrazy i najczęstsze strumienie wideo, z których upstream bierze okładkę plików `.mp4/.webm/.mpg`. AudioToolbox i SecureTransport nie są już potrzebne.

**Test różnicowy** (przy zmianie listy składników albo wersji ffmpeg): `scripts/ffmpeg-diff/make-corpus.sh` tworzy pliki we wszystkich obsługiwanych formatach (wymaga ffmpeg z Homebrew), a `scripts/ffmpeg-diff/ffdiff.sh` uruchamia na nich wywołania takie jak w upstreamie. Wyniki pełnego buildu (np. dotychczasowego, zbudowanego bez `--disable-everything`) i odchudzonego porównuje się `diff`-em plików `results.txt`; muszą być identyczne. Dla 9.0.2 identyczne są wszystkie 264 testy (kody wyjścia i wyjście ffprobe).

Upstream oczekuje ffmpeg 5.1 (`BinaryManager.js`), ale przez API serwera sprawdzone na tym buildzie: skan i metadane (ffprobe), miniatury okładek WebP/JPEG, strumień HLS z kopiowaniem i z kodowaniem do AAC, osadzanie metadanych, scalanie do M4B (AAC). Nie działa opcja „OPUS” w narzędziu M4B: upstream wywołuje eksperymentalny koder `opus` bez `-strict -2`, co kończy się błędem na każdym ffmpeg.
