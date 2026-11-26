# Przegląd Rapsoda pod kątem Apple Human Interface Guidelines (etap 14a)

Stan na 2026-11-26, gałąź `claude/cranky-curran-bc69f9`. Dokument jest raportem do decyzji. Kod aplikacji nie był zmieniany.

**Metoda i jej granice.** Przegląd statyczny kodu w `Rapsod/Rapsod/` (sceny, menu, Biblioteka, Ustawienia, czytnik, okno tekstu, powitanie, „O programie”, skróty, dostępność, materiały i kolory) oraz porównanie z HIG dla Maca. Aplikacji **nie uruchamiałem** i nie oglądałem okien: ustalenia o zachowaniu w czasie działania są oznaczone „do sprawdzenia w działającej aplikacji”. Odniesienia do HIG podaję z nazwy sekcji (Menu bar, Keyboard, Toolbars, Sidebars, Windows, Settings, Alerts, Sheets, Accessibility, Materials).

Skala: **szacunek** mała (do ok. godziny pracy, jedna sesja z innymi drobiazgami), średnia (jedna sesja), duża (kilka sesji albo decyzja produktowa). **Priorytet** W (wysoki), Ś (średni), N (niski).

## Co jest już dobre (nie ruszać)

- Okna to sceny `Window` z własnym `id`; treść Biblioteki i Ustawień zwalnia się po zamknięciu (`ReleasedWhenClosed`, `UI/WindowActivation.swift:23`).
- `NavigationSplitView` z paskiem bocznym, `.inspector` na odtwarzacz, `.searchable` w pasku narzędzi (⌘F działa tak jak w aplikacjach systemowych), `ContentUnavailableView` dla pustych stanów i wyszukiwania (`HomeSearch.swift:99`).
- Arkusze mają `.defaultAction` i `.cancelAction` prawie wszędzie (ok. 60 miejsc), edytor pozycji blokuje zamknięcie z niezapisanymi zmianami (`ItemEditor.swift:385`, `:398`).
- Usuwanie ma potwierdzenia z rolą `.destructive` (ok. 50 okien dialogowych, 70 przycisków destrukcyjnych), np. `ItemActions.swift:71`.
- Ustawienia: `Form` w stylu `.grouped`, pasek boczny jak w Ustawieniach systemowych, wyszukiwanie po dawnych nazwach (`SettingsWindow.swift:250`), znacznik „Wymaga uwagi” z etykietą dla VoiceOver (`:313`).
- Ruch i kontrast: okno tekstu książki, banner pomijania i panel odtwarzacza respektują `accessibilityReduceMotion`; okno tekstu także `colorSchemeContrast` (`BookTextViews.swift:100`, `SkipViews.swift:43`, `PlayerViews.swift:17`).
- Przeciąganie: upuszczanie plików na okno Biblioteki otwiera arkusz wgrywania (`LibraryWindow.swift:76`), kolejność bibliotek zmienia się przeciąganiem (`SettingsPages.swift:116`).
- Przyciski przewijania i odtwarzania mają `accessibilityLabel`, elementy zaznaczone mają cechę `.isSelected` (`ItemCard.swift:97`), dekoracyjne okładki są ukryte dla VoiceOver.
- Media keys i „Teraz odtwarzane”: obsługuje je `AudiobookPlayer` (`MPRemoteCommandCenter`).

## 1. Struktura scen i okna

**1.1. `⌘Q` nie kończy aplikacji, a ten sam skrót znaczy co innego w dwóch menu.** — `UI/AppCommands.swift:32-39`, `UI/ServerMenu.swift:98-100`, `RapsodApp.swift:195-201`.
W menu aplikacji `⌘Q` to „Zamknij okna (serwer działa dalej)”, a „Zakończ Rapsod i wyłącz serwer” nie ma skrótu. W menu na pasku `⌘Q` to „Zakończ” z wyłączeniem serwera. Użytkownik, który naciśnie `⌘Q` w menu paska, kończy serwer, a w menu aplikacji go zostawia. HIG (Menu bar › App menu; Keyboard): `⌘Q` zawsze kończy aplikację; „Zamknij wszystkie okna” ma `⌥⌘W`. Dziś zamknięcie aplikacji jest też jedyną drogą, którą system używa przy wylogowaniu, więc `AppQuit` rozpoznaje zdarzenie z powodem.
Propozycja: `⌘Q` = „Zakończ Rapsod” z jednym pytaniem przy pierwszym użyciu („Zatrzymać serwer, czy zostawić go w tle?” z „Nie pytaj ponownie” i ustawieniem w Ogólnych), a „Zamknij okna” zostaje pod `⌥⌘W` (standardowa pozycja menu Okno „Zamknij wszystko”). Wymaga decyzji produktowej (serwer w tle to cecha, nie błąd).
Szacunek: średnia. Priorytet: **W**.

**1.2. Okno ustawień to własne `Window`, nie scena `Settings`.** — `RapsodApp.swift:57-64`, `UI/AppCommands.swift:18-30`.
Scena `Settings` daje: standardową pozycję „Ustawienia…” z `⌘,` zarządzaną przez system, okno bez przycisku pełnego ekranu i zoom, tytuł spójny z menu, zapamiętane położenie. Własne `Window` robi to ręcznie (`openSettings`, `bringToFront`, `DockIcon`). HIG (Settings): ustawienia w osobnym oknie z `⌘,`, bez pełnego ekranu, zmiany stosowane od razu. Powód odstępstwa jest zapewne praktyczny: scena `Settings` nie otwiera się niezawodnie z `MenuBarExtra` w aplikacji `LSUIElement`.
Propozycja: sprawdzić w działającej aplikacji, czy `Settings { SettingsWindow }` z `SettingsLink` i `@Environment(\.openSettings)` da się otworzyć z menu paska i z `MenuBarLabel`. Jeśli tak, przenieść; jeśli nie, zostawić `Window`, ale wyłączyć zoom i pełny ekran (`NSWindow.collectionBehavior`), żeby zachowywało się jak okno ustawień. Dla wszystkich pozostałych okien nie ma sensu zmieniać.
Szacunek: mała (zablokowanie zoomu) do średniej (przeniesienie sceny). Priorytet: Ś.

**1.3. Minimalne rozmiary okien uniemożliwiają kafelkowanie na 13″.** — `Listening/LibraryWindow.swift:53` (980×560), `UI/Settings/SettingsWindow.swift:269` (760×520).
Pół ekranu MacBooka Air 13″ to ok. 735 pt. Biblioteki nie da się ułożyć w połowie ekranu (macOS Sequoia/Tahoe: kafelkowanie), a Ustawienia ledwo. Panel odtwarzacza (340 pt) i pasek boczny (210 pt) zostawiają treści ok. 430 pt przy minimum. HIG (Windows › Resizing): okno nie powinno wymuszać większego rozmiaru, niż potrzebuje treści; adaptacja zamiast stałego minimum.
Propozycja: minimum Biblioteki ok. 640×480 i automatyczne chowanie panelu odtwarzacza (zastąpionego paskiem `MiniPlayerBar`) poniżej ok. 900 pt; minimum Ustawień ok. 640. Do sprawdzenia w działającej aplikacji przy 735 pt.
Szacunek: mała. Priorytet: Ś.

**1.4. Przywracanie okien wyłączone wszędzie.** — `RapsodApp.swift:28, 37, 46, 53, 62, 71, 78, 87`.
Każde okno ma `.restorationBehavior(.disabled)` i `.defaultLaunchBehavior(.suppressed)`. Ma to sens dla aplikacji z paskiem menu (nic nie wyskakuje po starcie), ale oznacza, że po ponownym uruchomieniu aplikacja zapomina otwartą sekcję Biblioteki, ścieżkę nawigacji i rozmiar okna (poza ostatnią stroną Ustawień, `SettingsNavigation.lastPageKey`). HIG (Windows › Restoring state): odtwarzać, co użytkownik zostawił.
Propozycja: `@SceneStorage` na bieżącą sekcję, bibliotekę i stan inspektora w Bibliotece; sprawdzić, czy rozmiar i położenie `Window` zapisują się mimo `.disabled`. Okien nie przywracać automatycznie przy starcie (zgodne z paskiem menu).
Szacunek: mała. Priorytet: N.

**1.5. Aplikacja `LSUIElement` ze zmienną polityką aktywacji.** — `Info.plist:5-6`, `App/DockIcon.swift:35-82`.
Ikona w Docku i menu główne pojawiają się dopiero po otwarciu okna i znikają po zamknięciu ostatniego. To znany, działający wzorzec aplikacji paskowych, ale Rapsod jest pełnym odtwarzaczem: przy otwartym oknie Biblioteki użytkownik zakłada, że aplikacja jest „zwykła”. Koszt: aplikacja znika z `⌘Tab` po zamknięciu okna, choć odtwarza dźwięk; `NSApp.hide(nil)` przy ostatnim oknie (`DockIcon.swift:77`) może przełączać fokus. HIG (Menu bar extras): aplikacja z oknami powinna mieć stałą obecność w Docku albo jawną opcję.
Propozycja: opcja w Ogólnych „Pokazuj ikonę w Docku: tylko przy otwartych oknach / zawsze”. Domyślne zachowanie zostaje. Decyzja użytkownika.
Szacunek: średnia. Priorytet: N.

**1.6. „O programie” jest własnym oknem, nie standardowym panelem.** — `UI/AboutWindow.swift:5-70`, `RapsodApp.swift:76-82`.
Brakuje ikony aplikacji, nazwy wersji w standardowym układzie i nota praw autorskich; okno ma 640 pt i pole przewijania na całą treść licencji. HIG (About window): standardowy panel z ikoną, nazwą, wersją, prawami autorskimi i opcjonalnymi „Credits”.
Propozycja: `NSApp.orderFrontStandardAboutPanel(options: [.credits: <noty>, .applicationVersion: …])`; wersję serwera dołożyć do credits; „Pokaż teksty licencji” jako link w credits. Okno własne usunąć.
Szacunek: mała. Priorytet: N.

**1.7. Okno powitalne.** — `UI/WelcomeWindow.swift`, `RapsodApp.swift:66-74`.
Zgodne z HIG (pierwsze uruchomienie, rozmiar od treści). Tekst odsyła do „menu na pasku menu” (`:20`), co przy `⌘,`/Pliku będzie nieaktualne po zmianach z punktu 2. Do poprawki przy okazji.
Szacunek: mała. Priorytet: N.

## 2. Pasek menu aplikacji

Stan: SwiftUI dodaje domyślne Edycja, Okno i Pomoc; aplikacja zastępuje pozycje „O programie”, „Ustawienia”, „Zakończ” i „Nowy” (`AppCommands.swift`) i dodaje „Odtwarzanie” (`PlaybackCommands.swift`). Poniżej braki i niezgodności.

**2.1. Menu „Plik” zawiera tylko „Otwórz bibliotekę” (`⌘O`) i zamykanie okna.** — `UI/AppCommands.swift:42-53`.
`⌘O` w HIG to „Otwórz…” plik, a nie okno. Rzeczy, które użytkownik robi najczęściej w Bibliotece (wgrać książkę, dodać podcast, dodać bibliotekę, utworzyć playlistę, skanować, pokazać w Finderze), są tylko w pasku narzędzi i arkuszach.
Propozycja: Plik: „Wgraj książkę…” (w bibliotece podcastów „Dodaj podcast…”, oba na `⌘N`, jako „nowa pozycja” bieżącej sekcji), „Dodaj bibliotekę…”, „Skanuj bibliotekę”, „Pokaż w Finderze”, „Zamknij okno” (`⌘W`, już dodaje SwiftUI). Pozycje sterowane przez `focusedSceneValue` z `LibraryBrowser`, wyszarzone, gdy okno Biblioteki nie jest aktywne. „Otwórz bibliotekę” przenieść do menu „Okno” z `⌘1` (tak jak Muzyka).
Szacunek: średnia. Priorytet: **W**.

**2.2. Brak menu „Widok”.** — nie ma `CommandGroup(.sidebar)`, `SidebarCommands()`, `ToolbarCommands()`, `InspectorCommands()`.
Konsekwencje: nie ma „Pokaż/Ukryj pasek boczny” (`⌃⌘S`), „Dostosuj pasek narzędzi…”, a przełącznik panelu odtwarzacza jest tylko przyciskiem w pasku (`LibraryWindow.swift:111`) bez skrótu i bez pozycji w menu. Brakuje też wyboru sortowania/rozmiaru okładek jako pozycji menu (dziś tylko `SortMenu` w pasku).
Propozycja: `SidebarCommands()`, `ToolbarCommands()`, `InspectorCommands()` (po przejściu na `.inspector` z `isPresented`, `⌥⌘I`), pozycje „Sortuj według” i „Rozmiar okładek” (po 14c); pełny ekran dodaje system, o ile okno ma zoom.
Szacunek: mała. Priorytet: **W**.

**2.3. Menu „Edycja” i „Znajdź”.** — `.searchable` daje `⌘F` fokusu w polu, ale brak pozycji „Znajdź” w menu Edycja i `⌘G`; w czytniku i oknie tekstu nie ma wyszukiwania w treści (`ReaderWindow.swift:336-351`, `BookTextViews.swift`).
Propozycja: `TextEditingCommands()`/`CommandGroup(after: .textEditing)` z „Znajdź w bibliotece” (`⌘F`) i „Znajdź w książce” (`⌘F` w czytniku, `WKWebView`/EPUB: `performTextFinderAction`).
Szacunek: średnia. Priorytet: Ś.

**2.4. Cofnij/Ponów nie obejmuje operacji na serwerze.** — brak użycia `UndoManager` w całym kodzie (`grep`).
Pola tekstowe mają systemowe Cofnij. Operacje na danych biblioteki (oznacz jako ukończone, usuń z playlisty, wyzeruj postęp, usuń z „Słuchaj dalej”, zmiana nazwy) są nieodwracalne albo odwracalne tylko ręcznie; wyjątek to „Cofnij” przy pomijaniu fragmentu (`SkipViews.swift`). HIG (Undo and redo): odwracalne działania na danych użytkownika powinny dać się cofnąć.
Propozycja: `UndoManager` z odwrotnymi wywołaniami API dla czterech najczęstszych operacji (ukończone/nieukończone, playlisty, postęp), a dla reszty zostawić potwierdzenia. Duży koszt względem korzyści.
Szacunek: duża (cały zestaw), mała dla „ukończone/nieukończone”. Priorytet: N.

**2.5. Menu „Pomoc” jest puste.** — brak `CommandGroup(replacing: .help)`.
SwiftUI pokaże szukajkę menu i nieaktywną pozycję „Rapsod Pomoc”. HIG (Help menu): odnośniki do dokumentacji i zgłaszania problemów.
Propozycja: „README Rapsoda”, „Zgłoś problem…” (adres repozytorium z `ABSSourceURL`, gdy ustawiony), „Dokumentacja audiobookshelf”, „Skróty klawiszowe” (arkusz z listą).
Szacunek: mała. Priorytet: Ś.

**2.6. Menu „Odtwarzanie”: kolizje i niejednoznaczne nazwy.** — `Listening/PlaybackCommands.swift:34-70`, `UI/ServerMenu.swift` (`MenuPlayerControls`), `Listening/PlayerControls.swift:42-52`.
- `⌘[` i `⌘]` (Wolniej/Szybciej) to w całym systemie **Wstecz i Dalej** (Safari, Finder, Muzyka, Książki). Biblioteka ma nawigację `NavigationStack` bez skrótu Wstecz (`LibraryWindow.swift:60-66`), więc użytkownik nie ma tego skrótu wcale. HIG (Keyboard): nie zajmować standardowych skrótów innymi akcjami. Propozycja: `⌘[`/`⌘]` dla Wstecz/Dalej w Bibliotece (pozycje w menu „Idź” albo Widok), prędkość na `⌥⌘[`/`⌥⌘]` albo `⌃⌘↑/↓`.
- „Cofnij 15 s” w menu Odtwarzanie i na pasku menu (`PlaybackCommands.swift:36`, `MiniPlayerBar.swift:56`) brzmi jak „Cofnij” z menu Edycja (Undo); VoiceOver i wyszukiwarka menu mylą oba. Propozycja: „Przewiń do tyłu 15 s” / „Przewiń do przodu 30 s”.
- Etykiety `"Cofnij 15 sekund"` i `"Naprzód 30 sekund"` są wpisane na stałe (`PlayerControls.swift:42, 47`), a menu bierze wartości z `AudiobookPlayer.skipBack/skipForward`; zmiana stałych rozjedzie opisy. Użyć stałych.
- Brak „Timer snu” w menu (jest tylko w odtwarzaczu, `PlayerControls.swift` `SleepMenu`) i „Idź do rozdziału…”.
- Spacja jako skrót przycisku (`PlayerControls.swift:34`) jest przemyślana (nie przechwytuje pól tekstowych), ale w menu Odtwarzanie pozycja „Odtwórz/Wstrzymaj” nie pokazuje skrótu; dopisać `Spacja` jako tekst pomocniczy w tytule nie jest możliwe, więc zostaje.
Szacunek: mała. Priorytet: Ś (kolizja `⌘[`), N (reszta).

**2.7. Menu „Okno”.** — `commandsRemoved()` na czytniku, powitaniu i „O programie” (`RapsodApp.swift:38, 80, 89`).
Zgodne z intencją: te okna nie muszą mieć pozycji „Nowe okno”. Do sprawdzenia w działającej aplikacji, czy `commandsRemoved` nie usuwa ich z listy w menu „Okno” (czytnik, który użytkownik chce przywołać, powinien tam być).
Szacunek: mała. Priorytet: N.

## 3. Skróty klawiszowe

Inwentarz własnych skrótów (poza `⌘W`, `⌘,`, `⌘H`, `⌘M` z systemu): `⌘Q` (zamknij okna / zakończ, p. 1.1), `⌘O` (otwórz bibliotekę, p. 2.1), `⌃⌘←/→` (−15 s/+30 s), `⌥⌘←/→` (rozdziały), `⌘[`/`⌘]` (prędkość, p. 2.6), `⌃⌘T`, `⌃⇧⌘T` (tekst), `Spacja` (odtwarzaj/pauza), `⌘↩` (wróć do miejsca w tekście, `BookTextViews.swift:125`), `⌘+`/`⌘−`/`⌘0` (rozmiar tekstu, `BookTextViews.swift:193-199`), `⌘←/→` (strony w czytniku, `ReaderWindow.swift:339-341`), `⌘S` (zapis w edytorach, `DetailsTab.swift:230`, `PodcastTabs.swift:284`, `ChaptersTab.swift:113`, `EpisodeSheets.swift:289`).

- `⌘←/→` w czytniku zmienia strony; w polach tekstowych `⌘←/→` to początek/koniec wiersza. Czytnik nie ma pola tekstowego, więc nie koliduje dziś; po dodaniu wyszukiwania (2.3) będzie. Strony i tak obsługują `←/→` (`:233-235`). Propozycja: usunąć `⌘←/→` z paska narzędzi albo zamienić na `⌘[`/`⌘]` po decyzji z 2.6. Szacunek: mała. Priorytet: N.
- `⌘+`/`⌘−`/`⌘0` w oknie tekstu są zgodne z HIG (Zoom), ale tylko w tym oknie; w czytniku rozmiar tekstu jest w popoverze „Wygląd” bez skrótów. Dodać te same skróty. Szacunek: mała. Priorytet: N.
- `⌘↩` to w systemie „Wyślij/Zatwierdź” (Mail, Wiadomości); „Wróć do bieżącego miejsca” lepiej na `⌘J` („Idź do zaznaczenia” w Xcode/Preview) albo bez skrótu. Szacunek: mała. Priorytet: N.
- `⌘S` w edytorach działa tylko w arkuszu, bez pozycji „Zapisz” w menu Plik (jest tylko klawisz). HIG: akcja ze skrótem ma być w menu. Dodać „Zapisz” do Pliku z `focusedSceneValue` aktywnego edytora. Szacunek: średnia. Priorytet: N.
- Skróty w `ServerMenu` (`⌘O`, `⌘,`, `⌘Q`) w menu `MenuBarExtra` działają tylko przy otwartym menu i wyglądają jak globalne. Do 14d.

## 4. Biblioteka (okno)

**4.1. Pasek narzędzi bez dostosowywania.** — `Listening/LibraryWindow.swift:103-119`, `Browse/ItemGrid.swift:84-103`.
Pasek składa się z elementów wstawianych przez sekcje (`.toolbar { ToolbarItemGroup … }`) bez `.toolbar(id:)` i `ToolbarItem(id:)`, więc „Dostosuj pasek narzędzi…” nie istnieje. HIG (Toolbars): dla aplikacji z wieloma sekcjami zapewnić dostosowanie, ważne akcje nigdy nie tylko w menu. Przy 14c (widok listy) dojdą kolejne elementy (przełącznik widoku, grupowanie), więc to właściwy moment.
Propozycja: `.toolbar(id: "library")` z `ToolbarItem(id:)` dla: wstecz/dalej, sortowanie, filtr, widok siatka/lista (14c), wgraj/dodaj, zaznaczanie, odtwarzacz; elementy domyślne i dostępne do dodania.
Szacunek: średnia. Priorytet: Ś.

**4.2. Pasek narzędzi nie ma Wstecz/Dalej, a historia nawigacji nie jest widoczna.** — `Listening/LibraryWindow.swift:60-66`.
`NavigationStack` w kolumnie szczegółów; powrót ze strony książki zależy od automatycznego przycisku wstecz (do sprawdzenia w działającej aplikacji na macOS 27) i od kliknięcia w pasek boczny (`LibraryWindow.swift:292`, wiersz sekcji wraca do korzenia). Brak menu historii (przytrzymanie przycisku) i skrótu (p. 2.6).
Propozycja: jawne przyciski Wstecz/Dalej w `ToolbarItem(placement: .navigation)` z `browser.path`, `⌘[`/`⌘]`.
Szacunek: średnia. Priorytet: Ś.

**4.3. Przycisk odtwarzania na okładce istnieje tylko po najechaniu myszą.** — `Listening/Browse/ItemCard.swift:101-123`.
`hoverAction` pojawia się wyłącznie przy `hovering`. Klawiatura (Full Keyboard Access) i VoiceOver nigdy go nie zobaczą; jedyna droga do „Odtwarzaj” z siatki to menu kontekstowe (`ItemCard.swift:96`). HIG (Accessibility): każda funkcja dostępna bez myszy.
Propozycja: `.accessibilityAction(named: "Odtwarzaj")` i „Czytaj” na karcie; `Return` otwiera, `⌘Return` odtwarza (po 14c w liście: standardowa akcja podwójnego kliknięcia/Return). Przycisk na hover zostawić jako skrót dla myszy.
Szacunek: mała. Priorytet: **W** (dostępność).

**4.4. Dwukliknięcia przez `onTapGesture` bez odpowiednika klawiaturowego.** — `Browse/PodcastEpisodes.swift:57`, `UI/Users/ListeningHistoryPage.swift:45`, `UI/Users/PhoneSheets.swift:196`, `Reader/PageReaders.swift:329-330`.
Odcinki i historia słuchania reagują tylko na dwuklik myszą; VoiceOver i klawiatura mają menu kontekstowe, ale brak `primaryAction`. W `PlaylistViews.swift:33-37, 66-76` zrobiono to poprawnie (`contextMenu(forSelectionType:primaryAction:)`).
Propozycja: ten sam wzorzec (`List(selection:)` + `contextMenu(forSelectionType:primaryAction:)`) w odcinkach i historii; strefy kliknięcia w czytniku komiksów dostają `accessibilityAction` „Poprzednia/Następna strona” (lub zostają, bo strzałki działają).
Szacunek: mała. Priorytet: Ś.

**4.5. Karty serii, autorów i kolekcji bez menu kontekstowego.** — menu kontekstowe jest tylko w siedmiu miejscach (`ItemCard.swift:96`, playlisty, lektorzy, odcinki, historia, kafle użytkowników).
HIG (Contextual menus): menu kontekstowe to skrót do akcji dostępnych też gdzie indziej, więc nie jest wymagane wszędzie, ale elementy, na których użytkownik spodziewa się „Skanuj”, „Pokaż w Finderze”, „Otwórz w Ustawieniach”, ich nie mają: wiersze paska bocznego (bibliotek, playlist), serie i autorzy. Do 14c (lista) dojdzie wiersz, więc zaplanować menu razem.
Szacunek: średnia. Priorytet: N.

**4.6. Zaznaczanie to osobny tryb, nie standardowe zaznaczanie.** — `Browse/ItemCard.swift:64-80`, `LibraryBrowser.isSelecting`.
Siatka nie obsługuje `⌘A`, `⇧`-klik ani `⌘`-klik jak Finder; zaznaczenie wymaga włączenia trybu i klikania w okładki. Ma to znaczenie dla wielu operacji (usuń, dodaj do playlisty). **Obejmie to 14c** (lista jak w Finderze) — tu tylko odnotowuję, żeby 14c uwzględniło `selection` w siatce, nie tylko w liście.
Szacunek: p. 14c. Priorytet: —.

**4.7. Przeciąganie z Biblioteki.** — `grep draggable` znajduje tylko kolejność bibliotek w Ustawieniach (`SettingsPages.swift:116`).
Nie można przeciągnąć książki na playlistę lub kolekcję, ani plik audio/okładkę do Findera; kolejność w playliście nie zmienia się przeciąganiem (`PlaylistViews.swift:61`, brak `.onMove`; do sprawdzenia, czy API serwera to wspiera). Odbiór upuszczenia plików działa (`LibraryWindow.swift:76`), a nakładka „Upuść, żeby wgrać” jest własna zamiast systemowej, ale spójna z HIG (Drag and drop).
Propozycja: `.draggable` karty/wiersza (`Transferable` z identyfikatorem pozycji) i `dropDestination` na wierszach playlist/kolekcji w pasku bocznym; sortowanie playlisty `onMove`. Razem z 14c.
Szacunek: średnia. Priorytet: Ś.

**4.8. Materiały zamiast Liquid Glass nad treścią.** — `LibraryWindow.swift:87` (nakładka upuszczania), `Manage/ItemActions.swift:49` (pływający wskaźnik zajętości), `Browse/ItemCard.swift:63` (znacznik #n), `Listening/MiniPlayerBar.swift:46-47` (`.background(.bar)` + `Divider`).
Aplikacja używa Liquid Glass tylko w oknie tekstu (`BookTextViews.swift:123, 148`). HIG (Materials, macOS 26+): pływające kontrolki nad treścią to `glassEffect`, a pasek pod treścią to `safeAreaBar`/efekt krawędzi przewijania; ręczny `Divider` i `.bar` wyglądają jak poprzednia generacja. Materiały systemowe same respektują „Zmniejsz przezroczystość”, więc to kwestia spójności, nie błędu.
Propozycja: `glassEffect(in: Capsule())` dla wskaźnika zajętości i nakładki; `safeAreaBar(edge: .bottom)` dla `MiniPlayerBar`; znacznik #n zostaje na materiale (jest na okładce).
Szacunek: mała. Priorytet: N.

**4.9. Stałe kolory.** — `Reader/PageReaders.swift:22-23, 321` (motywy sepia/ciemny/czarny tło — celowo), `Browse/ItemCard.swift:107, 116` (biało-czarna paleta na okładce — dekoracyjna), pasek postępu `.orange` (`ItemCard.swift`, `ProgressOverlay`), `.orange` ostrzeżenia (`SettingsWindow.swift:314`).
Brak wad dla ciemnego trybu (system). Pomarańczowy pasek postępu ignoruje kolor akcentu użytkownika; `.tint` byłby spójniejszy. Zwiększony kontrast: tylko okno tekstu go uwzględnia, reszta polega na kolorach systemowych, co jest akceptowalne; znaczniki na okładce (`.white.opacity(0.9)` nad dowolną okładką) mogą mieć słaby kontrast (do sprawdzenia).
Szacunek: mała. Priorytet: N.

## 5. Ustawienia

**5.1. Okno poza sceną `Settings`** — p. 1.2; minimalna szerokość — p. 1.3.

**5.2. Część stron wymaga „Zapisz”, część zapisuje od razu.** — `UI/Settings/BackupsSettingsPage.swift:292-294`, `NotificationsSettingsPage.swift:392`, `RemoteAccessAdvanced.swift:369`, a strona biblioteki zapisuje natychmiast.
HIG (Settings): zmiany stosują się od razu, bez „Zapisz”. Dla ustawień serwera (SMTP, limity kopii) przycisk jest uzasadniony, bo zapis to wywołanie sieciowe z możliwym błędem. Spójność: oznaczyć takie karty wspólnym wzorcem („Zastosuj” + stan „niezapisane zmiany” jak w edytorze pozycji) i nie mieszać w jednej stronie.
Szacunek: średnia. Priorytet: N.

**5.3. Podstrony i nawigacja.** — `SettingsWindow.swift:259-269`.
Ścieżka podstron w `NavigationStack` ze strzałką wstecz jest zgodna ze stylem Ustawień systemowych. `.toolbar(removing: .sidebarToggle)` (`:254`) blokuje chowanie paska; akceptowalne (jak Ustawienia systemowe).
Szacunek: —. Priorytet: —.

**5.4. Pole szukania w pasku bocznym.** — `SettingsWindow.swift:250`.
Pasek ma `.searchable(placement: .sidebar)`, ale nie `⌘F` w oknie ustawień (do sprawdzenia w działającej aplikacji, czy skrót fokusuje pole).
Szacunek: mała. Priorytet: N.

## 6. Czytnik, okno tekstu, web UI

**6.1. Czytnik.** — `Listening/Reader/ReaderWindow.swift:176-211, 336-351`. Pasek narzędzi ma Wstecz/Dalej i „Wygląd” (popover) — zgodnie z HIG; brak: wyszukiwania w treści (2.3), skrótów rozmiaru tekstu (3), udostępniania/„Pokaż w Finderze”, zapamiętanego rozmiaru okna per książka. Okno z `.restorationBehavior(.disabled)` jest tymczasowe z założenia.
Szacunek: średnia. Priorytet: N.

**6.2. Okno tekstu książki.** — `Listening/TextSync/*`. Dobrze: motion/contrast, glass, rozmiar tekstu z `⌘+/−/0`. Do poprawy: `⌘↩` (3); `BookTextCanvas` jest własnym widokiem rysującym — dostępność tekstu dla VoiceOver do sprawdzenia w działającej aplikacji (czy zdania są elementami dostępności, czy cały canvas to jeden obraz).
Szacunek: średnia (jeśli canvas bez dostępności). Priorytet: **W**, jeśli potwierdzi się brak.

**6.3. Web UI** — `UI/WebUIWindow.swift`, `UI/WebUIView.swift`. Wyjście awaryjne, linki zewnętrzne otwierają przeglądarkę (`WebUIView.swift:125`). Bez uwag.

## 7. Dostępność (VoiceOver, klawiatura, tekst)

- **Suwak postępu** w rozdziale (`Listening/ChapterViews.swift:22-40`) nie ma `accessibilityValue` z czasem; VoiceOver przeczyta wartość liczbową (sekundy) lub procent. Dodać `accessibilityValue` „12 minut 30 sekund z 45 minut” i `accessibilityAdjustableAction` z krokiem 15/30 s. Mała, **W**.
- **Ikona na pasku menu**: `accessibilityLabel("Rapsod")` bez stanu (`RapsodApp.swift:107`). Dodać stan („Rapsod, serwer działa”) — do 14d.
- **Przyciski tylko z ikoną** mają `.help` (92 użycia) i w większości `accessibilityLabel`. Przeglądem: `ItemActions`, `PodcastTabs`, `CoverTab` (do sprawdzenia, czy każdy `Image(systemName:)`-przycisk ma etykietę; `grep` pokazuje 88 miejsc z `accessibility*` na 57 użyć symboli, co sugeruje pojedyncze braki). Mała, Ś.
- **Cel kliknięcia i fokus:** wiersze w `List` z `Button(.plain)` i `contentShape` (np. `PlaylistViews.swift:23-33`) są dostępne; karty siatki także (`ItemCard.swift:95-98`), ale bez widocznego pierścienia fokusu klawiatury w trybie własnej siatki (`PagedGrid`) — do sprawdzenia w działającej aplikacji ze Full Keyboard Access.
- **Rozmiar tekstu:** macOS nie ma Dynamic Type; używane są style tekstu (`.callout`, `.caption`, `.title2`). Stałe rozmiary `.font(.system(size:))` są tylko dla ikon i awatarów (13 miejsc, np. `PlayerControls.swift:29`, `AvatarStore.swift:157-170`), co jest w porządku. Priorytet: —.
- **Zwiększony kontrast, zmniejszona przezroczystość, mniej ruchu:** system obsługuje materiały i `glassEffect`; własne animacje respektują ruch (okno tekstu, banner, panel). Niesprawdzone: `withAnimation` w `PlayerViews.swift:77` jest poprawne; brak innych znanych animacji bez sprawdzenia `reduceMotion` (`grep` na `withAnimation` do dokończenia przy 14f).
- **Kolor jako jedyny nośnik znaczenia:** pasek postępu (pomarańczowy pasek bez wartości liczbowej na okładce), ikony ostrzeżeń są z symbolami (OK). `differentiateWithoutColor` nie jest używany; pasek postępu ma `accessibilityLabel` z procentem (`ItemCard.swift`). Priorytet: N.

## 8. Spójność nazw, wielokropków i ikon

- **Wielokropek.** Przyciski otwierające arkusz bez wielokropka: „Dodaj podcast” (`Browse/ItemGrid.swift:87`), „Wgraj książkę” (`:93`) — to etykiety w pasku narzędzi, a HIG dopuszcza rzeczownikowe etykiety, ale pozycje tych akcji w menu Plik (2.1) mają mieć „…”. Reszta jest spójna (`Zmień nazwę…`, `Edytuj…`, `Usuń…`, `Podłącz telefon…`); pozostałe niespójne („Zmień nazwę” bez „…” w `LibraryManagement.swift` obok „Zmień nazwę…” tamże — do sprawdzenia, który wariant otwiera arkusz) przejrzeć przy 14f. Mała, N.
- **Nazwy.** „Biblioteka” (okno) i „biblioteka” (obiekt serwera) są użyte dla dwóch rzeczy; „Otwórz bibliotekę” w menu to okno. Po zmianie z 2.1 nazwa pozycji menu „Okno › Biblioteka” rozwiązuje to. „Ustawienia” (okno) i „Ustawienia aplikacji” (ROADMAP) są spójne w kodzie („Ustawienia…”).
- **Ikony SF Symbols:** używane zgodnie z konwencją (`books.vertical`, `mic`, `play.circle.fill`, `sidebar.trailing`). `person.2.crop.square.stack` dla „Użytkowników” (`SettingsWindow.swift:50`) jest nietypowy; `person.2` byłoby czytelniejsze. Ikona „Odtwarzacz” (`sidebar.trailing`) to symbol panelu, nie odtwarzacza; po dodaniu pozycji menu Widok > „Pokaż odtwarzacz” zostaje. Mała, N.
- **Alerty:** tytuły w formie pytania i zwięzłe („Usunąć „X”?”), przyciski opisują akcję (nie „OK”) poza kilkoma „OK” (`LibraryWindow.swift:145` „Nie udało się” → „OK”, standard). Bez uwag.

## 9. Co obejmą kolejne etapy 14b–14e i 14g (tylko odnotowane)

- **14b — aktualizacje z GitHuba:** pozycja „Sprawdź aktualizacje…” w menu aplikacji, stan w „O programie” (p. 1.6, jeśli panel standardowy: link w credits), ustawienie automatycznych sprawdzeń w Ogólnych.
- **14c — lista jak w Finderze:** widok listy/kolumn w Bibliotece, standardowe zaznaczanie (4.6), sortowanie po kolumnach, menu kontekstowe wierszy (4.5), przeciąganie (4.7), akcja główna (4.3, 4.4) i przełącznik widoku w pasku (4.1).
- **14d — menu na pasku systemowym:** przegląd `ServerMenu` (skróty w `MenuBarExtra`, stan w `accessibilityLabel`, `⌘Q` z 1.1, pozycje odtwarzacza i serwera, „Podłącz telefon…”).
- **14e — powiadomienia i Skróty:** powiadomienia (koniec skanu, błąd serwera, nowy odcinek), akcje Skrótów (App Intents), upuszczenie folderu na ikonę paska.
- **14g — angielski:** katalog tekstów (`String(localized:)`/`LocalizedStringResource` dla tekstów poza `Text`/`Button`), reguły liczby mnogiej (np. „Pozycje: \(n)”, `PlaylistViews.swift:26`), skróty w menu, nazwy menu systemowych.

## 10. Proponowany zakres etapu 14f

Podział na trzy paczki, od najbardziej wartościowej:

**14f-1. Menu i skróty (Ś–W, ok. jedna sesja).**
1. Decyzja o `⌘Q` i pytanie przy zakończeniu (1.1), „Zamknij wszystkie okna” pod `⌥⌘W`.
2. Menu Plik i Okno (2.1): „Wgraj książkę…”, „Dodaj bibliotekę…”, „Dodaj podcast…”, „Skanuj”, „Pokaż w Finderze”; „Biblioteka” w menu Okno z `⌘1`; wyrzucić `⌘O`.
3. Menu Widok (2.2): `SidebarCommands`, `ToolbarCommands`, `InspectorCommands`, pozycja „Pokaż/Ukryj odtwarzacz”.
4. Menu Pomoc (2.5).
5. Kolizja `⌘[`/`⌘]` (2.6) i Wstecz/Dalej w Bibliotece (4.2); zmiana „Cofnij 15 s” na „Przewiń do tyłu 15 s”; stałe zamiast tekstów w etykietach.
6. `⌘↩` w oknie tekstu (3).

**14f-2. Dostępność i klawiatura (W, mała sesja).**
1. Akcje dostępności „Odtwarzaj”/„Czytaj” na karcie (4.3).
2. `primaryAction` zamiast `onTapGesture(count: 2)` (4.4).
3. `accessibilityValue` suwaka postępu (7).
4. Sprawdzenie dostępności `BookTextCanvas` (6.2) w działającej aplikacji; jeśli brak, osobny drobny etap.
5. Przegląd etykiet przycisków z samą ikoną.

**14f-3. Okna i wygląd (Ś–N, mała sesja).**
1. Minimalne rozmiary i kafelkowanie (1.3), zablokowanie zoomu okna Ustawień albo przejście na scenę `Settings` (1.2).
2. Standardowy panel „O programie” (1.6, po 14b, bo dochodzi „Sprawdź aktualizacje…”).
3. `.toolbar(id:)` w Bibliotece (4.1), po 14c.
4. `glassEffect`/`safeAreaBar` zamiast materiałów (4.8), `.tint` dla paska postępu (4.9).
5. `@SceneStorage` dla sekcji i inspektora (1.4).

**Poza zakresem 14f (albo tylko na życzenie):** pełne Cofnij/Ponów dla operacji na serwerze (2.4, duży koszt), opcja stałej ikony w Docku (1.5), zmiana strategii zapisywania w Ustawieniach (5.2), menu kontekstowe dla serii/autorów (4.5, razem z 14c).

**Zalecane do sprawdzenia w działającej aplikacji przed 14f** (nie robiłem tego w tym przeglądzie): przycisk wstecz w `NavigationStack` na macOS 27, kafelkowanie przy 735 pt, zapamiętywanie rozmiaru okien mimo `.restorationBehavior(.disabled)`, `⌘F` w oknie Ustawień, pierścień fokusu siatki, dostępność `BookTextCanvas`, pozycje czytnika w menu Okno.
