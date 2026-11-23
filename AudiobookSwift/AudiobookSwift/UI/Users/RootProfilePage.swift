import AppKit
import SwiftUI

/// Strona „Administrator serwera” (Użytkownicy › root): konto techniczne aplikacji. Nie ma telefonów,
/// roli ani usuwania; hasło: Pokaż · Kopiuj · Zmień… (decyzja z części 9 planu), a pod
/// „Zaawansowane” — „Zaloguj ponownie hasłem…” (dawne „Konta”, K3).
struct RootProfilePage: View {
    let models: AppModels
    @State private var changingPassword = false
    @State private var loggingIn = false
    @State private var confirmingReset = false

    private var account: ServerAccount { models.account }

    /// Reset ma sens tylko wtedy, gdy aplikacja nie zna działającego hasła roota.
    private var canReset: Bool {
        if case .needsPassword = account.state { return true }
        return models.rootReset.isRunning
    }

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

            if canReset {
                Section {
                    LabeledContent("Nikt nie zna hasła?") {
                        Button("Zresetuj hasło roota…") { confirmingReset = true }
                            .disabled(models.rootReset.isRunning)
                    }
                } header: {
                    Text("Reset hasła")
                } footer: {
                    Text("Ostateczność, gdy hasła nie ma ani w pęku kluczy, ani u Ciebie (np. po przeniesieniu folderu danych albo przywróceniu starej kopii). Aplikacja zatrzyma serwer, zrobi kopię bazy, nada kontu root nowe losowe hasło i zapisze je w pęku kluczy.")
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
        .confirmationDialog("Zresetować hasło konta root?", isPresented: $confirmingReset) {
            Button("Zatrzymaj serwer i zresetuj hasło", role: .destructive) {
                Task { await models.rootReset.run(supervisor: models.supervisor, account: account) }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Serwer zatrzyma się na kilka sekund (odtwarzanie i telefony na chwilę stracą połączenie). Przed zmianą powstanie kopia bazy w folderze danych: root-password-reset. Zmieni się tylko hasło konta root — inne konta, ich hasła, sesje i telefony działają dalej. Przy błędzie baza wróci do stanu sprzed resetu.")
        }
        .sheet(isPresented: Binding(get: { models.rootReset.phase != .idle }, set: { if !$0 { models.rootReset.dismiss() } })) {
            RootResetSheet(models: models)
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

/// Postęp i wynik resetu hasła roota. Arkusz należy do strony roota, ale operacja żyje
/// w `RootPasswordReset` (w `AppDelegate`), więc zatrzymanie serwera nie przerywa jej.
private struct RootResetSheet: View {
    let models: AppModels

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reset hasła konta root").font(.title2.bold())
            switch models.rootReset.phase {
            case .idle:
                EmptyView()
            case .running(let step):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step)
                }
                Text("Nie zamykaj aplikacji. Jeśli jednak się zamknie, przy następnym starcie dokończy albo cofnie reset.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .finished(let username, let password, let backup):
                Label("Gotowe — aplikacja zalogowała się nowym hasłem konta „\(username)”.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Form {
                    PasswordRow(password: password)
                    backupRow(backup)
                }
                .formStyle(.columns)
                Text("Hasło jest już w pęku kluczy tego Maca. Inne konta i telefony działają bez zmian. Kopię bazy możesz usunąć, gdy wszystko działa.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message, let backup):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let backup {
                    Form { backupRow(backup) }.formStyle(.columns)
                }
            }
            HStack {
                Spacer()
                Button("Gotowe") { models.rootReset.dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(models.rootReset.isRunning)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(models.rootReset.isRunning)
    }

    private func backupRow(_ backup: URL) -> some View {
        LabeledContent("Kopia bazy") {
            HStack {
                Text(backup.path)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
            }
        }
    }
}
