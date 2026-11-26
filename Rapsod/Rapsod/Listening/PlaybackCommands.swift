import AudiobookshelfPlayback
import SwiftUI

/// Menu „Odtwarzanie” w menu głównym: te same polecenia co przyciski odtwarzacza.
/// Skróty tylko z modyfikatorami — ⌘←/⌘→ ma czytnik (strony), ⌘[ i ⌘] to Wstecz/Dalej (menu Widok),
/// a spację (odtwarzaj/pauza) obsługuje przycisk w oknie biblioteki, bo w menu przejmowałaby ją
/// z pól tekstowych. „Przewiń do tyłu”, nie „Cofnij” — to drugie to Undo z menu Edycja.
struct PlaybackCommands: Commands {
    let player: AudiobookPlayer

    var body: some Commands {
        CommandMenu("Odtwarzanie") {
            PlaybackMenuItems(player: player)
        }
    }
}

/// Pozycje menu jako widok: obserwacja odtwarzacza działa tu tak jak w każdym widoku.
/// Czyta tylko książkę, stan, rozdziały i prędkość — nie czas, więc menu nie przebudowuje się
/// w trakcie słuchania.
private struct PlaybackMenuItems: View {
    let player: AudiobookPlayer
    @Environment(\.openWindow) private var openWindow
    @AppStorage(BookTextSettings.panelKey) private var showsText = false

    var body: some View {
        let loaded = player.book != nil
        let hasChapters = player.chapters.count > 1
        let faster = AudiobookPlayer.rates.first { $0 > player.rate + 0.001 }
        let slower = AudiobookPlayer.rates.last { $0 < player.rate - 0.001 }

        Button(player.isPlaying ? "Wstrzymaj" : "Odtwórz") { player.togglePlayPause() }
            .disabled(!loaded)

        Divider()

        Button(PlaybackLabels.back) { player.skip(by: -AudiobookPlayer.skipBack) }
            .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
            .disabled(!loaded)
        Button(PlaybackLabels.forward) { player.skip(by: AudiobookPlayer.skipForward) }
            .keyboardShortcut(.rightArrow, modifiers: [.control, .command])
            .disabled(!loaded)

        Divider()

        Button("Poprzedni rozdział") { player.previousChapter() }
            .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
            .disabled(!loaded || !hasChapters)
        Button("Następny rozdział") { player.nextChapter() }
            .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
            .disabled(!loaded || !hasChapters)

        Divider()

        Button("Szybciej") { if let faster { player.rate = faster } }
            .keyboardShortcut("]", modifiers: [.option, .command])
            .disabled(!loaded || faster == nil)
        Button("Wolniej") { if let slower { player.rate = slower } }
            .keyboardShortcut("[", modifiers: [.option, .command])
            .disabled(!loaded || slower == nil)
        Button("Normalna prędkość") { player.rate = 1 }
            .disabled(!loaded || player.rate == 1)

        Menu("Timer snu") {
            ForEach(SleepTimer.choices, id: \.self) { choice in
                Button(choice.label) { player.setSleepTimer(choice) }
            }
            if player.sleepTimer != nil {
                Divider()
                Button("Wyłącz timer") { player.setSleepTimer(nil) }
            }
        }
        .disabled(!loaded)

        Divider()

        // Tekst książki zsynchronizowany z nagraniem (etap 11b).
        Toggle("Tekst w odtwarzaczu", isOn: $showsText)
            .keyboardShortcut("t", modifiers: [.control, .command])
        Button("Tekst w osobnym oknie") { openWindow(id: BookTextWindow.windowID) }
            .keyboardShortcut("t", modifiers: [.control, .shift, .command])
    }
}

/// Nazwy przeskoków z długości w `AudiobookPlayer` — menu, przyciski i VoiceOver mówią to samo.
@MainActor
enum PlaybackLabels {
    static var back: String { "Przewiń do tyłu \(Int(AudiobookPlayer.skipBack)) s" }
    static var forward: String { "Przewiń do przodu \(Int(AudiobookPlayer.skipForward)) s" }
    static var backSpoken: String { "Przewiń do tyłu \(Int(AudiobookPlayer.skipBack)) sekund" }
    static var forwardSpoken: String { "Przewiń do przodu \(Int(AudiobookPlayer.skipForward)) sekund" }
}
