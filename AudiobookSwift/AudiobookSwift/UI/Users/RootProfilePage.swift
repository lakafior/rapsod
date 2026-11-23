import SwiftUI

/// Strona „Administrator serwera” (Użytkownicy › root): konto techniczne aplikacji. Nie ma telefonów,
/// roli ani usuwania; hasło: Pokaż · Kopiuj · Zmień… (decyzja z części 9 planu), a pod
/// „Zaawansowane” — „Zaloguj ponownie hasłem…” (dawne „Konta”, K3).
struct RootProfilePage: View {
    let models: AppModels
    @State private var changingPassword = false
    @State private var loggingIn = false

    private var account: ServerAccount { models.account }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    ZStack {
                        Circle().fill(.quaternary).frame(width: 72, height: 72)
                        Image(systemName: "lock.fill").font(.system(size: 28)).foregroundStyle(.secondary)
                    }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Administrator serwera").font(.title.weight(.semibold))
                        Chip(text: "\(account.username ?? ServerEnvironment.rootUsername) · konto techniczne", systemImage: "key", tint: .secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Tym kontem aplikacja zarządza serwerem (użytkownicy, biblioteki, kopie). Nie służy do słuchania i nigdy nie trafia do telefonu. Nie da się go usunąć ani zmienić jego roli.")
            }

            Section("Hasło") {
                switch account.state {
                case .ready:
                    PasswordRow(password: account.rootPassword) { changingPassword = true }
                    LabeledContent("Stan") {
                        Label("Aplikacja jest zalogowana", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                case .needsPassword(let reason):
                    RootPasswordForm(account: account, reason: reason)
                case .connecting:
                    ProgressView("Łączenie z serwerem…").controlSize(.small)
                case .disconnected:
                    Text("Dostępne, gdy serwer działa.").foregroundStyle(.secondary)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            AdvancedSection(summary: "Nazwa konta i ponowne logowanie hasłem") {
                LabeledContent("Nazwa konta", value: account.username ?? ServerEnvironment.rootUsername)
                LabeledContent("Hasło w pęku kluczy nie pasuje?") {
                    Button("Zaloguj ponownie hasłem…") { loggingIn = true }
                        .disabled(account.state == .disconnected || account.state == .connecting)
                }
            } footer: {
                Text("„Zaloguj ponownie” jest potrzebne tylko wtedy, gdy hasło w pęku kluczy przestało pasować (np. po przywróceniu starej kopii). Web UI do zarządzania serwerem zostaje pod klawiszem Option przy „Ustawieniach…” w menu.")
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle("Użytkownicy › Administrator serwera")
        .sheet(isPresented: $changingPassword) {
            ChangePasswordSheet(
                models: models,
                username: account.username ?? ServerEnvironment.rootUsername,
                remembered: true,
                note: "Najpierw zmienia się hasło na serwerze, potem w pęku kluczy tego Maca. Aplikacja zaloguje się od razu nowym hasłem; web UI zarządzania trzeba będzie otworzyć ponownie."
            ) { newPassword in
                try await account.changeRootPassword(to: newPassword)
            }
        }
        .sheet(isPresented: $loggingIn) {
            VStack(alignment: .leading, spacing: 16) {
                RootPasswordForm(account: account, reason: "Podaj aktualne hasło konta root. Aplikacja zapisze je w pęku kluczy tego Maca.")
                HStack {
                    Spacer()
                    Button("Zamknij") { loggingIn = false }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(24)
            .frame(width: 440)
        }
    }
}
