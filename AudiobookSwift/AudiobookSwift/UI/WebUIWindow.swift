import AudiobookshelfKit
import Observation
import SwiftUI

/// Na jakim koncie okno web UI ma być zalogowane. Ustawiane z menu.
@MainActor
@Observable
final class WebUIMode {
    /// `true`: konto root na czas zarządzania serwerem; `false`: zwykłe konto użytkownika.
    var isManagement = false
}

/// Okno z web UI audiobookshelf; gdy serwer nie działa, pokazuje jego stan.
///
/// Domyślnie loguje zwykłego użytkownika (to samo konto, na które loguje się telefon).
/// „Zarządzanie serwerem” przełącza na konto root w sesji trzymanej tylko w pamięci.
struct WebUIWindow: View {
    static let windowID = "web-ui"
    static let title = "Web UI audiobookshelf"
    static let managementTitle = "Zarządzanie serwerem"

    let supervisor: ServerSupervisor
    let account: ServerAccount
    let mode: WebUIMode
    let settings: SettingsNavigation

    /// Sesja przygotowana dla konkretnego trybu; `login == nil` oznacza ręczne logowanie.
    private struct WebSession {
        let isManagement: Bool
        let login: AudiobookshelfClient.Login?
    }

    /// Wszystko, od czego zależy, co okno ma pokazać.
    private struct SessionKey: Equatable {
        let account: ServerAccount.State
        let user: ServerAccount.UserState
        let isManagement: Bool
    }

    @State private var session: WebSession?
    @Environment(\.openWindow) private var openWindow

    private var needsUser: Bool {
        guard !mode.isManagement, account.state == .ready else { return false }
        switch account.userState {
        case .missing, .invalid: return true
        case .unknown, .ready: return false
        }
    }

    var body: some View {
        Group {
            switch supervisor.state {
            case .running:
                if needsUser {
                    UserAccountSetup(account: account)
                } else if let url = supervisor.webURL, let session, session.isManagement == mode.isManagement {
                    VStack(spacing: 0) {
                        if session.isManagement {
                            managementBar
                        }
                        WebUIView(url: url, login: session.login, isEphemeral: session.isManagement)
                            // Zmiana konta wymaga nowego widoku z nową sesją.
                            .id(session.login?.accessToken ?? "manual")
                    }
                } else {
                    ProgressView("Logowanie…")
                }
            case .starting:
                ProgressView("Uruchamianie serwera…")
            case .stopping:
                ProgressView("Zatrzymywanie serwera…")
            case .stopped:
                ContentUnavailableView {
                    Label("Serwer zatrzymany", systemImage: "books.vertical")
                } actions: {
                    Button("Uruchom serwer") { supervisor.start() }
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Serwer nie działa", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Uruchom ponownie") { supervisor.start() }
                    Button("Ustawienia i log…") { openWindow.openSettings(.general, navigation: settings) }
                }
            }
        }
        .frame(minWidth: 800, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        // Dwa tryby jednego okna rozróżnia tytuł (Dock, Mission Control, menu Okno).
        .navigationTitle(mode.isManagement ? Self.managementTitle : Self.title)
        .task(id: SessionKey(account: account.state, user: account.userState, isManagement: mode.isManagement)) {
            await prepareSession()
        }
        .onChange(of: supervisor.state) {
            if supervisor.state != .running { session = nil }
        }
        .onDisappear {
            // Scena `Window` po zamknięciu tylko chowa okno i trzyma jego widoki. Bez sesji
            // `WKWebView` znika z hierarchii, a z nim procesy WebKit (WebContent ok. 130 MB);
            // po ponownym otwarciu `task(id:)` loguje od nowa.
            session = nil
            // Zamknięcie okna kończy tryb zarządzania.
            mode.isManagement = false
        }
    }

    private var managementBar: some View {
        HStack {
            Label("Zarządzanie serwerem — zalogowano jako root", systemImage: "wrench.and.screwdriver")
            Spacer()
            Button("Wróć do słuchania") { mode.isManagement = false }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.18))
    }

    private func prepareSession() async {
        let isManagement = mode.isManagement
        if session?.isManagement != isManagement {
            session = nil
        }
        // Raz załadowanej strony nie przeładowujemy przy zmianach stanu konta.
        guard session == nil else { return }

        switch account.state {
        case .disconnected, .connecting:
            // Czekamy — po połączeniu `task(id:)` uruchomi się ponownie.
            return
        case .ready:
            if !isManagement {
                // Bez konta użytkownika okno pokazuje formularz jego utworzenia.
                guard case .ready = account.userState else { return }
            }
            let login = try? await account.webSession(isManagement ? .management : .listening)
            guard !Task.isCancelled else { return }
            session = WebSession(isManagement: isManagement, login: login)
        case .needsPassword, .failed:
            // Bez danych logowania web UI pokaże własny formularz logowania.
            session = WebSession(isManagement: isManagement, login: nil)
        }
    }
}
