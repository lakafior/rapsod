// Pochodzenie: widoki odtwarzacza przeniesione z projektu Dove tego samego autora
// (`App/Dove/Features/Library/AudiobookViews.swift`, MPL-2.0) i dostosowane do macOS:
// panel boczny zamiast pełnego ekranu, pasek odtwarzania na dole okna, sterowanie w menu ikony,
// bez muzyki, kolejki i wyboru wyjścia AirPlay.

import SwiftUI

/// Pełny odtwarzacz w panelu bocznym okna: okładka, rozdział, suwak, przewijanie,
/// prędkość, timer usypiania i lista rozdziałów.
struct PlayerPanel: View {
    let listening: ListeningController
    @State private var cover: NSImage?

    private var player: AudiobookPlayer { listening.player }

    var body: some View {
        if let book = player.book {
            VStack(spacing: 14) {
                CoverView(image: cover, symbol: "headphones")
                    .frame(maxWidth: 220, maxHeight: 220)
                    .shadow(radius: 8, y: 4)
                    .task(id: book.itemID) { cover = await listening.cover(for: book.itemID, path: listening.nowPlayingCoverPath, size: 300) }

                VStack(spacing: 3) {
                    Text(book.title).font(.headline).multilineTextAlignment(.center).lineLimit(2)
                    if let author = book.author { Text(author).foregroundStyle(.secondary).lineLimit(1) }
                    if book.chapters.count > 1, let chapter = player.currentChapter {
                        Text(chapter.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }

                ChapterScrubber(player: player)

                TransportControls(player: player, large: true)

                if let error = player.error {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                HStack {
                    SpeedMenu(player: player)
                    Spacer()
                    SleepMenu(player: player)
                    Spacer()
                    Menu {
                        Button("Oznacz jako ukończone", systemImage: "checkmark.circle") {
                            Task { await listening.markFinished() }
                        }
                        Button("Zatrzymaj i zamknij", systemImage: "xmark.circle") {
                            Task { await listening.stopPlayback() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Więcej")
                }
                .controlSize(.small)

                ChapterList(player: player)
            }
            .padding()
        } else {
            ContentUnavailableView("Nic nie gra", systemImage: "headphones", description: Text("Wybierz książkę z listy."))
        }
    }
}

/// Okładka albo zastępczy symbol.
struct CoverView: View {
    let image: NSImage?
    var symbol = "book.closed"

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { Image(systemName: symbol).foregroundStyle(.secondary) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Suwak w obrębie bieżącego rozdziału (w długiej książce cała oś byłaby za gęsta)
/// i czas do końca książki. Jedyny duży widok, który czyta czas dwa razy na sekundę.
struct ChapterScrubber: View {
    let player: AudiobookPlayer
    @State private var scrubbing: Double?
    @State private var isDragging = false

    var body: some View {
        let chapter = player.currentChapter
        let start = chapter?.start ?? 0
        let end = max(chapter?.end ?? player.duration, start + 1)
        let shown = scrubbing ?? player.currentTime
        VStack(spacing: 2) {
            Slider(
                value: Binding(get: { min(max(shown, start), end) }, set: { value in
                    if isDragging {
                        scrubbing = value
                    } else {
                        // Zmiana bez przeciągania (klawiatura, VoiceOver): przewija od razu.
                        player.seek(to: value)
                    }
                }),
                in: start...end
            ) { editing in
                isDragging = editing
                if !editing, let scrubbing {
                    player.seek(to: scrubbing)
                }
                if !editing { scrubbing = nil }
            }
            .controlSize(.small)
            .disabled(player.book == nil)
            .accessibilityIdentifier("player.scrubber")
            HStack {
                Text(Self.time(shown - start))
                Spacer()
                Text("Całość: \(Self.time(player.duration - shown)) do końca" + (player.rate != 1 ? " (\(Self.time((player.duration - shown) / Double(player.rate))) przy \(SpeedMenu.label(player.rate)))" : ""))
                    .accessibilityIdentifier("player.remaining")
                Spacer()
                Text("-" + Self.time(end - shown))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    static func time(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, seconds) : 0
        return Duration.seconds(value).formatted(.time(pattern: value >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// Poprzedni rozdział, −15 s, odtwarzaj/pauza, +30 s, następny rozdział.
struct TransportControls: View {
    let player: AudiobookPlayer
    var large = false

    var body: some View {
        HStack(spacing: large ? 22 : 14) {
            if large {
                Button { player.previousChapter() } label: { Image(systemName: "backward.end.fill") }
                    .accessibilityLabel("Poprzedni rozdział")
                    .help("Poprzedni rozdział")
            }
            Button { player.skip(by: -AudiobookPlayer.skipBack) } label: { Image(systemName: "gobackward.15") }
                .accessibilityLabel("Cofnij 15 sekund")
                .accessibilityIdentifier("player.back")
                .help("Cofnij 15 s")
            Button { player.togglePlayPause() } label: {
                ZStack {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: large ? 48 : 28))
                        .opacity(player.isLoading ? 0.3 : 1)
                    if player.isLoading { ProgressView().controlSize(.small) }
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(player.isPlaying ? "Pauza" : "Odtwarzaj")
            .accessibilityIdentifier("player.playPause")
            Button { player.skip(by: AudiobookPlayer.skipForward) } label: { Image(systemName: "goforward.30") }
                .accessibilityLabel("Naprzód 30 sekund")
                .accessibilityIdentifier("player.forward")
                .help("Naprzód 30 s")
            if large {
                Button { player.nextChapter() } label: { Image(systemName: "forward.end.fill") }
                    .accessibilityLabel("Następny rozdział")
                    .accessibilityIdentifier("player.nextChapter")
                    .help("Następny rozdział")
            }
        }
        .font(large ? .title2 : .title3)
        .buttonStyle(.plain)
    }
}

struct SpeedMenu: View {
    let player: AudiobookPlayer

    var body: some View {
        Picker("Prędkość", selection: Binding(get: { player.rate }, set: { player.rate = $0 })) {
            ForEach(AudiobookPlayer.rates, id: \.self) { Text(Self.label($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .help("Prędkość odtwarzania")
        .accessibilityIdentifier("player.speed")
    }

    static func label(_ rate: Float) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

struct SleepMenu: View {
    let player: AudiobookPlayer

    var body: some View {
        Menu {
            ForEach(AudiobookPlayer.SleepTimer.choices, id: \.self) { choice in
                Button(choice.label) { player.setSleepTimer(choice) }
            }
            if player.sleepTimer != nil {
                Divider()
                Button("Wyłącz timer") { player.setSleepTimer(nil) }
            }
        } label: {
            if let deadline = player.sleepDeadline {
                Label { Text(deadline, style: .timer).monospacedDigit() } icon: { Image(systemName: "moon.zzz.fill") }
            } else if player.sleepTimer == .endOfChapter {
                Label("Koniec rozdziału", systemImage: "moon.zzz.fill")
            } else {
                Label("Timer", systemImage: "moon.zzz")
            }
        }
        .fixedSize()
        .help("Timer usypiania")
        .accessibilityIdentifier("player.sleep")
    }
}

/// Wszystkie rozdziały; kliknięcie przechodzi do rozdziału.
struct ChapterList: View {
    let player: AudiobookPlayer

    var body: some View {
        let current = player.currentChapterID
        ScrollViewReader { proxy in
            List(player.chapters) { chapter in
                Button {
                    player.jump(to: chapter)
                } label: {
                    HStack {
                        Text(chapter.title).lineLimit(2)
                        Spacer()
                        if chapter.id == current {
                            Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill").foregroundStyle(.tint)
                        } else {
                            Text(ChapterScrubber.time(chapter.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(chapter.id)
            }
            .listStyle(.inset)
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
        }
    }
}

/// Pasek na dole okna, gdy coś jest załadowane: okładka, tytuł, rozdział, sterowanie.
struct MiniPlayerBar: View {
    let listening: ListeningController
    @Binding var showsPlayer: Bool
    @State private var cover: NSImage?

    var body: some View {
        let player = listening.player
        if let book = player.book {
            HStack(spacing: 12) {
                CoverView(image: cover, symbol: "headphones")
                    .frame(width: 36, height: 36)
                    .task(id: book.itemID) { cover = await listening.cover(for: book.itemID, path: listening.nowPlayingCoverPath, size: 40) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(book.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(player.currentChapter?.title ?? book.author ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                TransportControls(player: player)
                Button { showsPlayer.toggle() } label: { Image(systemName: "sidebar.trailing") }
                    .buttonStyle(.borderless)
                    .help(showsPlayer ? "Schowaj odtwarzacz" : "Pokaż odtwarzacz")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

/// Sterowanie w menu ikony na pasku menu. Czyta tylko tytuł i stan odtwarzania —
/// nie czas, więc menu nie przebudowuje się w trakcie słuchania.
struct MenuPlayerControls: View {
    let player: AudiobookPlayer

    var body: some View {
        if let book = player.book {
            Text(book.title)
            Button(player.isPlaying ? "Pauza" : "Odtwarzaj") { player.togglePlayPause() }
            Button("Cofnij 15 s") { player.skip(by: -AudiobookPlayer.skipBack) }
            Button("Naprzód 30 s") { player.skip(by: AudiobookPlayer.skipForward) }
            Divider()
        }
    }
}
