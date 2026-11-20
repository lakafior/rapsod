import SwiftUI

/// Formularz konta użytkownika: nazwa i opcjonalne hasło.
private struct UserAccountForm: View {
    let account: ServerAccount
    @State private var username = NSUserName()
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: String?

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
    }

    private func submit() {
        isWorking = true
        error = nil
        Task {
            do {
                try await account.setUpUser(username: username, password: password)
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// Wiersze sekcji „Konto użytkownika” w ustawieniach aplikacji (podstrona „Konta”).
struct UserAccountSection: View {
    let account: ServerAccount

    var body: some View {
        switch account.userState {
        case .ready(let username):
            LabeledContent("Konto do słuchania", value: "\(username) (hasło w pęku kluczy)")
            Text("To konto loguje okno biblioteki na Macu i aplikację na telefonie, więc postęp słuchania jest wspólny. Konto root służy tylko do zarządzania serwerem.")
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
