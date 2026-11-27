# Licencja

Licencje aplikacji i dołączonych komponentów oraz obowiązki przy rozprowadzaniu binarek.

## Licencja

Rapsod jest wolnym oprogramowaniem na licencji **GPL-3.0-or-later** (plik `LICENSE`). To nie jest porada prawna, tylko przyjęte rozwiązanie: aplikacja jest rozprowadzana w jednej paczce z serwerem audiobookshelf (GPL-3.0), a jej skrypt `parent-watch.js` działa w procesie serwera.

Wydana paczka zawiera niezmienione komponenty innych autorów (Node.js i FFmpeg zbudowane z niezmienionych źródeł z mniejszym zestawem składników): audiobookshelf (GPL-3.0) z pakietami npm, Node.js (MIT i licencje dołączonych bibliotek), FFmpeg (LGPL-2.1+), libwebp (BSD-3-Clause), nunicode-sqlite (MIT). Lista jest w `Rapsod/Rapsod/Resources/THIRD-PARTY-NOTICES.txt` i w oknie „O programie”; pełne teksty licencji, adresy źródeł, sumy kontrolne i opcje budowania Node i ffmpeg trafiają do `Contents/Resources/Licenses` w paczce.

Rozprowadzanie binarek na GPL/LGPL wymaga udostępnienia odpowiadającego im kodu źródłowego. Dlatego **przed publikacją wydania** to repozytorium (z przypiętym submodule i skryptami budowania) musi być publicznie dostępne, a jego adres wpisany w klucz `ABSSourceURL` w `Rapsod/Info.plist` — pokazuje go „O programie”, a `scripts/release.sh` ostrzega, gdy jest pusty.

Lista zgodności na [ffmpeg.org/legal.html](https://ffmpeg.org/legal.html) zaleca ponadto, by źródła FFmpeg leżały na tym samym serwerze co binarka. Obok pliku DMG warto więc opublikować archiwa `ffmpeg-9.0.2.tar.xz` i `libwebp-1.6.0.tar.gz` (adresy i sumy są w `scripts/build-ffmpeg.sh`), a nie tylko wskazać ffmpeg.org.
