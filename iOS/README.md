# AudiobookSwift na iOS

Klient iOS (iOS 27, Swift 6, SwiftUI) dla serwera audiobookshelf uruchamianego przez
aplikację AudiobookSwift na Macu. Licencja **MPL-2.0** (`LICENSE`), tak jak wspólny pakiet
`Packages/AudiobookshelfKit`, z którego korzysta. Nie zawiera kodu aplikacji na Maca (GPL-3.0)
ani kodu przetłumaczonego ze źródeł audiobookshelf — rozmawia z serwerem wyłącznie przez jego API.

Osobny projekt (`AudiobookSwiftiOS.xcodeproj`), a nie cel w projekcie Maca: schematy projektu
Maca są generowane automatycznie, a `scripts/release.sh` buduje go po nazwie schematu — osobny
projekt nie może niczego tam zmienić; granica licencji przebiega też po granicy projektu.

Etap 10b: parowanie z Makiem kodem QR (`abswift://pair?d=…`, format w `PairingPayload`
pakietu) albo ręcznie (adres i klucz API), wybór działającego adresu (najpierw sieć lokalna,
potem dostęp spoza domu), klucz w pęku kluczy iOS oraz prosty ekran z bibliotekami i okładkami.

Etap 10c: odtwarzanie strumienia z serwera (cel pakietu `AudiobookshelfPlayback`): strona
pozycji z „Odtwarzaj”/„Kontynuuj”, „Słuchaj dalej”, pasek mini-odtwarzacza i pełny ekran,
sesja audio iOS z odtwarzaniem w tle, przerwaniami i odłączaniem słuchawek, „Teraz odtwarzane”
i sterowanie z ekranu blokady, synchronizacja postępu z serwerem (wspólny z Makiem). Wybór
adresu zawsze od sieci lokalnej, ponawiany przy zmianie sieci i po błędzie połączenia.
Szczegóły w głównym `README.md` („Odtwarzacz na iOS”).

Etap 10d: docelowy układ z zakładkami (Start, Audiobooki, Podcasty, Szukaj,
Ustawienia; na iPadzie także pasek boczny) i mini-odtwarzaczem nad paskiem zakładek. Zakładka
„Audiobooki” łączy wszystkie biblioteki książek w jedną listę (scalanie stron w pakiecie,
`CombinedLibraries`), z sortowaniem, filtrem, seriami i autorami bez powtórzeń; wspólne półki
Startu, wyszukiwanie we wszystkich bibliotekach, strony serii, autora i lektora oraz rozbudowana
strona pozycji z rozdziałami. Szczegóły w głównym `README.md` („Zakładki i wspólna biblioteka
książek na iOS”).

Etap 10e: zakładka „Podcasty” ze wszystkich bibliotek podcastów i strona podcastu, która obok
odcinków z serwera pokazuje odcinki z kanału RSS (czytanego przez telefon) ze stanem: na serwerze,
tylko w kanale, pobierany, w kolejce. Odcinek spoza serwera gra od razu ze strumienia wydawcy,
a serwer może go w tym czasie pobrać (wymaga typu administratora i „Edycji pozycji” dla konta
telefonu); postęp takiego odcinka zostaje na telefonie i przechodzi na serwer po pobraniu.
Szczegóły w głównym `README.md` („Podcasty na iOS”).

Etap 10f: pobieranie książek i odcinków z serwera na telefon (sesja tła `URLSession`, domyślnie
tylko w sieci domowej przez Wi-Fi; tunel do włączenia w Ustawieniach) i słuchanie bez sieci —
pobrane grają z plików, a bez połączenia Start i zakładki pokazują to, co jest na telefonie.
Postęp zapisuje się w trwałym dzienniku na telefonie i po powrocie połączenia idzie na serwer
(sesje lokalne do statystyk; nowszy zapis z innego urządzenia wygrywa). Szczegóły w głównym
`README.md` („Pobieranie na telefon i słuchanie bez sieci”).

Etap 10i: porządki i nowy wygląd pod iOS 27 (Liquid Glass) — wspólne komponenty
(`DesignSystem.swift`), Start z jedną półką „Słuchaj dalej” (książki i odcinki razem, bez
powtórzeń — naprawiony błąd z dwa razy tym samym odcinkiem) i półkami poziomymi z pełnymi
listami, strona pozycji i podcastu z tłem z okładki (na iPadzie dwie kolumny), Audiobooki z
kategoriami (serie, autorzy, lektorzy, kolekcje, playlisty, pobrane) i widokiem siatka/lista,
pełnoekranowy odtwarzacz wysuwany z mini-odtwarzacza. Kolor akcentu z ikony. Szczegóły w głównym
`README.md` („Wygląd klienta iOS”).

Etap 11b: tryb „Tekst” w pełnoekranowym odtwarzaczu — tekst książki z EPUB-a z podświetlonym
bieżącym zdaniem przewijanym za nagraniem, dotknięcie zdania przenosi odtwarzanie, ręczne
przewinięcie z „Wróć do bieżącego miejsca”, krój i rozmiar w menu „Aa”. Mapę tekstu liczy Mac
(„Synchronizuj e-book”), telefon ją pobiera, także razem z książką do słuchania bez sieci. Model
we wspólnym pakiecie (`TextFollowModel`, `TextSyncDocument`). Przy okazji: lista „Audiobooki”
zostaje na miejscu po powrocie z podstrony, a strona pozycji nie przerysowuje się przy każdej
synchronizacji postępu. Szczegóły w głównym `README.md` („Tekst w odtwarzaczu”).

Etap 11d: płynny ruch trybu „Tekst” — skład CoreText i ruch ze wspólnego `TextFlowController`
(pakiet), widok to `BookTextCanvas` (`UIScrollView` z warstwami wierszy): przewijanie o wiersz,
gdy lektor do niego dochodzi, jedną ciągłą animacją; jasność zdań zmienia tylko krycie nakładki
(układ się nie zmienia); bez okna akapitów i bez późniejszych korekt po przeskoku. Tryb pokazowy
(tylko Debug) do nagrań i pomiarów bez serwera: `xcrun simctl launch booted net.smigi.abswift.ios
-BookTextDemo <folder z *.m4a i *.sync.json> [-BookTextDemoStart s] [-BookTextDemoRate r]
[-BookTextDemoScript plik]`. Szczegóły w głównym `README.md` („Płynny ruch tekstu”).

Etap 13a: segmenty sponsorowane w podcastach — znaczniki pod suwakiem, automatyczne pomijanie
z „Cofnij” (komunikat w pełnym odtwarzaczu, „Cofnij” też w mini-odtwarzaczu), „Pomiń” po
przewinięciu w środek segmentu, lista segmentów z poprawkami (zapisywanymi na telefonie) i
ustawienie per podcast w pasku strony podcastu. Znaczniki: z serwera (liczy je Mac po pobraniu
odcinka), pobrane razem z odcinkiem (działają bez sieci), a dla odcinków prosto z kanału —
liczone na telefonie z opisu odcinka (`SkipSupport.swift`, `SkipViews.swift`). Szczegóły w
głównym `README.md` („Segmenty sponsorowane w podcastach”).

Etap 10g: czytnik e-booków — „Czytaj” na stronie pozycji (i „Czytaj e-book” na liście „Pobrane”),
EPUB w WKWebView z epub.js 0.3.93 (BSD-2-Clause) i JSZip 3.10.1 (MIT; noty w
`AudiobookSwiftiOS/Reader/THIRD-PARTY-NOTICES.txt`, dołączone do aplikacji), PDF w PDFKit. Pozycja
czytania w tym samym zapisie co czytnik Maca i web UI (CFI epub.js / numer strony), zapamiętywana
też na telefonie do czytania bez sieci; e-book pobiera się razem z książką. Treść książki bez
skryptów i bez sieci. MOBI i inne formaty — komunikat o braku obsługi. Szczegóły w głównym
`README.md` („Czytnik e-booków na iOS”).
