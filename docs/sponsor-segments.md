# Segmenty sponsorowane w podcastach

Oznaczanie i pomijanie reklam i autopromocji w podcastach: znaczniki bez modelu (13a) oraz transkrypcja i zdalny klasyfikator na Macu (13b), z pomiarami.

## Segmenty sponsorowane w podcastach (etap 13a)

Oznaczanie i pomijanie reklam, „partnerów odcinka” i autopromocji przy odtwarzaniu, na Macu i iOS — bez transkrypcji i bez modelu (to 13b). Pliku audio nie wycinamy.

- **Plik `<odcinek>.skip.json`** obok pliku audio w folderze podcastu (`Odcinek 12.mp3` → `Odcinek 12.skip.json`). Skaner serwera dopisuje go do plików pozycji jako plik metadanych (czyta tylko `metadata.json`), odcinki się nie zmieniają; każde konto z dostępem pobiera go przez `GET /api/items/:id/file/:ino` (bez uprawnienia do pobierania) — sprawdzone na testowym serwerze. Serwer podaje plik po ścieżce, więc nadpisanie w miejscu działa od razu; aplikacja i tak skanuje pozycję po zapisie (nowy plik, rozmiar). Zawartość (`SkipMap` w pakiecie): `format: "rapsod-skip"` (pliki ze starą nazwą formatu `abswift-skip`, sprzed zmiany nazwy aplikacji, czytają się tak samo i przy zapisie dostają nową), `version: 1`, `episode` (pozycja, odcinek, guid, adres), `audio` — odcisk pliku (nazwa, rozmiar, długość, SHA-256 pierwszych i ostatnich 64 KiB), `segments` — `{id, start, end, kind, source, confidence, label, autoSkip}`, `insertedAds` — reklamy wstawiane dynamicznie (źródło, sekundy, liczba slotów, `located`), `notices` — wzmianki bez czasu albo bez końca, `corrections` — poprawki użytkownika (`added`: segmenty ręczne, `removed`: odrzucone zakresy czasu), `runs` — które wykrywania się odbyły i w jakiej wersji reguł. `kind` (`sponsor`, `selfpromo`) i `source` (`description`, `chapters`, `megaphone`, `duration`, `user`, zarezerwowane `model`) to tekst — nieznane wartości z nowszej wersji czytają się bez błędu, uszkodzony segment wypada sam. Ponowne wykrywanie zastępuje segmenty tylko tych źródeł, które liczyły; poprawki zostają (odrzucenie działa na każdy wykryty segment, który w ≥ 50% leży w odrzuconym zakresie, więc przeżywa też inne granice z nowego wykrywania).
- **Źródła bez modelu.**
  - *Opis odcinka:* czasy (`m:ss`, `h:mm:ss`, zakres „1:45–3:45”) przy nagłówkach wstawek po polsku i angielsku: „[autopromocja]”, „Sponsor odcinka”, „[partner odcinka]”, „Partner odcinka – X”, „Partnerem X jest…”, „[współpraca reklamowa]”, „Segment partnera”, „Sponsor: X”, „Brought to you by”, „Support for this show comes from”, samo „Reklama”/„Ads”. Koniec = jawny koniec zakresu albo następny czas w opisie; bez następnego czasu — tylko wzmianka (bez zgadywania końca). Wzmianki bez czasu („Partnerem odcinka jest Komputronik”) pokazuje edytor. Reguły są celowo wąskie: przegląd ok. 9 tys. opisów z 10 kanałów pokazał, że samo „reklama”/„partner” w temacie rozmowy („Jak ustawić reklamę Google Ads”, „Wybór partnera logistycznego”) daje dziesiątki fałszywych trafień w podcastach biznesowych. Zakres dłuższy niż 3 min (opis podaje następny czas dopiero kilka minut po wstawce) jest tylko znacznikiem.
  - *Rozdziały:* z pliku (serwer czyta ID3 CHAP) albo z kanału (`psc:chapters`, plik JSON `podcast:chapters`) — tytuł jak wyżej, granice z rozdziału; wygrywają z tym samym wpisem w opisie.
  - *Reklamy wstawiane dynamicznie:* `itunes:duration` z kanału kontra długość pliku (nadwyżka > 20 s i > 2%) — „reklamy są, położenie nieznane”, a czasy z opisu stają się wtedy tylko znacznikami (mogą być przesunięte). Megaphone: nagłówek `x-megaphone-payload-2` z zapytania o jeden bajt (tylko adresy z `megaphone.fm/`, także za przedrostkami Podtrac); format odczytany z obserwacji (parser własny, `MegaphonePayload`): sloty `id reklamy#ostatni bajt#pre|mid|post#nr#pierwszy bajt#…`, na końcu `@id#bitrate#początek audio`; pusty slot ma puste id i ostatni bajt o jeden mniejszy od pierwszego. Czas z bajtu przy stałym bitrate. Położenie używane tylko, gdy odpowiedź opisuje ten sam plik: tyle samo bajtów audio (bez nagłówka ID3 — serwer przepisuje znaczniki przy pobieraniu, różnica ok. 1 KB; tolerancja pół sekundy nagrania) i zgodna długość. Czasy z opisu przelicza się wtedy na oś pliku (dodając wstawione przed nimi reklamy). Gdy odpowiedź jest z innym zestawem reklam — „reklamy są, położenie nieznane”.
- **Kiedy liczy (Mac, `Listening/Skip/SkipController.swift`).** Po pobraniu odcinka na serwer (zdarzenie serwera przy otwartym oknie, a przy zamkniętym — przegląd najnowszych odcinków przy starcie i co 30 min: odcinki pobrane w ostatnich 3 dniach bez pliku znaczników), przyciskiem „Wykryj w pobranych odcinkach” (popover „Segmenty sponsorowane” na stronie podcastu) i z menu odcinka. Jedno zadanie naraz z niskim priorytetem: odcinek to dwa fragmenty po 64 KiB, kanał RSS raz na podcast na 30 min i — dla Megaphone — jedno zapytanie o bajt. Starsze odcinki tylko przyciskiem (nagłówek Megaphone opisuje bieżący zestaw reklam, a ten po kilku dniach zwykle nie pasuje do pliku na dysku).
- **Pomijanie (pakiet, `AudiobookshelfPlayback`).** `SkipPlan` (czysta funkcja, z testami) i `AudiobookPlayer`: pominięcie, gdy odtwarzanie dociera do początku segmentu (zegar co 0,5 s i obserwator granic AVPlayer — bez pół sekundy reklamy także przy 3×; start odtwarzania na początku segmentu, np. pre-roll, też). Przewinięcie w środek segmentu to wybór słuchacza: bez automatu, komunikat „Reklama do 12:30 · Pomiń”. „Cofnij” wraca na początek i gra fragment do końca (segment wraca do pomijania, gdy pozycja z niego wyjdzie); sąsiednie segmenty pomija jeden skok; segment do końca pliku kończy odcinek; wyłącznik „do końca rozdziału” zatrzymuje na końcu rozdziału; bez pomijania w pauzie. Zegar nie czyta pozycji, póki trwa przewinięcie (wcześniej stara pozycja psuła „Cofnij”). Postęp: pominięcie to zwykłe przewinięcie (pozycja idzie na serwer), czas słuchania liczony zegarem, więc bez zawyżania. Znaczniki tylko dla odcinka, którego odcisk pasuje (rozmiar albo skróty, długość ±1 s) — przy niezgodności nie ma ani pomijania, ani znaczników, a edytor mówi dlaczego.
- **Ustawienie per podcast** (na tym urządzeniu, `UserDefaults` `skipSettings.<id podcastu>`): „Oznaczaj i pomijaj w tym podcaście” oraz osobno „Reklamy i sponsorzy” i „Autopromocja”: Pomijaj / Tylko pokazuj / Ignoruj. Domyślnie obie kategorie pomijane (ustalenie użytkownika). Mac: popover na stronie podcastu; iOS: przycisk w pasku strony podcastu.
- **Interfejs.** Znaczniki pod suwakiem (pomarańczowe — reklamy, fioletowe — autopromocja, przygaszone — tylko pokazywane), komunikat „Pominięto reklamę (0:58) · Cofnij” (10 s, przy VoiceOver 30 s; ogłoszenie VoiceOver ze słownym czasem; przy „Ogranicz ruch” samo przenikanie); na Macu też w dolnym pasku, na iOS „Cofnij” w mini-odtwarzaczu. Edytor („Więcej” → „Segmenty sponsorowane…”): rodzaj, początek i koniec (Mac: pole czasu i „bieżące miejsce”; iOS: krok ±1 s i „bieżące miejsce”), odsłuch od początku, usuwanie, „Dodaj w bieżącym miejscu”, „Przywróć wykryte”, a także informacje o reklamach o nieznanym położeniu, wzmiankach z opisu i niezgodnym pliku. Na Macu w wierszu odcinka podsumowanie („1 segment”, „reklamy wstawione, położenie nieznane”). Ten sam edytor otwiera się bez odtwarzania z menu odcinka („Fragmenty sponsorowane…”; Mac: menu kontekstowe wiersza, iOS: przytrzymanie wiersza odcinka na serwerze): Mac czyta plik obok odcinka (z „Wykryj teraz”/„Wykryj ponownie”) i zapisuje do niego, iOS wczytuje plik z serwera albo kopię pobraną z odcinkiem, a poprawki zapisuje na telefonie — odtwarzacz nałoży je przy starcie odcinka. Gdy odcinek nie gra, nie ma „bieżącego miejsca”, „Dodaj segment” zaczyna od 0:00, a odsłuch segmentu uruchamia odcinek od tego miejsca; gdy właśnie gra, menu otwiera edytor odtwarzacza. (Tylko skompilowane, nie klikane w aplikacji.)
- **iOS — trzy przypadki.** *Odcinek z serwera (strumień):* plik `.skip.json` z serwera, odcisk z rozmiaru i długości pliku na serwerze. *Pobrany na telefon:* plik znaczników pobiera się razem z odcinkiem (`skip.json` w folderze pobranego odcinka) i odświeża przy odtwarzaniu z siecią; bez sieci działa kopia; odcisk liczony z pliku na telefonie (te same skróty co na Macu). *Prosto z kanału (odcinek, którego nie ma na serwerze):* telefon liczy sam z opisu w kanale i nagłówka Megaphone (położenie slotów tylko przy długości zgodnej ±1 s z odtwarzanym strumieniem); różnicy długości z kanałem nie da się tu użyć do lokalizacji — tylko jako informacja. Poprawki z telefonu zapisują się na telefonie (`Application Support/SkipCorrections`) i nakładają na znaczniki z serwera; poprawki z Maca trafiają do pliku na serwerze i widzą je wszystkie urządzenia.
- **Wyniki na zestawie testowym** (7 publicznych odcinków pobranych z kanałów 2026-11-23: Kryminatorium 453, Imponderabilia — Kuba Rafalski, Mała Wielka Firma 555, Przygody Przedsiębiorców — Filip Duszczak, Syntax 1055, Darknet Diaries 182, Today, Explained „The rise of kidults”; prawda z rozpoznania: 10 segmentów, 517 s): z opisów 2/10 trafione (Kryminatorium autopromocja: granice +0,1 / +5,6 s; Syntax sponsor: −1,0 / +1,1 s), 0 fałszywych obszarów, 8 s treści pominiętej błędnie; Darknet Diaries — „reklamy wstawione (+194 s), położenie nieznane”, bez pomijania; Imponderabilia, MWF, Przygody — tylko wzmianki w opisie (bez czasów). Today, Explained (Megaphone, 7 wypełnionych slotów → 4 bloki, 385 s): wszystkie 6 granic wewnętrznych leży w ciszy nagrania (`silencedetect`); na pliku pobranym przez testowy serwer (inny zestaw reklam, 3 bloki, 330 s) — wszystkie 5 granic też w ciszy. Przegląd opisów ok. 9 tys. odcinków z 10 kanałów: 683 zakresy, wszystkie przy nagłówkach wstawek (przed zawężeniem reguł — ok. 76 fałszywych, głównie w podcastach biznesowych). Ocena jest testem w pakiecie (`SkipEvaluation`, włączany zmiennymi `SKIP_EVAL_MANIFEST`/`SKIP_EVAL_FEEDS`), zestaw i manifest — w notatkach sesji.
- **Sprawdzone uruchomieniem.** Testowa kopia Maca (port 13497, osobny folder danych): po pobraniu odcinka przez serwer plik znaczników powstał sam (Syntax: sponsor 216–240 s; Today, Explained: 3 bloki z Megaphone); automatyczne pominięcie (214 → 240 s, komunikat), „Cofnij” (gra reklamę do końca, bez ponownego pominięcia), przewinięcie w środek → „Pomiń”, korekta granic w edytorze (zapis do pliku, odtwarzacz używa nowych granic), wyłączenie dla podcastu (reklama gra, bez komunikatu) i powrót, niezgodny plik (bez pomijania, komunikat w edytorze), ponowne wykrywanie z zachowaniem poprawki, wznowienie po pominięciach od właściwego miejsca. Symulator iOS (iPhone 17, sparowany z testową kopią przez `rapsod://pair` z adresem 127.0.0.1): znaczniki z serwera z poprawką z Maca, automatyczne pominięcie, „Cofnij”, „Pomiń” po przewinięciu w środek, arkusz ustawienia per podcast, pobranie odcinka z plikiem znaczników i pomijanie bez serwera (źródło „kopia na telefonie”), odcinek prosto z kanału ze znacznikiem z opisu, poprawka na telefonie; bez serwera: wyłączenie dla podcastu (ustawienie zapisane bezpośrednio w ustawieniach aplikacji w symulatorze, bo strona podcastu bez serwera się nie otwiera — znacznik i komunikat znikają) i niezgodny plik (zepsuty rozmiar w kopii znaczników: bez pomijania, komunikat w liście segmentów). Przy tym wyszedł błąd: porządkowanie folderu pobranych kasowało `skip.json` przy każdym starcie aplikacji (poprawione, test). Testowy serwer zamknięty, symulator wyłączony, bez osieroconych procesów. **Nie uruchamiane / tylko skompilowane:** VoiceOver w użyciu, „Ogranicz ruch”, Dynamic Type przy największych rozmiarach, zmiana prędkości i wyłącznik czasowy w aplikacji (oba tylko testem pakietu na prawdziwym odtwarzaczu), odtwarzanie Today, Explained (pre-roll od 0 i łańcuch sąsiednich bloków — tylko testy na WAV), Megaphone na telefonie dla odcinka z kanału, prawdziwe urządzenie.
- **Zmiana we wspólnym odtwarzaczu (dotyczy też książek):** zegar nie czyta pozycji, póki trwa ostatnie przewinięcie (znacznik zerowany przy ładowaniu pliku i zamknięciu) — wcześniej zegar potrafił na chwilę podać pozycję sprzed przewinięcia.
- **Długość zakresów z opisu** (683 z przeglądu kanałów): ≤ 30 s — 127, 31–60 s — 209, 61–120 s — 286, 121–180 s — 43, 181–300 s — 12 (tylko znaczniki), > 300 s — 6 (tylko znaczniki). Reklamy czytane w Syntax trwają zwykle 20–60 s, więc część dłuższych zakresów obejmuje też początek treści po reklamie (bez odsłuchu niesprawdzone); w polskich podcastach wstawki mają 1,5–3 min.
- **Znane braki:** rozdziały z kanału (oś wydawcy) nie są przesuwane o reklamy z Megaphone (rozdziały z pliku są na osi pliku); poprawki z telefonu nie wracają na serwer (iOS nie zapisuje w folderze podcastu); ustawienie per podcast jest osobne na każdym urządzeniu; plik znaczników zostaje po usunięciu odcinka z serwera (osierocony plik w plikach pozycji); polskie podcasty rzadko podają czasy wstawek — na nich 13a daje głównie wzmianki, właściwe wykrywanie to 13b; Megaphone lokalizuje reklamy tylko przy świeżym pobraniu (ten sam zestaw reklam), DAI innych dostawców (Podtrac/Dovetail, Spreaker) — tylko „są, położenie nieznane”.

## Segmenty sponsorowane z transkrypcji i modelu (etap 13b)

Mac transkrybuje pobrane odcinki podcastów i wysyła tekst do zdalnego modelu zgodnego z API OpenAI, na kluczu użytkownika. Wynik to segmenty `model` w tym samym pliku `.skip.json`. iOS i odtwarzacz niczego nowego nie potrzebują: pomijają je jak inne segmenty. Bez konfiguracji aplikacja działa dokładnie jak po 13a i nic nie wysyła.

### Jak włączyć (Mac)

1. **Ustawienia → Ogólne → Fragmenty sponsorowane w podcastach → „Usługa modelu językowego”.**
   - Adres API, np. `https://api.mistral.ai/v1`, `https://generativelanguage.googleapis.com/v1beta/openai` albo `https://api.openai.com/v1`.
   - Model, np. `mistral-small-latest`; podpowiedź w polu: „mały model, np. Mistral Small albo Gemini Flash”.
   - Klucz API, który trafia do pęku kluczy.
2. **„Sprawdź połączenie”.** Wysyła jedno krótkie zapytanie, bez danych odcinków.
3. **Zgoda „Zgadzam się na wysyłanie transkrypcji odcinków do <host>”.** Pod polem jest opis, co dokładnie jest wysyłane.
4. **„Wykrywaj fragmenty sponsorowane”.** Przełącznik jest nieaktywny, dopóki nie ma adresu, modelu i zgody.
5. **Wybór działania dla kategorii.** „Reklamy i sponsorzy” oraz „Autopromocja”: Pomijaj / Tylko pokazuj / Ignoruj (domyślnie obie: Pomijaj).

Od tej chwili analizowany jest każdy odcinek pobrany na serwer. Starsze odcinki analizuje przycisk „Wykryj segmenty sponsorowane” w menu odcinka.

### Przepływ

1. **Wykrywanie z 13a** (opis, rozdziały, Megaphone, różnica długości) — bez zmian. Po nim odcinek trafia do drugiej kolejki w `SkipController` (`SkipController+Model.swift`).
   - Kolejka obejmuje odcinki pobrane w ostatnich 3 dniach, które model jeszcze nie oceniał. Włączenie wykrywania nie przelicza całej biblioteki.
   - Odcinek wskazany przyciskiem jest zawsze liczony od nowa.
2. **Transkrypcja na tym Macu** (`DictationTranscriber`, kod z 11a).
   - Pamięć podręczna `TranscriptCache` (klucz: język, `ino`, rozmiar): ponowna analiza nie słucha nagrania drugi raz.
   - Język pochodzi z metadanych podcastu, potem z kanału. Wariant regionalny: rodzimy, potem region tego Maca, potem najczęstszy (`en-US`, poprawione w 13b).
   - Przy języku bez obsługi pojawia się czytelny błąd.
3. **Wiersze i okna** (`SponsorClassification` w pakiecie).
   - Wiersz kończy się przy przerwie ≥ 0,7 s, przy kropce po ≥ 4 s albo po 12 s.
   - Okna mają 10 min i zachodzą na siebie o 2 min. Bardzo długi odcinek daje po prostu więcej okien.
4. **Zapytanie `POST <adres>/chat/completions`** (`SponsorAPIClient`).
   - Parametry: `temperature: 0`, `response_format: json_object`.
   - **Wykrywanie:** instrukcja z rozpoznania bez zmian, po angielsku z przykładami zwrotów PL i EN; ten sam prompt działa dla obu języków. Model odpowiada numerami wierszy, nie czasami: `{"ad_line_ids":[…]}`. Kolejne numery to jeden blok.
   - **Kategoria:** dla każdego znalezionego bloku osobne krótkie pytanie z tekstem bloku: `{"category":"sponsor"|"selfpromo"}`. Gdy pytanie się nie uda, blok zostaje jako „sponsor”, a wykrycie się nie traci.
   - Dlaczego tak: inne prompty wypadły gorzej w ocenie z kluczem (tabela w „Pomiarach”).
5. **Walidacja odpowiedzi.**
   - Tekst wokół JSON-a (np. blok kodu) jest tolerowany.
   - Numery spoza okna i powtórzenia wypadają.
   - Brak listy albo odpowiedź, która nie jest JSON-em, daje jedną ponowną próbę z przypomnieniem formatu. Gdy i ona zawiedzie, odcinek kończy się błędem i nic nie jest zapisywane. Częściowy wynik pominąłby reklamy tylko w części odcinka.
   - Pusty wynik `{"ad_line_ids":[]}` jest prawidłowy. Zapisuje przebieg bez segmentów.
6. **Odporność.**
   - 429, 5xx, zerwane połączenie i przekroczony czas: do 4 prób z odstępem 2, 4, 8 s albo według `Retry-After`.
   - 400 daje jedną próbę z minimalnym zapytaniem, bez `response_format`, `temperature` i `max_tokens`, bo nie każda usługa je zna.
   - 401, 403, 404 i drugi 400 wstrzymują kolejkę z komunikatem w Ustawieniach i przyciskiem „Wznów”. Kolejka rusza też sama po zmianie ustawień albo klucza.
   - Inne błędy oznaczają odcinek; przegląd nie ponawia go przez 12 h.
7. **Scalanie i granice.**
   - Zgłoszenia tej samej kategorii nachodzące na siebie albo oddalone o mniej niż 4 s łączą się. Model nie podaje pewności, więc segment z listy ma stałą pewność 0,7.
   - Granice wierszy są granicami słów. Docięcie cofa początek w ciszę tuż przed pierwszym słowem i wydłuża koniec w ciszę tuż po ostatnim, najwyżej o 0,5 s.
   - Ciszę wyznaczają poziomy głośności czytane tylko wokół granic (`AudioLevels` w `AudiobookshelfPlayback`); gdy jej nie ma, liczą się odstępy między słowami.
8. **Zapis.**
   - Plik jest czytany od nowa tuż przed zapisem, bez `await` pomiędzy, więc poprawki zrobione w czasie analizy zostają.
   - Przed zapisem sprawdzany jest odcisk pliku audio.
   - `SkipMap.replacingSegments(from: .model, …)` i `SkipRun(source: .model, detail: "13b.3 · <model> · N zapyt. · T tokenów")`.
   - Format pliku bez zmian. Ponowne wykrywanie z 13a zachowuje segmenty modelu tylko dla tego samego pliku: po ponownym pobraniu odcinka model liczy od nowa.

**Kolejka.**
- Jedno zadanie naraz, w tle.
- Zadania czekają w `sponsor-queue.json` w folderze danych serwera.
- Wyniki okien trafiają do punktu kontrolnego w `Caches/…/Sponsor/`. Przerwane zadanie (zamknięcie aplikacji, zatrzymanie serwera) kończy się po ponownym uruchomieniu i nie wysyła drugi raz okien już policzonych. Wysłane jeszcze raz może zostać tylko okno, które było w drodze.
- Stan w wierszu odcinka: „w kolejce do analizy” / „Transkrypcja 37 %” / „Klasyfikacja 2/4” / „model: 2 segmenty (1 tylko znacznik)” / błąd z przyczyną.
- W menu odcinka „Przerwij analizę modelem” usuwa zadanie z kolejki.
- W Ustawieniach widać liczbę odcinków w kolejce i bieżący krok.

**Segmenty modelu a zakresy z opisu (13a).** Ten sam fragment nie jest ani pokazywany, ani pomijany dwa razy. Liczy się przy odczycie (`SkipMap.effectiveSegments`), więc tak samo na Macu i iOS. Za „ten sam fragment” uznaję co najmniej 5 s wspólnego czasu albo połowę krótszego z segmentów.
- **Pewny zakres z opisu albo rozdziałów** (pomija się sam: do 3 min, bez reklam w nieznanych miejscach) wygrywa z nachodzącym segmentem modelu, który znika.
- **Niepewny zakres** (tylko znacznik: dłuższy niż 3 min albo z czasami przesuniętymi przez wstawione reklamy) zastępuje pewny segment modelu: model wyznacza w nim prawdziwe granice. Niepewny segment modelu go nie zastępuje, więc zostają oba znaczniki.
- **Gdzie model nic nie znalazł**, zakres z opisu zostaje jak w 13a.
- **Sloty Megaphone** zostają zawsze. Gdy nachodzą na segment modelu, odtwarzacz pomija je jednym skokiem.
- **Odrzucenie segmentu modelu** przez użytkownika nie przywraca zastąpionego niepewnego zakresu.
- **Pomiar** (`combinedWithDescriptionRanges`: 13a i zapisane odpowiedzi modelu razem, przez plan odtwarzacza):

  | | Trafione | Fałszywe obszary | Pominięte błędnie | Pokrycie reklam |
  |---|---|---|---|---|
  | samo 13a | 2/10 | 0 | 8 s | 136/517 s |
  | sam model | 7/10 | 0 | 27 s | 442/517 s |
  | razem | **8/10** | 0 | 30 s | 483/517 s |

  Reguła „model zawsze zastępuje opis” dawała tyle co sam model. W Kryminatorium opis 105–225 s (prawda 104,9–219,4 s) był lepszy niż model, który zgubił środek bloku (105–125 i 164–218 s).

**Automatyczne pomijanie segmentów modelu.**
- Zgodnie z ustaleniem pomijają się automatycznie, z „Cofnij”, gdy trwają ≥ 15 s. Krótsze są znacznikiem z „Pomiń”.
- Próg długości jest zmierzony na zapisanych odpowiedziach modelu z rozpoznania. Bez progu 3 fałszywe obszary (5, 8 i 13 s) pomijałyby się same; z progiem 15 s — 0, przy tych samych 7/10 trafieniach. Próg 20 s gubi krótką autopromocję (18 s).
- Próg potwierdziła ocena z kluczem: wszystkie krótkie fałszywe alarmy (11–12 s) zostały znacznikami. Progu pewności w praktyce nie ma: model jej nie podaje (`AutoSkipPolicy` ma 0,6 przy stałej 0,7 dla list).

**Ustawienia a ustawienie per podcast (13a).**
- Kategorie w Ustawieniach to domyślne działanie dla wszystkich znaczników (z opisu, rozdziałów, Megaphone i modelu).
- Podcast ma wyjątki: w popoverze ⏭ każda kategoria ma „Jak w ustawieniach (…)” albo jawny wybór (`SkipPreference` w pakiecie). Zapisy z 13a czytają się jako jawny wybór.
- iOS bez zmian: domyślne „pomijaj” i własne wyjątki per podcast.

**Prywatność.**
- Klucz jest w pęku kluczy (`net.smigi.rapsod.sponsor-api`, konto = folder danych), nigdy w `UserDefaults`, plikach ani logu. Komunikaty błędów usługi są obcinane i maskują klucz.
- Ustawienia (adres, model, zgoda z hostem i datą) są w `sponsor-detection.json` w folderze danych, więc testowa kopia z `-ABSDataRoot` ma własne.
- Zgoda jest przypięta do hosta: zmiana adresu na inną usługę wyłącza wykrywanie, dopóki zgoda nie zostanie udzielona od nowa.
- Wysyłane są: tekst rozpoznany z nagrania (okna po ok. 10 min, z numerem i czasem każdego wiersza) i długość odcinka. Nie są wysyłane: plik audio, tytuły, opis, nazwa i adres podcastu ani dane kont.
- Konfiguracja zapytań powstaje wyłącznie z `SponsorDetectionSettings.requestConfiguration`, która zwraca `nil` bez włączenia, zgody dla tego hosta, adresu i modelu (test w pakiecie).

### Pomiary

**Transkrypcja** (M4, 16 GB, `DictationTranscriber`, osobny program z tym samym ustawieniem co aplikacja):

| Odcinek | Czas nagrania | Czas transkrypcji | Na godzinę nagrania | Usługa mowy `localspeechrecognition` |
|---|---|---|---|---|
| Kryminatorium 453 (PL) | 1:58 h | 84 s | 43 s | śr. ok. 94% CPU (ok. 1 rdzeń), do 317 MB |
| Darknet Diaries 182 (EN) | 42 min | 64 s | 90 s | śr. ok. 124% CPU, do 389 MB |
| Syntax 1055 (EN) | 31 min | 83 s | 159 s | śr. ok. 122% CPU, do 430 MB |

- Sam proces programu zużywał 11–32% CPU i ok. 25–30 MB.
- W aplikacji (testowa kopia): MWF 555 (PL, 28 min) — 13a, transkrypcja i 4 okna w ok. 29 s. Syntax (EN, `en-US`, 31 min) — ok. 85 s.
- Próbki CPU co 5 s z `ps`, tylko gdy proces był w pierwszej piątce, więc to orientacyjne wartości.

**Klasyfikacja i scalanie na zapisanych odpowiedziach modelu** (Mistral Small z rozpoznania; cała transkrypcja w jednym zapytaniu, 6 odcinków, 10 segmentów, test `SponsorRegressionTests` bez sieci):

| Reguła | Trafione | Fałszywe obszary pomijane | Treść pominięta błędnie | Pokrycie reklam |
|---|---|---|---|---|
| bez progu długości | 7/10 | 3 | 53 s | 442/517 s |
| **≥ 15 s (przyjęte)** | **7/10** | **0** | **27 s** | **442/517 s** |
| ≥ 20 s | 6/10 | 0 | 27 s | 404/517 s |

- Docinanie granic na tych samych odpowiedziach z prawdziwymi nagraniami (`SponsorBoundaryEvaluation`): mediana błędu granicy 1,46 s dla samych wierszy i 1,47 s po docięciu.
  - **Na tym zestawie docinanie do ciszy praktycznie nic nie zmienia:** przesuwa granice o najwyżej 0,5 s w ciszę.
  - Prawdę w rozpoznaniu wyznaczono z czasów słów, więc zestaw i tak nie pokaże zysku poniżej sekundy.
  - Zostawiłem je jako zabezpieczenie przed ucięciem słowa przy przesuniętych czasach rozpoznawania mowy.
  - Wcześniejszy wariant, przyciągający do najbliższej przerwy w promieniu 2,5 s, pogarszał wynik do 2,39 s i został odrzucony.
  - Granice realnie poprawiają krótsze wiersze (12 zamiast 20 s), ale tego nie da się zmierzyć na zapisanych odpowiedziach — dotyczą wierszy 20 s.
  - Największe błędy (do 57 s) to części bloku reklam, które model pominął, a nie granice.
**Ocena z prawdziwym modelem** (Twój klucz, `mistral-small-latest`, 2026-11-23; 6 odcinków, 6,4 h, 10 segmentów; wiersze do 12 s; liczy się to, co pomija się samo):

| Wariant | Trafione | Fałszywe obszary pomijane | Pominięte błędnie | Pokrycie reklam |
|---|---|---|---|---|
| 13b.1: segmenty z kategorią i pewnością, okna | 0/10 | 0 | 0 s | 0/517 s |
| 13b.1, cała transkrypcja naraz | 0/10 | 0 | 0 s | 0/517 s |
| instrukcja z rozpoznania, okna | 7/10 | 0 | 45 s | 447/517 s |
| instrukcja z rozpoznania, cała transkrypcja | 7/10 | 0 | 29 s | 447/517 s |
| 13b.2: dwie listy (sponsor, autopromocja), okna | 7/10 | 2 | 185 s | 400/517 s |
| 13b.2, cała transkrypcja | 7/10 | 1 | 129 s | 407/517 s |
| **13b.3 (w aplikacji): instrukcja z rozpoznania + pytanie o kategorię, okna** | **8/10** | **0** | **53 s** | **450/517 s** |

- **13b.1:** model w każdym oknie odpowiadał pustą listą.
- **13b.2:** model brał prezentację firmy gościa (koniec Przygód) za autopromocję i rozbijał blok gry prowadzącego (Kryminatorium).
- **13b.3:** kategoria zgodna z prawdą we wszystkich 8 trafieniach (4× autopromocja, 4× sponsor).
- **Nietrafione** (oba w Przygodach): wspólny blok sponsora i autopromocji 27,9–74,2 s oraz 7-sekundowa autopromocja. Model zaznaczył z nich tylko krótki znacznik 24–35 s.
- **Okna zamiast całej transkrypcji:** okna znalazły autopromocję na końcu Darknet Diaries, a cała transkrypcja pominęła ją raz. Okna obsługują też bardzo długie odcinki.
- **Granice** trafień: mediana ok. 1 s, największe odchyłki (10–17 s) to początki bloków, w których model zaznaczył o jeden–dwa wiersze za dużo.

**Koszt** (z ocen z kluczem; liczniki tokenów podane przez Mistral).
- Cały zestaw (6,4 h) to 61 zapytań, 155,6 tys. tokenów wejścia i 0,7 tys. wyjścia. Godzina odcinka to więc ok. 10 zapytań i **ok. 24 tys. tokenów wejścia** (tekst, zakładka okien, prompt, numery wierszy, pytania o kategorię).
- To ok. 1,6 razy więcej niż cała transkrypcja w jednym zapytaniu, którą wycenia rozpoznanie (0,001–0,007 USD/h według cenników z 2026-11). Daje to **ok. 0,002–0,011 USD za godzinę odcinka**: gpt-5-nano ok. 0,002, Haiku 5.5 ok. 0,005, Gemini Flash-Lite ok. 0,008.
- Mistral Small na darmowym progu kosztuje 0 USD, ale darmowe progi części dostawców używają danych do trenowania. Ceny się zmieniają — sprawdź cennik dostawcy.

### Sprawdzone uruchomieniem

**Testowa kopia Maca** (port 13581, osobny folder danych). Atrapa usługi i kanału RSS była na 127.0.0.1. Dwa punkty testowe działają tylko w buildzie Debug: serwer dostaje `SSRF_REQUEST_FILTER_WHITELIST` ze środowiska, a `-ABSTestLibraryFolder <ścieżka>` podaje folder biblioteki bez systemowego panelu, którego automatyzacja po PID nie obsłuży.

- **Bez konfiguracji** pobranie odcinka i ponowne wykrywanie dały plik 13a i **0 zapytań do API** (log atrapy).
- **Z adresem i modelem, bez zgody:** przełącznik jest nieaktywny, ponowne wykrywanie — 0 zapytań.
- **„Sprawdź połączenie”:** 1 zapytanie, 224 B, bez danych odcinka.
- **Po zgodzie** pobranie odcinka EN samo uruchomiło kolejkę: transkrypcja, 4 okna z kluczem w nagłówku i zapis.
- **Zamknięcie aplikacji po 1. oknie:** po ponownym uruchomieniu poszły tylko okna 2–4, kolejka się opróżniła.
- **Poprawki przetrwały ponowną analizę:**
  - zapisane do pliku przy zamkniętej aplikacji (odrzucony fałszywy alarm, dodany segment);
  - dopisane do pliku w trakcie klasyfikacji (atrapa odpowiadała wolno) — tak, jak zapisuje edytor; sam edytor w tym przebiegu nie był klikany.
- **Błędy usługi:**
  - 429 ×2 ponowione z `Retry-After`;
  - zerwane połączenie ×2 ponowione;
  - 401 wstrzymało kolejkę z komunikatem i „Wznów”;
  - zły format ×2 dał błąd z przyczyną bez zapisu.
- **„Przerwij analizę modelem”** w czasie klasyfikacji: stan „Przerwano.”, pusta kolejka, plik bez segmentów z przerwanego przebiegu.
- **Pomijanie w odtwarzaczu Maca:** 1659 → 1684 s, „Pominięto autopromocję (0:22)”.
- **Bez dublowania:** w Syntax pewny zakres z opisu 216–240 s ukrywa nachodzący segment modelu. W wierszu odcinka są segmenty z opisu, krótki znacznik modelu i segment użytkownika, bez podwójnych.
- Czasy segmentów z przebiegów sprzed ostatniej zmiany docinania (MWF 1660,8–1683,3 s) pochodzą ze starszej reguły. Ostatni przebieg Syntax był już na końcowym kodzie.
- **Klucz** zapisany i usunięty przyciskiem w aplikacji; nie pojawił się w plikach ani w `UserDefaults`.

**Symulator iOS** (iPhone 17, sparowany z testową kopią; przebieg na wcześniejszej regule, gdy segment modelu zastępował każdy zakres z opisu):
- znaczniki segmentów modelu na pasku: pomijany i „tylko znacznik”, bez zakresu z opisu;
- automatyczne pominięcie „Pominięto reklamę (0:23) · Cofnij”;
- edytor z „źródło: model językowy” i „tylko znacznik”.

Po testach testowy serwer i atrapa zostały zamknięte, bez osieroconych procesów; `UserDefaults` przywrócone.

**Testy i buildy.**
- `swift test` w pakiecie: 250 testów.
- Buildy: Mac Debug i Release, iOS na symulator.

**Ocena z prawdziwym modelem (wymaga klucza użytkownika).** Zestaw z rozpoznania jest w notatkach sesji (`etap13b-zestaw/`: transkrypcje i manifest). W `Packages/AudiobookshelfKit`:

```bash
read -s "SPONSOR_API_KEY?Klucz API: " && export SPONSOR_API_KEY && SPONSOR_API_BASE=https://api.mistral.ai/v1 SPONSOR_API_MODEL=mistral-small-latest SKIP_EVAL_MODEL_MANIFEST="$HOME/Library/Application Support/Claude/side-session-notes/local_263f2d4b-e6bd-4026-980a-5c1d74778a55/etap13b-zestaw/manifest.json" swift test --filter SkipEvaluation/modelEvaluation
```

- Wysyła transkrypcje 6 odcinków, razem 6,4 h: ok. 60 zapytań i 156 tys. tokenów, ok. 0,02 USD przy małym modelu.
- Drukuje wynik każdego odcinka i zgodność kategorii z prawdą.
- `SKIP_EVAL_VARIANTS=okna,calosc` porównuje okna z całą transkrypcją w jednym zapytaniu.
- `SKIP_EVAL_RAW=<plik>` zapisuje surowe odpowiedzi modelu.
- Klucz najlepiej wpisać w osobnej karcie terminala. W polu wiadomości `read -s` nie czyta z klawiatury.

### Znane braki

- Ocena z kluczem objęła jeden model (Mistral Small) i 6 odcinków. Przebiegi w aplikacji szły na atrapie, więc pytanie o kategorię w aplikacji sprawdziły tylko testy pakietu i ocena.
- Przygody Przedsiębiorców (wspólny blok sponsora i autopromocji na początku) model nadal pomija.
- Brak wyboru „analizuj tylko przy zasilaniu”. Transkrypcja godziny to ok. 1 min pracy jednego rdzenia.
- Domyślne kategorie z Ustawień Maca nie przechodzą na iOS (iOS ma własne).
- Transkrypcja dyktowaniem gubi część słów w swobodnej rozmowie i nazwy marek; lepszą transkrypcją może być Parakeet (później).
- Okno, które było w drodze przy zamknięciu aplikacji, idzie drugi raz.
- „Wykryj w pobranych odcinkach” wysyła do modelu wszystkie pobrane odcinki podcastu, których model nie oceniał; ich liczba jest w podpisie przycisku, ale bez osobnego potwierdzenia.
- Wybór `en-US` zamiast `en-ZA` zmienia też klucz pamięci podręcznej transkrypcji 11a dla angielskich książek: pierwsza synchronizacja po zmianie słucha nagrania od nowa.
