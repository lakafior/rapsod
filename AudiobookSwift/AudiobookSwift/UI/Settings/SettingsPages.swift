import AudiobookshelfKit
import SwiftUI

/// Strona „Biblioteki” (etap 4 planu): lista bibliotek (wiersz → podstrona), dodawanie, polskie źródła i własni dostawcy metadanych, a pod „Zaawansowane” wspólne
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
                Text("Kliknij bibliotekę, aby zmienić jej ustawienia, harmonogram skanu albo ją usunąć. Kolejność bibliotek (ta sama w oknie „Biblioteka”, w telefonie i w web UI) zmienisz na stronie biblioteki w „Zaawansowane”.")
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
            if navigation.pendingAdvanced == .libraries {
                navigation.pendingAdvanced = nil
                showsAdvanced = true
            }
        }
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
