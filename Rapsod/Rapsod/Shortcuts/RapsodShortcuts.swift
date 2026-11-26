import AppIntents

/// Gotowe Skróty Rapsodu (etap 14e): widoczne w aplikacji Skróty i w Spotlight bez konfiguracji.
/// System pozwala na najwyżej 10 — przeskoki w odtwarzaczu są tylko akcjami do własnych Skrótów.
/// Każda fraza zawiera nazwę aplikacji (wymóg systemu).
struct RapsodShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ContinueListeningIntent(), phrases: [
            "Kontynuuj słuchanie w \(.applicationName)",
            "Słuchaj dalej w \(.applicationName)",
        ], shortTitle: "Kontynuuj słuchanie", systemImageName: "play.circle")
        AppShortcut(intent: PlayPauseIntent(), phrases: [
            "Odtwarzaj lub wstrzymaj w \(.applicationName)",
            "Pauza w \(.applicationName)",
        ], shortTitle: "Odtwarzaj/wstrzymaj", systemImageName: "playpause")
        AppShortcut(intent: PlayBookIntent(), phrases: [
            "Odtwórz książkę w \(.applicationName)",
        ], shortTitle: "Odtwórz książkę", systemImageName: "book")
        AppShortcut(intent: PlayEpisodeIntent(), phrases: [
            "Odtwórz odcinek w \(.applicationName)",
        ], shortTitle: "Odtwórz odcinek", systemImageName: "waveform")
        AppShortcut(intent: OpenBookIntent(), phrases: [
            "Otwórz książkę w \(.applicationName)",
        ], shortTitle: "Otwórz książkę", systemImageName: "book.closed")
        AppShortcut(intent: OpenPodcastIntent(), phrases: [
            "Otwórz podcast w \(.applicationName)",
        ], shortTitle: "Otwórz podcast", systemImageName: "mic")
        AppShortcut(intent: ScanLibrariesIntent(), phrases: [
            "Skanuj biblioteki w \(.applicationName)",
        ], shortTitle: "Skanuj biblioteki", systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: AddPodcastIntent(), phrases: [
            "Dodaj podcast w \(.applicationName)",
        ], shortTitle: "Dodaj podcast", systemImageName: "plus.circle")
        AppShortcut(intent: UploadBookIntent(), phrases: [
            "Wgraj książkę do \(.applicationName)",
        ], shortTitle: "Wgraj książkę", systemImageName: "square.and.arrow.up")
    }
}
