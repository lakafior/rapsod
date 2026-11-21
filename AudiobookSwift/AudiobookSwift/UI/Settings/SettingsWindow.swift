import Observation
import SwiftUI

/// Modele, z których korzystają podstrony ustawień. Nowy model to nowe pole tutaj
/// i w `AppDelegate.models`.
struct AppModels {
    let supervisor: ServerSupervisor
    let account: ServerAccount
    let loginItem: LoginItem
    let sharing: SharingController
    let metadataSources: MetadataSourcesController
    let libraryTasks: LibraryTasks
}

/// Podstrony okna „Ustawienia aplikacji” — jedyna lista. Nowa podstrona to nowy
/// przypadek z tytułem, symbolem i widokiem w `content(models:)`.
enum SettingsPage: String, CaseIterable, Identifiable {
    // Aplikacja
    case general
    case sharing
    case metadata
    case log
    // Serwer
    case libraries
    case accounts
    case users
    case serverSettings
    case access
    case activity
    case notifications
    case backups

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "Ogólne"
        case .libraries: "Biblioteki"
        case .accounts: "Konta"
        case .users: "Użytkownicy"
        case .backups: "Kopie zapasowe"
        case .sharing: "Udostępnianie"
        case .metadata: "Źródła metadanych"
        case .log: "Log serwera"
        case .serverSettings: "Ustawienia serwera"
        case .access: "Dostęp"
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
        case .accounts: "person.2"
        case .users: "person.3"
        case .backups: "clock.arrow.circlepath"
        case .sharing: "iphone.and.arrow.forward"
        case .metadata: "text.book.closed"
        case .log: "doc.text.magnifyingglass"
        case .serverSettings: "server.rack"
        case .access: "key"
        case .activity: "waveform"
        case .notifications: "bell.badge"
        }
    }

    @MainActor @ViewBuilder
    func content(models: AppModels) -> some View {
        switch self {
        case .general: GeneralSettingsPage(models: models)
        case .libraries: LibrariesSettingsPage(models: models)
        case .accounts: AccountsSettingsPage(models: models)
        case .users: UsersSettingsPage(models: models)
        case .backups: BackupsSettingsPage(models: models)
        case .sharing: SharingSettingsPage(models: models)
        case .metadata: MetadataSettingsPage(models: models)
        case .log: LogSettingsPage(models: models)
        case .serverSettings: ServerSettingsPage(models: models)
        case .access: AccessSettingsPage(models: models)
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
        case .accounts:
            if case .needsPassword = models.account.state { return true }
            guard models.account.state == .ready else { return false }
            switch models.account.userState {
            case .missing, .invalid: return true
            case .unknown, .ready: return false
            }
        case .users, .backups, .serverSettings, .access, .activity, .notifications:
            return false
        case .sharing:
            return models.sharing.lastError != nil
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

/// Wybrana podstrona. Żyje w `AppDelegate`, więc przetrwa zamknięcie okna, a menu
/// i inne okna mogą otworzyć ustawienia od razu na właściwej podstronie.
@MainActor
@Observable
final class SettingsNavigation {
    var page: SettingsPage = .general
}

extension OpenWindowAction {
    /// Otwiera „Ustawienia aplikacji”, opcjonalnie na konkretnej podstronie.
    @MainActor
    func openSettings(_ page: SettingsPage? = nil, navigation: SettingsNavigation) {
        if let page { navigation.page = page }
        bringToFront(id: SettingsWindow.windowID)
    }
}

/// Okno „Ustawienia aplikacji”: pasek boczny z podstronami jak w Ustawieniach systemowych.
struct SettingsWindow: View {
    static let windowID = "settings"
    static let title = "Ustawienia aplikacji"

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
            navigation.page.content(models: models)
                // Tytuł okna zostaje stały, żeby dało się je rozpoznać w Docku i menu Okno.
                .navigationTitle(SettingsWindow.title)
                .navigationSubtitle(navigation.page.title)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { models.loginItem.refresh() }
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
