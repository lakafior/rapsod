// Pochodzenie: widoki odtwarzacza przeniesione z projektu Dove tego samego autora
// (`App/Dove/Features/Library/AudiobookViews.swift`, MPL-2.0) i dostosowane do macOS:
// panel boczny zamiast pełnego ekranu, pasek odtwarzania na dole okna, sterowanie w menu ikony,
// bez muzyki, kolejki i wyboru wyjścia AirPlay.

import SwiftUI

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

extension EnvironmentValues {
    /// Spacja (bez modyfikatorów) przełącza odtwarzanie. Okno biblioteki wyłącza ją, póki pole
    /// tekstowe ma fokus — skrót przycisku przejąłby spację, zanim trafi do pola.
    @Entry var playPauseOnSpace = true
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
            // Lista idzie za odtwarzaniem: nowy rozdział (także po przewinięciu) jest widoczny.
            .onChange(of: current) {
                if let current { withAnimation { proxy.scrollTo(current, anchor: .center) } }
            }
        }
    }
}
