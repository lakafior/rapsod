import Observation
import SwiftUI

/// Modele, z których korzystają podstrony ustawień. Nowy model to nowe pole tutaj
/// i w `AppDelegate.models`.
struct AppModels {
    let supervisor: ServerSupervisor
    let account: ServerAccount
    let loginItem: LoginItem
    let sharing: SharingController
}

/// Podstrony okna „Ustawienia aplikacji” — jedyna lista. Nowa podstrona to nowy
/// przypadek z tytułem, symbolem i widokiem w `content(models:)`.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case libraries
    case accounts
    case sharing
    case log

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "Ogólne"
        case .libraries: "Biblioteki"
        case .accounts: "Konta"
        case .sharing: "Udostępnianie"
        case .log: "Log serwera"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .libraries: "books.vertical"
        case .accounts: "person.2"
        case .sharing: "iphone.and.arrow.forward"
        case .log: "doc.text.magnifyingglass"
        }
    }

    @MainActor @ViewBuilder
    func content(models: AppModels) -> some View {
        switch self {
        case .general: GeneralSettingsPage(models: models)
        case .libraries: LibrariesSettingsPage(models: models)
        case .accounts: AccountsSettingsPage(models: models)
        case .sharing: SharingSettingsPage(models: models)
        case .log: LogSettingsPage(models: models)
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
        case .sharing:
            return models.sharing.lastError != nil
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
            List(SettingsPage.allCases, selection: Binding(
                get: { navigation.page },
                set: { if let page = $0 { navigation.page = page } }
            )) { page in
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
