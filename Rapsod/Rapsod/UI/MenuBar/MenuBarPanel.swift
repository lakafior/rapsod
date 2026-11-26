import AppKit
import AudiobookshelfKit
import AudiobookshelfPlayback
import SwiftUI

/// Panel ikony na pasku menu (etap 14d, styl `.window` zamiast `.menu`).
///
/// Styl `.menu` umie tylko pozycje tekstowe: bez okładki, suwaka czasu i pasków postępu, których
/// wymaga „Teraz odtwarzane” i stan zadań. Panel jest więc oknem jak moduły Centrum sterowania,
/// a pozycje rzadkie (serwer, logowanie, web UI, O programie, aktualizacje, Zakończ) są w jednym
/// prawdziwym menu „Więcej” na dole — tam działa też Option (web UI) jak dawniej.
///
/// Treść żyje tylko przy otwartym panelu, więc czytanie czasu odtwarzania (suwak) nie kosztuje
/// nic, gdy panel jest zamknięty.
struct MenuBarPanel: View {
    let supervisor: ServerSupervisor
    let account: ServerAccount
    let loginItem: LoginItem
    let webMode: WebUIMode
    let settings: SettingsNavigation
    let listening: ListeningController
    let updates: UpdateController
    let libraryTasks: LibraryTasks
    let menuBar: MenuBarModel
    @Environment(\.openWindow) private var openWindow
    @State private var panelWindow = WeakWindow()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ServerStatusHeader(supervisor: supervisor)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if listening.player.book != nil {
                PanelDivider()
                NowPlayingSection(listening: listening, openLibrary: { open(LibraryWindow.windowID) })
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            ActivitySection(listening: listening, account: account, updates: updates, libraryTasks: libraryTasks, menuBar: menuBar,
                            showUpload: { request(.showUpload) }, showUpdate: showUpdate)

            ResumeSection(listening: listening, menuBar: menuBar, close: close)

            PanelDivider()
            QuickActions(listening: listening, account: account, libraryTasks: libraryTasks,
                         openLibrary: { open(LibraryWindow.windowID) },
                         upload: { request(.upload([])) },
                         addPodcast: { request(.addPodcast) },
                         openSettings: {
                             close()
                             openWindow.openSettings(navigation: settings)
                         })
                .padding(.horizontal, 6)
                .padding(.vertical, 6)

            PanelDivider()
            MoreMenu(supervisor: supervisor, account: account, loginItem: loginItem, webMode: webMode, settings: settings, updates: updates, close: close)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
        }
        .frame(width: 330)
        .background(WindowReader(window: panelWindow))
        .onAppear {
            menuBar.panelOpened()
            libraryTasks.appear()
        }
        .onDisappear { libraryTasks.disappear() }
    }

    private func close() {
        panelWindow.window?.close()
    }

    private func open(_ id: String) {
        close()
        openWindow.bringToFront(id: id)
    }

    private func request(_ request: MenuBarModel.LibraryRequest) {
        menuBar.libraryRequest = request
        open(LibraryWindow.windowID)
    }

    private func showUpdate() {
        if let pending = updates.pending, !updates.isBusy { updates.showAvailable(pending) }
        open(UpdateWindow.windowID)
    }
}

// MARK: - Nagłówek: stan serwera

private struct ServerStatusHeader: View {
    let supervisor: ServerSupervisor

    var body: some View {
        HStack(spacing: 8) {
            Text("Rapsod").font(.headline)
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(supervisor.state.color).frame(width: 7, height: 7)
                Text(supervisor.state.shortStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(supervisor.state.title)
        }
        if case .failed(let message) = supervisor.state {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.top, 4)
        }
    }
}

// MARK: - Teraz odtwarzane

private struct NowPlayingSection: View {
    let listening: ListeningController
    let openLibrary: () -> Void
    @State private var cover: NSImage?

    var body: some View {
        let player = listening.player
        if let book = player.book {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button(action: openLibrary) {
                        CoverView(image: cover, symbol: "headphones")
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Otwórz bibliotekę")
                    .accessibilityLabel("Otwórz bibliotekę")
                    .task(id: "\(book.itemID)#\(listening.coverRevision[book.itemID] ?? 0)") {
                        cover = await listening.cover(for: book.itemID, path: book.coverPath, size: 60)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title).font(.callout.weight(.semibold)).lineLimit(2)
                        if let line = player.currentChapter?.title ?? book.author {
                            Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                PanelScrubber(player: player)
                HStack(spacing: 0) {
                    SpeedMenu(player: player)
                        .controlSize(.small)
                    Spacer()
                    PanelTransport(player: player)
                    Spacer()
                    SleepMenu(player: player)
                        .controlSize(.small)
                        .labelStyle(.iconOnly)
                }
            }
        }
    }
}

/// Poprzedni rozdział, −15 s, odtwarzaj/pauza, +30 s, następny rozdział — w rozmiarze panelu.
private struct PanelTransport: View {
    let player: AudiobookPlayer

    var body: some View {
        HStack(spacing: 14) {
            Button { player.previousChapter() } label: { Image(systemName: "backward.end.fill") }
                .help("Poprzedni rozdział").accessibilityLabel("Poprzedni rozdział")
            Button { player.skip(by: -AudiobookPlayer.skipBack) } label: { Image(systemName: "gobackward.15") }
                .help("Przewiń do tyłu 15 s").accessibilityLabel("Przewiń do tyłu 15 sekund")
            Button { player.togglePlayPause() } label: {
                ZStack {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 26)
                        .opacity(player.isLoading ? 0.3 : 1)
                    if player.isLoading { ProgressView().controlSize(.small) }
                }
            }
            .accessibilityLabel(player.isPlaying ? "Pauza" : "Odtwarzaj")
            Button { player.skip(by: AudiobookPlayer.skipForward) } label: { Image(systemName: "goforward.30") }
                .help("Przewiń do przodu 30 s").accessibilityLabel("Przewiń do przodu 30 sekund")
            Button { player.nextChapter() } label: { Image(systemName: "forward.end.fill") }
                .help("Następny rozdział").accessibilityLabel("Następny rozdział")
        }
        .font(.body)
        .buttonStyle(.plain)
    }
}

/// Suwak w obrębie rozdziału, z czasem od początku i do końca rozdziału.
private struct PanelScrubber: View {
    let player: AudiobookPlayer
    @State private var scrubbing: Double?
    @State private var isDragging = false

    var body: some View {
        let chapter = player.currentChapter
        let start = chapter?.start ?? 0
        let end = max(chapter?.end ?? player.duration, start + 1)
        let shown = scrubbing ?? player.currentTime
        VStack(spacing: 1) {
            Slider(
                value: Binding(get: { min(max(shown, start), end) }, set: { value in
                    if isDragging { scrubbing = value } else { player.seek(to: value) }
                }),
                in: start...end
            ) { editing in
                isDragging = editing
                if !editing, let scrubbing { player.seek(to: scrubbing) }
                if !editing { scrubbing = nil }
            }
            .controlSize(.mini)
            .accessibilityLabel(chapter == nil ? "Postęp" : "Postęp rozdziału")
            .accessibilityValue("\(PlaybackFormat.clock(shown - start)) z \(PlaybackFormat.clock(end - start))")
            HStack {
                Text(PlaybackFormat.clock(shown - start, rounding: .toNearestOrEven))
                Spacer()
                Text("-" + PlaybackFormat.clock(end - shown, rounding: .toNearestOrEven))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Stan: skan, pobieranie, wgrywanie, aktualizacja

private struct ActivitySection: View {
    let listening: ListeningController
    let account: ServerAccount
    let updates: UpdateController
    let libraryTasks: LibraryTasks
    let menuBar: MenuBarModel
    let showUpload: () -> Void
    let showUpdate: () -> Void

    private var scans: [(name: String, activity: LibraryTasks.Activity)] {
        account.libraries.compactMap { library in
            guard let activity = libraryTasks.activities[library.id], activity.isRunning else { return nil }
            return (library.name, activity)
        }
    }

    private var hasContent: Bool {
        !scans.isEmpty || listening.episodeDownloads.current != nil || !listening.episodeDownloads.queue.isEmpty
            || menuBar.browser?.upload?.isRunning == true || updates.pending != nil || updates.isBusy
    }

    var body: some View {
        if hasContent {
            PanelDivider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(scans, id: \.name) { scan in
                    ActivityRow(symbol: "arrow.triangle.2.circlepath",
                                title: scan.activity.kind == .matchAll ? "Dopasowywanie: \(scan.name)" : "Skanowanie: \(scan.name)",
                                progress: nil)
                }
                let downloads = listening.episodeDownloads
                if let current = downloads.current {
                    ActivityRow(symbol: "arrow.down.circle",
                                title: "Pobieranie: \(current.episodeDisplayTitle ?? current.podcastTitle ?? "odcinek")",
                                detail: downloads.queue.isEmpty ? nil : "W kolejce: \(downloads.queue.count)",
                                progress: nil)
                } else if !downloads.queue.isEmpty {
                    ActivityRow(symbol: "arrow.down.circle", title: "Odcinki w kolejce: \(downloads.queue.count)", progress: nil)
                }
                if let upload = menuBar.browser?.upload, upload.isRunning {
                    Button(action: showUpload) {
                        ActivityRow(symbol: "square.and.arrow.up", title: "Wgrywanie do biblioteki", progress: upload.overallProgress)
                    }
                    .buttonStyle(.plain)
                    .help("Pokaż wgrywanie")
                }
                UpdateActivity(updates: updates, show: showUpdate)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

private struct UpdateActivity: View {
    let updates: UpdateController
    let show: () -> Void

    var body: some View {
        switch updates.phase {
        case .checking:
            ActivityRow(symbol: "arrow.down.app", title: "Sprawdzanie aktualizacji…", progress: nil)
        case .downloading(let update, let fraction):
            ActivityRow(symbol: "arrow.down.app", title: "Pobieranie Rapsodu \(update.version.string)", progress: fraction ?? nil)
        case .verifying(let update), .installing(let update):
            ActivityRow(symbol: "arrow.down.app", title: "Instalowanie Rapsodu \(update.version.string)…", progress: nil)
        default:
            if let pending = updates.pending {
                Button(action: show) {
                    ActivityRow(symbol: "arrow.down.app.fill", title: "Dostępny Rapsod \(pending.version.string)", detail: "Pokaż szczegóły…", progress: nil, showsSpinner: false)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ActivityRow: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    /// `nil` — postęp nieznany (kółko), liczba — pasek.
    let progress: Double?
    var showsSpinner = true

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout).lineLimit(1)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                if let progress {
                    ProgressView(value: progress).controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            if progress == nil, showsSpinner {
                ProgressView().controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Słuchaj dalej

private struct ResumeSection: View {
    let listening: ListeningController
    let menuBar: MenuBarModel
    let close: () -> Void

    /// Bez pozycji, która już jest w „Teraz odtwarzane”.
    private var entries: [MenuBarModel.ResumeEntry] {
        let current = listening.player.book.map { ListeningController.key($0.itemID, $0.episodeID) }
        return menuBar.recent.filter { $0.id != current }
    }

    var body: some View {
        if listening.availability == .ready, !entries.isEmpty {
            PanelDivider()
            VStack(alignment: .leading, spacing: 2) {
                Text("Słuchaj dalej")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(entries) { entry in
                    Button {
                        menuBar.resume(entry)
                    } label: {
                        ResumeRow(listening: listening, entry: entry, isStarting: listening.startingKey == entry.id)
                    }
                    .buttonStyle(PanelRowStyle())
                    .accessibilityHint("Wznawia słuchanie")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
    }
}

private struct ResumeRow: View {
    let listening: ListeningController
    let entry: MenuBarModel.ResumeEntry
    let isStarting: Bool
    @State private var cover: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            CoverView(image: cover, symbol: entry.episodeID == nil ? "book.closed" : "mic")
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .task(id: entry.itemID) {
                    cover = await listening.cover(for: entry.itemID, path: entry.coverPath, size: 36)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.callout).lineLimit(1)
                if let subtitle = entry.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if isStarting {
                ProgressView().controlSize(.small)
            } else if let progress = entry.progress {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "play.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Szybkie akcje

private struct QuickActions: View {
    let listening: ListeningController
    let account: ServerAccount
    let libraryTasks: LibraryTasks
    let openLibrary: () -> Void
    let upload: () -> Void
    let addPodcast: () -> Void
    let openSettings: () -> Void

    private var isReady: Bool { account.state == .ready }
    private var hasPodcastLibrary: Bool { account.libraries.contains { $0.mediaType == "podcast" } }
    private var scanning: Bool { libraryTasks.anyRunning }

    var body: some View {
        VStack(spacing: 0) {
            PanelRow("Otwórz bibliotekę", symbol: "books.vertical", action: openLibrary)
            PanelRow("Wgraj książkę…", symbol: "square.and.arrow.up", action: upload)
                .disabled(!isReady || account.libraries.isEmpty)
            if hasPodcastLibrary {
                PanelRow("Dodaj podcast…", symbol: "plus", action: addPodcast)
                    .disabled(!isReady)
            }
            PanelRow(scanning ? "Skanowanie trwa…" : "Skanuj biblioteki", symbol: "arrow.triangle.2.circlepath") {
                for library in account.libraries { libraryTasks.scan(library, force: false) }
            }
            .disabled(!isReady || account.libraries.isEmpty || scanning)
            PanelRow("\(SettingsWindow.title)…", symbol: "gearshape", action: openSettings)
        }
    }
}

// MARK: - Więcej: serwer, logowanie, web UI, O programie, aktualizacje, Zakończ

private struct MoreMenu: View {
    let supervisor: ServerSupervisor
    let account: ServerAccount
    let loginItem: LoginItem
    let webMode: WebUIMode
    let settings: SettingsNavigation
    let updates: UpdateController
    let close: () -> Void
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MenuOptions.showsPairPhoneKey) private var showsPairPhone = false

    var body: some View {
        HStack {
            Menu {
                Button("Uruchom serwer") { supervisor.start() }
                    .disabled(!supervisor.state.canStart)
                Button("Zatrzymaj serwer") { Task { await supervisor.stop() } }
                    .disabled(!supervisor.state.canStop)
                Button("Uruchom ponownie serwer") { Task { await supervisor.restart() } }
                    .disabled(!supervisor.state.canStop)
                Divider()
                Toggle("Uruchamiaj przy logowaniu", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                if loginItem.requiresApproval {
                    Button("Wymaga zgody — otwórz Ustawienia systemowe…") { loginItem.openSystemSettings() }
                }
                // Opcja z Ogólne › Aplikacja (decyzja z części 9 planu): domyślnie wyłączona.
                if showsPairPhone {
                    Button("Podłącz telefon…") {
                        close()
                        settings.pendingMacPairing = true
                        openWindow.openSettings(.users, navigation: settings)
                    }
                    .disabled(account.state != .ready)
                }
                Divider()
                // Web UI zostaje jako wyjście awaryjne (etap 9i).
                Button("\(WebUIWindow.title)…") {
                    close()
                    webMode.isManagement = false
                    openWindow.bringToFront(id: WebUIWindow.windowID)
                }
                .disabled(account.state != .ready)
                Button("Zarządzanie serwerem (web UI)…") {
                    close()
                    webMode.isManagement = true
                    openWindow.bringToFront(id: WebUIWindow.windowID)
                }
                .disabled(account.state != .ready)
                Divider()
                Button("O programie Rapsod") {
                    close()
                    openWindow.bringToFront(id: AboutWindow.windowID)
                }
                UpdateMenuItem(updates: updates)
            } label: {
                Label("Więcej", systemImage: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Serwer, uruchamianie przy logowaniu, web UI, aktualizacje")

            Spacer()

            // Zakończenie razem z serwerem, tak jak ⌘Q w menu aplikacji.
            Button("Zakończ Rapsod") { AppQuit.quit() }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }
}

// MARK: - Elementy panelu

/// Wiersz jak pozycja menu: ikona, tekst, podświetlenie pod kursorem.
private struct PanelRow: View {
    let title: String
    let symbol: String
    let action: () -> Void

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                Spacer()
            }
        }
        .buttonStyle(PanelRowStyle())
    }
}

/// Podświetlenie wiersza pod kursorem, jak w modułach Centrum sterowania.
private struct PanelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PanelRowBody(configuration: configuration)
    }

    private struct PanelRowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.primary.opacity(configuration.isPressed ? 0.16 : (hovered && isEnabled ? 0.08 : 0)))
                }
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovered = $0 }
        }
    }
}

private struct PanelDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 14)
    }
}

/// Okno panelu — do zamknięcia go po wybraniu akcji (`dismiss` nie działa w `MenuBarExtra`).
@MainActor
final class WeakWindow {
    weak var window: NSWindow?
}

private struct WindowReader: NSViewRepresentable {
    let window: WeakWindow

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.box = window
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var box: WeakWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            box?.window = window
            #if DEBUG
            // Sprawdzanie na kopii testowej: numer okna do `screencapture -l` (zrzuty w docs/).
            NSLog("MENUBAR panel window %ld", window.windowNumber)
            #endif
        }
    }
}

// MARK: - Stan serwera

extension ServerState {
    var title: String {
        switch self {
        case .stopped: "Serwer zatrzymany"
        case .starting: "Uruchamianie serwera…"
        case .running: "Serwer działa"
        case .stopping: "Zatrzymywanie serwera…"
        case .failed: "Błąd serwera — szczegóły w ustawieniach"
        }
    }

    /// Krótki opis obok kropki w nagłówku panelu.
    var shortStatus: String {
        switch self {
        case .stopped: "Serwer zatrzymany"
        case .starting: "Uruchamianie…"
        case .running: "Serwer działa"
        case .stopping: "Zatrzymywanie…"
        case .failed: "Błąd serwera"
        }
    }

    var color: Color {
        switch self {
        case .running: .green
        case .starting, .stopping: .yellow
        case .stopped: .secondary
        case .failed: .red
        }
    }

    var symbolName: String {
        switch self {
        case .running: "books.vertical.fill"
        case .failed: "exclamationmark.triangle"
        case .stopped, .starting, .stopping: "books.vertical"
        }
    }

    var canStart: Bool {
        switch self {
        case .stopped, .failed: true
        case .starting, .running, .stopping: false
        }
    }

    var canStop: Bool {
        switch self {
        case .starting, .running: true
        case .stopped, .stopping, .failed: false
        }
    }
}

/// Opcje menu na pasku menu ustawiane w Ogólne › Aplikacja.
enum MenuOptions {
    static let showsPairPhoneKey = "menu.showsPairPhone"
}
