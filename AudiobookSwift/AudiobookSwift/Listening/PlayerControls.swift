// Pochodzenie: widoki odtwarzacza przeniesione z projektu Dove tego samego autora
// (`App/Dove/Features/Library/AudiobookViews.swift`, MPL-2.0) i dostosowane do macOS:
// panel boczny zamiast pełnego ekranu, pasek odtwarzania na dole okna, sterowanie w menu ikony,
// bez muzyki, kolejki i wyboru wyjścia AirPlay.

import SwiftUI

/// Poprzedni rozdział, −15 s, odtwarzaj/pauza, +30 s, następny rozdział.
struct TransportControls: View {
    let player: AudiobookPlayer
    var large = false
    @Environment(\.playPauseOnSpace) private var playPauseOnSpace

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
            .keyboardShortcut(playPauseOnSpace ? KeyboardShortcut(.space, modifiers: []) : nil)
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
        Picker("Prędkość", selection: Bindable(player).rate) {
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
