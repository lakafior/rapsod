// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AudiobookshelfKit
import AudiobookshelfPlayback

// Pozycja zmienia się dwa razy na sekundę, więc czytają ją tylko małe widoki z czasem
// (`ChapterScrubber`, `MiniProgress`) — reszta ekranu odświeża się przy zmianie rozdziału i stanu.

/// Mini-odtwarzacz w miejscu na akcesorium paska zakładek: okładka, tytuł, rozdział, pauza i +30 s.
/// Tło i kształt daje system; gdy pasek zakładek się zwinie (`inline`), zostaje skrócona wersja.
struct MiniPlayerBar: View {
    let model: AppModel
    @Binding var showsPlayer: Bool
    @Environment(\.displayScale) private var displayScale
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @State private var cover: UIImage?

    var body: some View {
        let player = model.playback.player
        if let book = player.book {
            HStack(spacing: 12) {
                Button {
                    showsPlayer = true
                } label: {
                    HStack(spacing: 12) {
                        CoverImage(image: cover)
                            .frame(width: 32, height: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if placement != .inline {
                                // Jeden rozdział (zwykle odcinek podcastu) ma tytuł całości — wtedy autor.
                                Text((player.chapters.count > 1 ? player.currentChapter?.title : nil) ?? book.author ?? "")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Odtwarzacz: \(book.title)"))
                .accessibilityHint(Text("Otwiera pełny ekran odtwarzacza"))

                PlayPauseButton(player: player, size: .title3)
                if placement != .inline {
                    Button {
                        player.skip(by: AudiobookPlayer.skipForward)
                    } label: {
                        Image(systemName: "goforward.30").font(.title3)
                    }
                    .accessibilityLabel(Text("30 sekund do przodu"))
                }
            }
            .padding(.horizontal, 12)
            .overlay(alignment: .bottom) { MiniProgress(player: player) }
            .task(id: book.key) {
                cover = await model.currentSession?.cover(itemID: book.itemID, path: nil, size: 44, scale: displayScale)
            }
        }
    }
}

private struct MiniProgress: View {
    let player: AudiobookPlayer

    var body: some View {
        let duration = player.duration
        ProgressView(value: duration > 0 ? min(1, player.currentTime / duration) : 0)
            .progressViewStyle(.linear)
            .padding(.horizontal, 16)
            .accessibilityHidden(true)
    }
}

struct PlayPauseButton: View {
    let player: AudiobookPlayer
    var size: Font = .largeTitle

    var body: some View {
        Button {
            player.togglePlayPause()
        } label: {
            ZStack {
                if player.isLoading {
                    ProgressView()
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                }
            }
            .font(size)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .accessibilityLabel(Text(player.isPlaying ? "Pauza" : "Odtwarzaj"))
    }
}

/// Pełny ekran odtwarzacza: wysuwa się z mini-odtwarzacza (przejście „zoom”, zamykany gestem
/// w dół), tło z rozmytej okładki, duża okładka, suwak rozdziału, przeskoki, prędkość,
/// wyłącznik czasowy, AirPlay i rozdziały. W poziomie okładka obok sterowania.
struct PlayerScreen: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cover: UIImage?
    @State private var showsChapters = false
    /// Tryb „Tekst” (etap 11b): tekst książki zamiast dużej okładki.
    @AppStorage("player.showsText") private var showsText = false
    @State private var text = TextFollowModel()
    @Namespace private var artworkSpace

    private var player: AudiobookPlayer { model.playback.player }
    /// Tekst ma sens tylko dla książek (podcast nie ma e-booka).
    private var textAvailable: Bool { player.book.map { $0.episodeID == nil && $0.feedKey == nil } ?? false }
    private var textMode: Bool { showsText && textAvailable }

    var body: some View {
        ZStack {
            if let book = player.book {
                GeometryReader { proxy in
                    let landscape = proxy.size.width > proxy.size.height * 1.15
                    if textMode {
                        textLayout(book, size: proxy.size, landscape: landscape)
                            .transition(.opacity)
                    } else if landscape {
                        HStack(spacing: 36) {
                            artwork(side: min(proxy.size.height - 40, proxy.size.width * 0.42))
                            // Przewijana, gdy przy dużym tekście sterowanie się nie mieści.
                            ScrollView {
                                VStack(spacing: 18) {
                                    topBar
                                    info(book)
                                    ChapterScrubber(player: player)
                                    controls
                                    options
                                }
                                .padding(.vertical, 12)
                                .frame(minHeight: proxy.size.height - 24)
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .frame(maxWidth: 460)
                        }
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                    } else {
                        ScrollView {
                            VStack(spacing: 22) {
                                topBar
                                artwork(side: min(proxy.size.width - 48, 520, proxy.size.height * 0.5))
                                    .padding(.vertical, 8)
                                info(book)
                                ChapterScrubber(player: player)
                                controls
                                options
                            }
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                            .frame(maxWidth: 560)
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .transition(.opacity)
                    }
                }
                .task(id: book.key) {
                    cover = await model.currentSession?.cover(itemID: book.itemID, path: nil, size: 520, scale: displayScale)
                }
                // Mapę wczytujemy dopiero, gdy ktoś włączy tekst (i przy zmianie książki).
                .task(id: textMode ? book.key : nil) {
                    guard textMode else { return }
                    loadText(book)
                }
                .background { if textMode { TextTimeFeed(model: text, player: player) } }
            } else {
                VStack {
                    topBar.padding(24)
                    ContentUnavailableView("Nic nie gra", systemImage: "headphones")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ArtworkBackdrop(image: cover, fadesToBackground: false, dimming: textMode ? 0.66 : nil).ignoresSafeArea() }
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showsChapters) {
            ChapterList(player: player)
        }
        // Ekran nie gaśnie, gdy czyta się tekst w trakcie słuchania; blokada znika po pauzie i wyjściu.
        .onChange(of: textMode && player.isPlaying, initial: true) { _, keepAwake in
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func loadText(_ book: PlaybackBook) {
        guard let session = model.currentSession else { return }
        let itemID = book.itemID
        let auth = session.auth
        let downloads = session.downloads.manager
        text.load(key: session.scope + "|" + itemID, source: TextSyncSource(
            itemID: itemID,
            fetchItem: { try await auth.perform { try await $0.item(id: itemID, token: $1) } },
            fetchFile: { ino in try await auth.perform { try await $0.libraryFile(itemID: itemID, ino: ino, token: $1) } },
            downloadedCopy: { downloads.textSyncData(itemID: itemID) },
            updateDownloadedCopy: { downloads.storeTextSync($0, itemID: itemID) }
        ), cache: .standard())
    }

    private func toggleText() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.55, bounce: 0.12)) {
            showsText.toggle()
        }
    }

    /// Tryb tekstu: u góry mała okładka z tytułem, pod nią tekst, na dole zwarte sterowanie.
    /// W poziomie tekst po lewej, sterowanie w kolumnie po prawej.
    @ViewBuilder
    private func textLayout(_ book: PlaybackBook, size: CGSize, landscape: Bool) -> some View {
        if landscape {
            HStack(spacing: 20) {
                BookTextView(model: text, player: player)
                    .mask(Self.textFade)
                    .frame(maxWidth: .infinity)
                ScrollView {
                    VStack(spacing: 16) {
                        topBar
                        compactHeader(book)
                        ChapterScrubber(player: player)
                        controls
                        options
                    }
                    .padding(.vertical, 12)
                    .frame(minHeight: size.height - 24)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: min(400, size.width * 0.4))
            }
            .padding(.horizontal, 20)
        } else {
            VStack(spacing: 0) {
                VStack(spacing: 14) {
                    topBar
                    compactHeader(book)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 560)
                // Przy największych rozmiarach pasek z czterema przyciskami rozpychałby ekran;
                // tekst książki ma własną regulację rozmiaru.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                BookTextView(model: text, player: player, bottomInset: 8)
                    .mask(Self.textFade)
                    .frame(maxHeight: .infinity)
                VStack(spacing: 14) {
                    ChapterScrubber(player: player, compact: true)
                    compactControls
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                .frame(maxWidth: 560)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Tekst łagodnie znika przy górnej i dolnej krawędzi.
    private static var textFade: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0), .init(color: .black, location: 0.07),
            .init(color: .black, location: 0.9), .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    /// Mała okładka, tytuł i rozdział (rozdział otwiera listę rozdziałów).
    private func compactHeader(_ book: PlaybackBook) -> some View {
        HStack(spacing: 12) {
            CoverImage(image: cover)
                .matchedGeometryEffect(id: "artwork", in: artworkSpace)
                .frame(width: 54, height: 54)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.headline).lineLimit(1)
                if let chapter = player.currentChapter, player.chapters.count > 1 {
                    Button {
                        showsChapters = true
                    } label: {
                        Text(chapter.title).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Rozdział: \(chapter.title)"))
                    .accessibilityHint(Text("Pokazuje listę rozdziałów"))
                } else if let author = book.author {
                    Text(author).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Zwarte sterowanie w trybie tekstu: −15 s, odtwarzaj, +30 s, prędkość i rozdziały.
    private var compactControls: some View {
        HStack {
            Menu {
                Picker("Prędkość", selection: Binding(get: { player.rate }, set: { player.rate = $0 })) {
                    ForEach(AudiobookPlayer.rates, id: \.self) { rate in
                        Text(Self.rateLabel(rate)).tag(rate)
                    }
                }
            } label: {
                Text(Self.rateLabel(player.rate)).font(.subheadline.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text("Prędkość: \(Self.rateLabel(player.rate))"))
            Spacer()
            Button {
                player.skip(by: -AudiobookPlayer.skipBack)
            } label: {
                Image(systemName: "gobackward.15").font(.system(size: 26, weight: .medium))
            }
            .accessibilityLabel(Text("15 sekund wstecz"))
            Spacer()
            PlayPauseButton(player: player, size: .system(size: 42, weight: .semibold))
            Spacer()
            Button {
                player.skip(by: AudiobookPlayer.skipForward)
            } label: {
                Image(systemName: "goforward.30").font(.system(size: 26, weight: .medium))
            }
            .accessibilityLabel(Text("30 sekund do przodu"))
            Spacer()
            Button {
                showsChapters = true
            } label: {
                Image(systemName: "list.bullet").font(.title3).frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text("Rozdziały"))
            .disabled(player.chapters.count < 2)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 440)
    }

    /// Uchwyt, zamknięcie i menu.
    private var topBar: some View {
        HStack {
            Button("Zamknij", systemImage: "chevron.down") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            Spacer()
            Capsule().fill(.white.opacity(0.35)).frame(width: 40, height: 5).accessibilityHidden(true)
            Spacer()
            if textAvailable {
                HStack(spacing: 10) {
                    if textMode { BookTextSettingsMenu().labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle) }
                    Button {
                        toggleText()
                    } label: {
                        Label(textMode ? "Okładka" : "Tekst", systemImage: "quote.bubble")
                            .symbolVariant(textMode ? .fill : .none)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(Text("Tekst książki"))
                    .accessibilityValue(Text(textMode ? "włączony" : "wyłączony"))
                    .accessibilityHint(Text(textMode ? "Wraca do okładki" : "Pokazuje tekst zsynchronizowany z nagraniem"))
                }
            }
            Menu {
                Button("Oznacz jako ukończone", systemImage: "checkmark.circle") {
                    Task { await model.playback.markFinished() }
                    dismiss()
                }
                Button("Zakończ słuchanie", systemImage: "stop.circle", role: .destructive) {
                    Task { await model.playback.stop() }
                    dismiss()
                }
            } label: {
                Label("Więcej", systemImage: "ellipsis")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .controlSize(.large)
        // Cztery okrągłe przyciski w jednym wierszu — bez rozmiarów dostępności, które rozpychały ekran.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// Okładka — przy pauzie lekko mniejsza (bez animacji przy „Ogranicz ruch”).
    private func artwork(side: CGFloat) -> some View {
        CoverImage(image: cover, isPodcast: player.book?.episodeID != nil || player.book?.feedKey != nil)
            .matchedGeometryEffect(id: "artwork", in: artworkSpace)
            .frame(width: max(120, side), height: max(120, side))
            .scaleEffect(player.isPlaying || reduceMotion ? 1 : 0.86)
            .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.3), value: player.isPlaying)
            .accessibilityHidden(true)
    }

    private func info(_ book: PlaybackBook) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(book.title).font(.title3.bold()).lineLimit(3)
            if let author = book.author {
                Text(author).font(.body).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            if let chapter = player.currentChapter, player.chapters.count > 1 {
                Button {
                    showsChapters = true
                } label: {
                    Label(chapter.title, systemImage: "list.bullet")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .accessibilityLabel(Text("Rozdział: \(chapter.title)"))
                .accessibilityHint(Text("Pokazuje listę rozdziałów"))
            }
            if model.playback.isProgressLocal {
                // Odcinek ze strumienia, którego nie ma na serwerze (etap 10e).
                Label("Ze strumienia wydawcy · postęp tylko na tym telefonie", systemImage: "iphone")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let error = player.error ?? model.playback.loadError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if model.isOffline {
                Label("Brak połączenia z serwerem — pozycja zostanie wysłana po powrocie sieci.", systemImage: "wifi.slash")
                    .font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        HStack {
            Button {
                player.previousChapter()
            } label: {
                Image(systemName: "backward.end.fill").font(.title2)
            }
            .accessibilityLabel(Text("Poprzedni rozdział"))
            .disabled(player.chapters.count < 2)
            Spacer()
            Button {
                player.skip(by: -AudiobookPlayer.skipBack)
            } label: {
                Image(systemName: "gobackward.15").font(.system(size: 34, weight: .medium))
            }
            .accessibilityLabel(Text("15 sekund wstecz"))
            Spacer()
            PlayPauseButton(player: player, size: .system(size: 58, weight: .semibold))
            Spacer()
            Button {
                player.skip(by: AudiobookPlayer.skipForward)
            } label: {
                Image(systemName: "goforward.30").font(.system(size: 34, weight: .medium))
            }
            .accessibilityLabel(Text("30 sekund do przodu"))
            Spacer()
            Button {
                player.nextChapter()
            } label: {
                Image(systemName: "forward.end.fill").font(.title2)
            }
            .accessibilityLabel(Text("Następny rozdział"))
            .disabled(PlaybackTimeline.nextChapter(in: player.chapters, at: player.currentChapter?.start ?? 0) == nil)
        }
        .frame(maxWidth: 420)
        .buttonStyle(.plain)
    }

    private var options: some View {
        // Przy dużym tekście (Dynamic Type) w jednym wierszu się nie mieszczą — wtedy pod sobą.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) { optionButtons }
            VStack(spacing: 14) { optionButtons }
        }
        .labelStyle(StackedLabelStyle())
        .font(.caption.weight(.medium))
    }

    @ViewBuilder
    private var optionButtons: some View {
        Group {
            Menu {
                Picker("Prędkość", selection: Binding(get: { player.rate }, set: { player.rate = $0 })) {
                    ForEach(AudiobookPlayer.rates, id: \.self) { rate in
                        Text(Self.rateLabel(rate)).tag(rate)
                    }
                }
            } label: {
                Label(Self.rateLabel(player.rate), systemImage: "gauge.with.dots.needle.67percent")
            }
            .accessibilityLabel(Text("Prędkość: \(Self.rateLabel(player.rate))"))
            .frame(maxWidth: .infinity)

            SleepTimerMenu(player: player)
                .frame(maxWidth: .infinity)

            AirPlayButton()
                .frame(width: 30, height: 30)
                .frame(maxWidth: .infinity)

            if player.chapters.count > 1 {
                Button("Rozdziały", systemImage: "list.bullet") { showsChapters = true }
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
    }

    static func rateLabel(_ rate: Float) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

/// Suwak w obrębie rozdziału, czas od początku i do końca rozdziału oraz pozycja w całej książce.
private struct ChapterScrubber: View {
    let player: AudiobookPlayer
    /// Tryb tekstu: bez wiersza z czasem całej książki.
    var compact = false
    /// Wartość w trakcie przeciągania (sekundy od początku rozdziału); `nil` = pokazuje odtwarzacz.
    @State private var dragging: Double?

    var body: some View {
        let position = PlaybackTimeline.chapterPosition(in: player.chapters, at: player.currentTime, duration: player.duration)
        let elapsed = dragging ?? position.elapsed
        VStack(spacing: 6) {
            Slider(
                value: Binding(get: { elapsed }, set: { dragging = $0 }),
                in: 0...max(position.length, 1)
            ) { editing in
                if !editing, let value = dragging {
                    player.seek(to: position.bookTime(forElapsed: value))
                    dragging = nil
                }
            }
            .accessibilityLabel(Text(position.chapter == nil ? "Pozycja w książce" : "Pozycja w rozdziale"))
            .accessibilityValue(Text("\(TimeText.long(elapsed)) z \(TimeText.long(position.length))"))

            HStack {
                Text(TimeText.clock(elapsed))
                Spacer()
                Text("−" + TimeText.clock(max(0, position.length - elapsed)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

            if position.chapter != nil, !compact {
                let bookTime = position.start + elapsed
                Text("Całość: \(TimeText.clock(bookTime)) z \(TimeText.clock(player.duration)) · zostało \(TimeText.long((player.duration - bookTime) / Double(player.rate)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SleepTimerMenu: View {
    let player: AudiobookPlayer

    var body: some View {
        Menu {
            ForEach(SleepTimer.choices, id: \.self) { choice in
                Button(choice.label) { player.setSleepTimer(choice) }
            }
            if player.sleepTimer != nil {
                Button("Wyłącz", role: .destructive) { player.setSleepTimer(nil) }
            }
        } label: {
            if let deadline = player.sleepDeadline {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label(TimeText.clock(deadline.timeIntervalSince(context.date)), systemImage: "moon.zzz.fill")
                        .monospacedDigit()
                }
            } else if player.sleepTimer == .endOfChapter {
                Label("Koniec rozdziału", systemImage: "moon.zzz.fill")
            } else {
                Label("Wyłącznik", systemImage: "moon.zzz")
            }
        }
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        switch player.sleepTimer {
        case nil: "Wyłącznik czasowy: wyłączony"
        case .endOfChapter: "Wyłącznik czasowy: do końca rozdziału"
        case .minutes: "Wyłącznik czasowy: włączony"
        }
    }
}

private struct ChapterList: View {
    let player: AudiobookPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(player.chapters) { chapter in
                    let isCurrent = chapter.id == player.currentChapterID
                    Button {
                        player.jump(to: chapter)
                        dismiss()
                    } label: {
                        HStack {
                            Text(chapter.title)
                                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                                .fontWeight(isCurrent ? .semibold : .regular)
                            Spacer()
                            Text(TimeText.clock(chapter.duration))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .id(chapter.id)
                    .accessibilityLabel(Text("\(chapter.title), \(TimeText.long(chapter.duration))"))
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
                .onAppear {
                    if let id = player.currentChapterID { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .navigationTitle("Rozdziały")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gotowe") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Ikona nad krótkim podpisem — dolny rząd odtwarzacza (prędkość, wyłącznik, rozdziały).
struct StackedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon.font(.title3)
            configuration.title.lineLimit(1).monospacedDigit()
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect)
    }
}
