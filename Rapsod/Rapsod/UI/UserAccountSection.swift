import SwiftUI

/// Formularz konta użytkownika: nazwa i opcjonalne hasło.
private struct UserAccountForm: View {
    let account: ServerAccount
    @State private var username = NSUserName()
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var confirmingAdmin = false

    var body: some View {
        TextField("Nazwa użytkownika", text: $username)
        SecureField("Hasło", text: $password, prompt: Text("puste = losowe, zapisane w pęku kluczy"))
        if let error {
            Text(error).foregroundStyle(.red)
        }
        HStack {
            Spacer()
            if isWorking {
                ProgressView().controlSize(.small)
            }
            Button("Utwórz konto") { submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || username.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .confirmationDialog("Konto „\(username)” ma rolę Administrator", isPresented: $confirmingAdmin) {
            Button("Używaj konta administratora") { submit(allowAdmin: true) }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Do słuchania zwykle wystarcza zwykłe konto. Wybierz to konto, jeśli to Twoje dotychczasowe konto (np. po przenosinach aplikacji) — zachowasz postęp słuchania.")
        }
    }

    private func submit(allowAdmin: Bool = false) {
        isWorking = true
        error = nil
        Task {
            do {
                try await account.setUpUser(username: username, password: password, allowAdmin: allowAdmin)
            } catch ServerAccount.UserSetupError.notRegularUser where !allowAdmin {
                confirmingAdmin = true
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// Konto tego Maca (konto do słuchania): stan albo formularz założenia. Używane w kaflu
/// „Utwórz konto tego Maca” na stronie „Użytkownicy” i w oknach Biblioteka i web UI (X8).
struct UserAccountSection: View {
    let account: ServerAccount

    var body: some View {
        switch account.userState {
        case .ready(let username):
            LabeledContent("Konto tego Maca", value: "\(username) (hasło w pęku kluczy)")
            Text("Na tym koncie słuchasz na Macu i na telefonach podłączonych do tego konta, więc postęp słuchania jest wspólny. Konto root służy tylko do zarządzania serwerem.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .missing:
            Text("Utwórz konto, na którym będziesz słuchać — na Macu i na telefonie. Konto root zostaje do zarządzania serwerem.")
                .foregroundStyle(.secondary)
            UserAccountForm(account: account)
        case .invalid(let message):
            Text(message).foregroundStyle(.orange)
            UserAccountForm(account: account)
        case .unknown:
            Text("Dostępne, gdy serwer działa.").foregroundStyle(.secondary)
        }
    }
}

/// Pełnoekranowa wersja formularza w oknie web UI, gdy konta jeszcze nie ma.
struct UserAccountSetup: View {
    let account: ServerAccount

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Utwórz konto użytkownika")
                .font(.title2.weight(.semibold))
            Form {
                UserAccountSection(account: account)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 460, height: 260)
        }
        .padding()
    }
}
