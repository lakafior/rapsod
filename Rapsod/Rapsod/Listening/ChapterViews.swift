// Pochodzenie: widoki odtwarzacza przeniesione z projektu Dove tego samego autora
// (`App/Dove/Features/Library/AudiobookViews.swift`, MPL-2.0) i dostosowane do macOS:
// panel boczny zamiast pełnego ekranu, pasek odtwarzania na dole okna, sterowanie w menu ikony,
// bez muzyki, kolejki i wyboru wyjścia AirPlay.

import AudiobookshelfPlayback
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
            // VoiceOver: czas w rozdziale słowami zamiast liczby sekund; strzałki przewijają
            // o te same odcinki co przyciski (etap 14f).
            .accessibilityLabel("Pozycja w rozdziale")
            .accessibilityValue("\(PlaybackFormat.spokenDuration(shown - start)) z \(PlaybackFormat.spokenDuration(end - start))")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: player.skip(by: AudiobookPlayer.skipForward)
                case .decrement: player.skip(by: -AudiobookPlayer.skipBack)
                @unknown default: break
                }
            }
            SkipMarkersBar(plan: player.skipPlan, range: start...end)
                .padding(.horizontal, 6)
            HStack {
                Text(PlaybackFormat.clock(shown - start, rounding: .toNearestOrEven))
                Spacer()
                Text("Całość: \(PlaybackFormat.clock(player.duration - shown, rounding: .toNearestOrEven)) do końca" + (player.rate != 1 ? " (\(PlaybackFormat.clock((player.duration - shown) / Double(player.rate), rounding: .toNearestOrEven)) przy \(PlaybackFormat.rate(player.rate)))" : ""))
                    .accessibilityIdentifier("player.remaining")
                Spacer()
                Text("-" + PlaybackFormat.clock(end - shown, rounding: .toNearestOrEven))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
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
                            Text(PlaybackFormat.clock(chapter.duration, rounding: .toNearestOrEven)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
