import AudiobookshelfKit
import SwiftUI

/// Strona „Biblioteki” (etap 4 planu): lista bibliotek (wiersz → podstrona, przeciąganie zmienia kolejność), dodawanie, polskie źródła i własni dostawcy metadanych, a pod „Zaawansowane” wspólne
/// ustawienia skanera, okładek, zapisu w folderach, sortowania i pamięci podręcznej serwera.
struct LibrariesSettingsPage: View {
    let models: AppModels
    @Environment(SettingsNavigation.self) private var navigation
    @State private var showsAdvanced = false
    // Model ustawień serwera powstaje dopiero po rozwinięciu „Zaawansowane”.
    @State private var serverSettings: ServerSettingsModel?

    var body: some View {
        SettingsForm {
            Section {
                LibraryListRows(models: models)
            } header: {
                Text("Biblioteki na serwerze")
            } footer: {
                Text("Kliknij bibliotekę, aby zmienić jej ustawienia, harmonogram skanu albo ją usunąć. Kolejność (ta sama w oknie „Biblioteka”, w telefonie i w web UI) zmienisz, przeciągając wiersz na miejsce innej biblioteki, albo przyciskami „Wyżej/Niżej” na stronie biblioteki.")
            }
            Section {
                MetadataSourcesSection(sources: models.metadataSources)
            } header: {
                Text("Metadane")
            }
            CustomProvidersSection(account: models.account, refreshKey: models.metadataSources.registration.title)
            AdvancedHeader(summary: "Skaner i okładki, zapis w folderach pozycji, sortowanie, pamięć podręczna — wspólne dla wszystkich bibliotek", isExpanded: $showsAdvanced)
            if showsAdvanced {
                if models.account.state == .ready, let serverSettings {
                    LibraryServerSettingsSections(model: serverSettings, supervisor: models.supervisor)
                } else {
                    Section { AdminUnavailableRow(account: models.account) }
                }
            }
        }
        .onAppear {
            models.libraryTasks.appear()
            consumePendingAdvanced()
        }
        .onChange(of: navigation.pendingAdvanced) { consumePendingAdvanced() }
        // Biblioteki mogły przybyć albo zniknąć poza aplikacją (web UI, inny administrator).
        .task(id: models.account.state) {
            guard models.account.state == .ready else { return }
            models.libraryTasks.resume()
            guard !models.account.isScanning else { return }
            try? await models.account.refreshLibraries()
        }
        .task(id: AdvancedLoad(expanded: showsAdvanced, state: models.account.state)) {
            guard showsAdvanced, models.account.state == .ready else { return }
            let model = serverSettings ?? ServerSettingsModel(account: models.account)
            serverSettings = model
            await model.load()
        }
        .onDisappear { models.libraryTasks.disappear() }
    }

    private func consumePendingAdvanced() {
        guard navigation.pendingAdvanced == .libraries else { return }
        navigation.pendingAdvanced = nil
        showsAdvanced = true
    }

    private struct AdvancedLoad: Equatable {
        let expanded: Bool
        let state: ServerAccount.State
    }
}

/// Wiersze bibliotek w ustawieniach: stan połączenia, biblioteki ze „Skanuj” i strzałką do podstrony,
/// postęp dodawania i przyciski dodawania. Okno powitalne ma własną, prostszą listę (`LibrarySection`).
private struct LibraryListRows: View {
    let models: AppModels
    @Environment(SettingsNavigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    @State private var error: String?
    @State private var dropTarget: String?

    private var account: ServerAccount { models.account }
    private var tasks: LibraryTasks { models.libraryTasks }

    var body: some View {
        switch account.state {
        case .disconnected:
            Label("Serwer nie działa — biblioteki są niedostępne.", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        case .connecting:
            ProgressView("Łączenie z serwerem…")
                .controlSize(.small)
        case .needsPassword:
            ActionBanner(text: "Aplikacja nie zna aktualnego hasła konta root, więc nie może zarządzać bibliotekami.", actionTitle: "Podaj hasło…") {
                navigation.show(.root)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Button("Połącz ponownie") { reconnect() }
            }
        case .ready:
            ready
        }
    }

    @ViewBuilder
    private var ready: some View {
        if account.libraries.isEmpty {
            Text("Na serwerze nie ma jeszcze żadnej biblioteki.")
                .foregroundStyle(.secondary)
        }
        ForEach(account.libraries) { library in
            row(library)
                // Przeciąganie zmienia kolejność: upuszczona biblioteka zajmuje miejsce tej, na którą ją upuszczono.
                .draggable(LibraryDrag.payload(library.id)) {
                    Label(library.name, systemImage: library.mediaType == "podcast" ? "antenna.radiowaves.left.and.right" : "books.vertical")
                        .padding(6)
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let dragged = items.first.flatMap(LibraryDrag.id(from:)) else { return false }
                    return move(dragged, to: library.id)
                } isTargeted: { targeted in
                    if targeted { dropTarget = library.id } else if dropTarget == library.id { dropTarget = nil }
                }
                .overlay(alignment: .top) {
                    if dropTarget == library.id {
                        Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: -5)
                    }
                }
        }
        if let error {
            Label(error, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        if let scan = account.scan {
            ScanProgressRow(scan: scan) {
                openWindow.bringToFront(id: LibraryWindow.windowID)
            }
        }
        HStack {
            Spacer()
            Button("Dodaj audiobooki…") { add(.audiobooks) }
                .help("Nowa biblioteka audiobooków z wybranego folderu")
            Button("Dodaj podcasty…") { add(.podcasts) }
                .help("Nowa biblioteka podcastów z wybranego folderu; podcasty dodasz w oknie „Biblioteka”")
        }
        .disabled(account.isScanning)
    }

    /// Wiersz biblioteki: klik w nazwę albo strzałkę otwiera podstronę (przycisk, nie `NavigationLink`,
    /// bo formularz dorysowałby mu drugą strzałkę), obok „Skanuj”, pod spodem stan ostatniego skanu.
    private func row(_ library: AudiobookshelfClient.Library) -> some View {
        let isPodcast = library.mediaType == "podcast"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button { open(library) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isPodcast ? "antenna.radiowaves.left.and.right" : "books.vertical")
                            .frame(width: 22)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(library.name)
                            Text(subtitle(library))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(library.name), \(isPodcast ? "podcasty" : "audiobooki")")
                .accessibilityHint("Otwiera ustawienia biblioteki")
                Button("Skanuj") { tasks.scan(library, force: false) }
                    .disabled(tasks.isRunning(library.id) || account.isScanning)
                    .help("Skanuj folder biblioteki; pełny skan i dopasowanie są na stronie biblioteki")
                    .accessibilityLabel("Skanuj „\(library.name)”")
                Button { open(library) } label: {
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
            if let activity = tasks.activities[library.id] {
                LibraryActivityRow(activity: activity)
                    .padding(.leading, 32)
            }
        }
    }

    private func open(_ library: AudiobookshelfClient.Library) {
        navigation.path = [.library(id: library.id)]
    }

    private func subtitle(_ library: AudiobookshelfClient.Library) -> String {
        let kind = library.mediaType == "podcast" ? "Podcasty" : "Audiobooki"
        let folders = library.folders.map(\.fullPath).joined(separator: ", ")
        return folders.isEmpty ? kind : "\(kind) · \(folders)"
    }

    /// Przenosi bibliotekę `dragged` na miejsce `target` i zapisuje nową kolejność na serwerze.
    private func move(_ dragged: String, to target: String) -> Bool {
        var ids = account.libraries.map(\.id)
        guard dragged != target, let from = ids.firstIndex(of: dragged), let to = ids.firstIndex(of: target) else { return false }
        ids.remove(at: from)
        ids.insert(dragged, at: to)
        error = nil
        Task {
            do {
                try await account.reorderLibraries(ids)
            } catch {
                self.error = "Nie udało się zmienić kolejności bibliotek: \(error.localizedDescription)"
            }
        }
        return true
    }

    private func add(_ kind: ServerAccount.LibraryKind) {
        Task {
            guard let folder = await chooseLibraryFolder(for: kind) else { return }
            await account.addLibrary(folder: folder, kind: kind)
        }
    }

    private func reconnect() {
        guard let environment = models.supervisor.environment, models.supervisor.state == .running else { return }
        Task { await account.connect(environment: environment) }
    }
}

/// Przeciągana biblioteka jako tekst z przedrostkiem — upuszczenie zwykłego tekstu (np. z innej
/// aplikacji) nie zmienia kolejności.
enum LibraryDrag {
    static let prefix = "abswift-library:"
    static func payload(_ id: String) -> String { prefix + id }
    static func id(from text: String) -> String? {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : nil
    }
}
