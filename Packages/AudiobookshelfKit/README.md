# AudiobookshelfKit

Wspólny pakiet Swift aplikacji Rapsod na Maca i klienta iOS: klient HTTP API serwera
[audiobookshelf](https://github.com/advplyr/audiobookshelf) z modelami i punktami API, zdarzenia
serwera (Socket.IO), odnawianie tokenów kilku kont naraz (hasło albo klucz API, sekrety za
protokołem `SecretStore`) i pamięć okładek (`PlatformImage`: `NSImage`/`UIImage`).

## Licencja

Pakiet jest na licencji **Mozilla Public License 2.0** (`LICENSE` w tym folderze), bez noty
„Incompatible With Secondary Licenses”. Aplikacja na Maca w tym repozytorium jest na GPL-3.0
(główny `LICENSE`); MPL-2.0 pozwala połączyć z nią pakiet.

Pakiet zawiera wyłącznie kod napisany w tym projekcie. Wywołania punktów API i kształty odpowiedzi
opisują protokół serwera audiobookshelf (GPL-3.0), ale kod nie jest z niego skopiowany ani
przetłumaczony. Reguły przetłumaczone z klienta web audiobookshelf (rozpoznawanie książek
w upuszczonym folderze, nazwa folderu podcastu, czyszczenie adresu odcinka, domyślne uprawnienia
typu konta) celowo zostały w aplikacji (GPL-3.0) — nie dodawaj ich tutaj.

## Testy

```bash
swift test
xcodebuild -scheme AudiobookshelfKit -destination 'generic/platform=iOS' build
```
