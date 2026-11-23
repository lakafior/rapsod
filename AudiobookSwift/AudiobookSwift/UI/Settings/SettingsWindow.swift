import Observation
import SwiftUI

/// Modele, z których korzystają podstrony ustawień. Nowy model to nowe pole tutaj
/// i w `AppDelegate.models`.
struct AppModels {
    let supervisor: ServerSupervisor
    let account: ServerAccount
    let loginItem: LoginItem
    let sharing: SharingController
    let pairing: PhonePairing
    let metadataSources: MetadataSourcesController
    let libraryTasks: LibraryTasks
    let users: UsersModel
    let avatars: AvatarStore
    let rootReset: RootPasswordReset
}

/// Strony okna „Ustawienia” — jedyna lista. Nowa strona to nowy przypadek z tytułem,
/// symbolem i widokiem w `content(models:)`. Surowa wartość jest zapisywana jako ostatnia
/// strona, więc przy usuwaniu strony trzeba dopisać ją do `init(storedValue:)`.
enum SettingsPage: String, CaseIterable, Identifiable {
    // Aplikacja
    case general
    case sharing
    case metadata
    case log
    // Serwer
    case libraries
    case users
    case serverSettings
    case activity
    case notifications
    case backups

    var id: Self { self }

    /// Strona zapisana przy poprzednim uruchomieniu; nieznana (np. usunięta w nowszej wersji) daje „Ogólne”.
    init(storedValue: String?) {
        switch storedValue {
        // Etap 2: „Konta” weszły do „Użytkowników”.
        case "accounts": self = .users
        // Etap 3: „Dostęp” wszedł do „Dostępu zdalnego”.
        case "access": self = .sharing
        default: self = storedValue.flatMap(SettingsPage.init(rawValue:)) ?? .general
        }
    }

    var title: String {
        switch self {
        case .general: "Ogólne"
        case .libraries: "Biblioteki"
        case .users: "Użytkownicy"
        case .backups: "Kopie zapasowe"
        case .sharing: "Dostęp zdalny"
        case .metadata: "Źródła metadanych"
        case .log: "Log serwera"
        case .serverSettings: "Ustawienia serwera"
        case .activity: "Aktywność"
        case .notifications: "Powiadomienia i e-mail"
        }
    }

    /// Grupa na pasku bocznym.
    var isServerPage: Bool {
        switch self {
        case .general, .sharing, .metadata, .log: false
        default: true
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .libraries: "books.vertical"
        case .users: "person.2.crop.square.stack"
        case .backups: "clock.arrow.circlepath"
        case .sharing: "globe"
        case .metadata: "text.book.closed"
        case .log: "doc.text.magnifyingglass"
        case .serverSettings: "server.rack"
        case .activity: "waveform"
        case .notifications: "bell.badge"
        }
    }

    @MainActor @ViewBuilder
    func content(models: AppModels) -> some View {
        switch self {
        case .general: GeneralSettingsPage(models: models)
        case .libraries: LibrariesSettingsPage(models: models)
        case .users: UsersPage(models: models)
        case .backups: BackupsSettingsPage(models: models)
        case .sharing: RemoteAccessPage(models: models)
        case .metadata: MetadataSettingsPage(models: models)
        case .log: LogSettingsPage(models: models)
        case .serverSettings: ServerSettingsPage(models: models)
        case .activity: ActivitySettingsPage(models: models)
        case .notifications: NotificationsSettingsPage(models: models)
        }
    }

    /// Czy podstrona wymaga uwagi (znak na pasku bocznym).
    @MainActor
    func needsAttention(models: AppModels) -> Bool {
        switch self {
        case .general:
            if case .failed = models.supervisor.state { return true }
            return models.loginItem.requiresApproval || models.loginItem.lastError != nil
        case .libraries:
            if case .failed = models.account.state { return true }
            return false
        case .users:
            // Brak hasła roota albo brak konta tego Maca (dawny znak przy „Kontach”).
            if case .needsPassword = models.account.state { return true }
            guard models.account.state == .ready else { return false }
            switch models.account.userState {
            case .missing, .invalid: return true
            case .unknown, .ready: return false
            }
        case .backups, .serverSettings, .activity, .notifications:
            return false
        case .sharing:
            if case .failed = models.sharing.tunnel.state, models.sharing.externalAccess == .cloudflareTunnel { return true }
            return models.sharing.lastError != nil
                || (!models.pairing.devices.isEmpty && models.sharing.phonesMayLackRemoteAddress)
        case .metadata:
            let sources = models.metadataSources
            guard sources.isEnabled else { return false }
            if case .failed = sources.state { return true }
            if case .unavailable = sources.state { return true }
            if case .failed = sources.registration { return true }
            return false
        case .log:
            return false
        }
    }
}

/// Miejsce w oknie ustawień: strona z paska bocznego albo podstrona obiektu.
/// Podstrona to element ścieżki `NavigationStack` w szczegółach (`SettingsNavigation.path`).
enum SettingsDestination: Hashable, Codable {
    /// Profil osoby (Użytkownicy › osoba).
    case user(id: String)
    /// Konto root (Użytkownicy › Administrator serwera).
    case root
    /// Dziennik serwera. Do etapu 5 planu to osobna strona („Log serwera”), nie podstrona.
    case serverLog
    /// Biblioteka. Do etapu 4 planu ustawienia biblioteki są arkuszem na stronie „Biblioteki”.
    case library(id: String)

    /// Strona na pasku bocznym, pod którą leży to miejsce.
    var page: SettingsPage {
        switch self {
        case .user, .root: .users
        case .serverLog: .log
        case .library: .libraries
        }
    }

    /// Czy to podstrona (element ścieżki), czy na razie sama strona z paska bocznego.
    var isSubpage: Bool {
        switch self {
        case .user, .root: true
        case .serverLog, .library: false
        }
    }

    @MainActor @ViewBuilder
    func content(models: AppModels) -> some View {
        switch self {
        case .user(let id): UserProfilePage(models: models, userID: id)
        case .root: RootProfilePage(models: models)
        // Jeszcze nie podstrony (`isSubpage`): `show(_:)` otwiera ich stronę.
        case .serverLog, .library: EmptyView()
        }
    }
}

/// Wybrana strona i ścieżka podstron. Żyje w `AppDelegate`, więc przetrwa zamknięcie okna, a menu
/// i inne okna mogą otworzyć ustawienia od razu we właściwym miejscu. Strona przetrwa też ponowne
/// uruchomienie aplikacji (UserDefaults; ścieżka podstron nie, bo obiekt mógł w tym czasie zniknąć).
@MainActor
@Observable
final class SettingsNavigation {
    static let lastPageKey = "settings.lastPage"

    var page: SettingsPage {
        didSet {
            guard page != oldValue else { return }
            path = []
            UserDefaults.standard.set(page.rawValue, forKey: Self.lastPageKey)
        }
    }
    var path: [SettingsDestination] = []

    /// Akcja z menu kontekstowego kafla osoby, którą profil wykona po otwarciu.
    enum ProfileAction: Equatable {
        case pairPhone
        case changePassword
    }
    var pendingProfileAction: ProfileAction?
    /// Strona „Dostęp zdalny” ma się otworzyć z rozwiniętym „Zaawansowane” (np. z profilu osoby).
    var pendingRemoteAdvanced = false

    init() {
        page = SettingsPage(storedValue: UserDefaults.standard.string(forKey: Self.lastPageKey))
    }

    /// Przechodzi do miejsca: strona z paska bocznego, a dla podstron także ścieżka.
    func show(_ destination: SettingsDestination) {
        guard destination.isSubpage else {
            page = destination.page
            path = []
            return
        }
        if page == destination.page {
            path = [destination]
            return
        }
        // Nowa strona to nowy `NavigationStack` (`.id(page)`); stary przy znikaniu zeruje ścieżkę,
        // więc podstronę dokładamy dopiero w następnym obiegu, gdy nowy stos już jest.
        page = destination.page
        Task { @MainActor in
            await Task.yield()
            if self.page == destination.page { self.path = [destination] }
        }
    }
}

extension OpenWindowAction {
    /// Otwiera okno ustawień, opcjonalnie na konkretnej stronie.
    @MainActor
    func openSettings(_ page: SettingsPage? = nil, navigation: SettingsNavigation) {
        if let page {
            navigation.page = page
            navigation.path = []
        }
        bringToFront(id: SettingsWindow.windowID)
    }

    /// Otwiera okno ustawień w konkretnym miejscu (strona albo podstrona obiektu).
    @MainActor
    func openSettings(_ destination: SettingsDestination, navigation: SettingsNavigation) {
        navigation.show(destination)
        bringToFront(id: SettingsWindow.windowID)
    }
}

/// Okno „Ustawienia”: pasek boczny ze stronami jak w Ustawieniach systemowych, a w szczegółach
/// stos podstron (osoba, biblioteka) ze strzałką wstecz na pasku narzędzi.
struct SettingsWindow: View {
    static let windowID = "settings"
    static let title = "Ustawienia"

    let models: AppModels
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<SettingsPage?>(
                get: { navigation.page },
                set: { if let page = $0 { navigation.page = page } }
            )) {
                Section("Aplikacja") {
                    ForEach(SettingsPage.allCases.filter { !$0.isServerPage }) { row($0) }
                }
                Section("Serwer audiobookshelf") {
                    ForEach(SettingsPage.allCases.filter(\.isServerPage)) { row($0) }
                }
            }
            // Sama szerokość kolumny nie wystarcza: podział pamięta poprzednią szerokość.
            .frame(minWidth: 215)
            .navigationSplitViewColumnWidth(min: 215, ideal: 215, max: 280)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            NavigationStack(path: $navigation.path) {
                navigation.page.content(models: models)
                    // Tytuł okna zostaje stały, żeby dało się je rozpoznać w Docku i menu Okno.
                    .navigationTitle(SettingsWindow.title)
                    .navigationSubtitle(navigation.page.title)
                    .navigationDestination(for: SettingsDestination.self) { destination in
                        destination.content(models: models)
                            .navigationTitle(SettingsWindow.title)
                    }
            }
            // Nowa strona to nowy stos: bez tego SwiftUI zostawia stan poprzedniej strony.
            .id(navigation.page)
        }
        .frame(minWidth: 760, minHeight: 520)
        .environment(navigation)
        .onAppear { models.loginItem.refresh() }
        .task { await SettingsTour.runIfRequested(models: models, navigation: navigation) }
    }

    private func row(_ page: SettingsPage) -> some View {
        Label {
            HStack {
                Text(page.title)
                if page.needsAttention(models: models) {
                    Spacer()
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Wymaga uwagi")
                }
            }
        } icon: {
            Image(systemName: page.symbolName)
        }
        .tag(page)
    }
}

/// Wspólny układ podstrony z formularzem.
struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
    }
}
