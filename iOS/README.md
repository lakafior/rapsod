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
