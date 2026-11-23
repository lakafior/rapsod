import AudiobookshelfKit
import SwiftUI

/// Strona „Użytkownicy” (etap 2 planu): siatka okrągłych profili domowników, kafel
/// „Dodaj osobę” i pod siatką osobny, szary kafel konta root. Zastępuje dawne strony „Konta”
/// i „Użytkownicy” oraz sekcję telefonu z „Udostępniania”.
///
/// Siatka nie znika, gdy serwer na chwilę się rozłącza (np. restart po włączeniu sieci domowej):
/// pokazuje ostatnio wczytaną listę z informacją o stanie, żeby otwarte profile i arkusze zostały.
struct UsersPage: View {
    let models: AppModels
    @Environment(SettingsNavigation.self) private var navigation
    @State private var addingPerson = false
    @State private var creatingMacAccount = false

    private var model: UsersModel { models.users }
    private var account: ServerAccount { models.account }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Kto słucha?")
                    .font(.largeTitle.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                    .accessibilityAddTraits(.isHeader)

                status
                    .padding(.horizontal, 28)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 150), spacing: 24)], spacing: 26) {
                    if needsMacAccount {
                        CreateMacAccountTile { creatingMacAccount = true }
                    }
                    ForEach(model.people) { user in
                        PersonTile(models: models, user: user)
                    }
                    AddPersonTile { addingPerson = true }
                        .disabled(account.state != .ready)
                }
                .padding(.horizontal, 28)

                ObjectRow(
                    destination: .root,
                    title: "Administrator serwera (root)",
                    subtitle: needsRootPassword ? "Aplikacja nie zna aktualnego hasła — kliknij, aby je podać." : "Konto techniczne aplikacji. Nie trafia do telefonów, nie da się go usunąć.",
                    needsAttention: needsRootPassword
                ) {
                    ZStack {
                        Circle().fill(.quaternary).frame(width: 38, height: 38)
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 28)

                ObjectRow(
                    destination: .history(userID: nil),
                    title: "Historia słuchania wszystkich",
                    subtitle: "Kto słucha teraz i zapisane sesje ze wszystkich urządzeń"
                ) {
                    ZStack {
                        Circle().fill(.quaternary).frame(width: 38, height: 38)
                        Image(systemName: "waveform").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 28)

                Text("Każda osoba w domu może mieć własne konto z osobnym postępem słuchania i własnymi telefonami. Konto root zarządza serwerem z tej aplikacji; jego hasło jest w pęku kluczy tego Maca.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $addingPerson) {
            NewPersonSheet(model: model)
        }
        .sheet(isPresented: $creatingMacAccount) {
            CreateMacAccountSheet(account: account)
        }
        .task(id: account.state) {
            guard account.state == .ready else { return }
            await model.load()
            await models.pairing.refresh()
            // „Słucha teraz” na kaflach, odświeżane, dopóki strona jest widoczna.
            while !Task.isCancelled {
                await model.refreshListeningNow()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        // Konto tego Maca założone (kafel „Utwórz konto tego Maca”) albo zapomniane — nowa lista.
        .onChange(of: account.userState) {
            guard account.state == .ready else { return }
            if case .ready = account.userState { model.notice = nil }
            Task { await model.load() }
        }
    }

    private var needsRootPassword: Bool {
        if case .needsPassword = account.state { return true }
        return false
    }

    private var needsMacAccount: Bool {
        guard account.state == .ready else { return false }
        switch account.userState {
        case .missing, .invalid: return true
        case .unknown, .ready: return false
        }
    }

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch account.state {
            case .ready:
                EmptyView()
            case .connecting:
                ProgressView("Łączenie z serwerem…").controlSize(.small)
            case .disconnected:
                Label("Serwer nie działa — zmiany kont są niedostępne.", systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
            case .needsPassword:
                ActionBanner(text: "Aplikacja nie zna aktualnego hasła konta root, więc nie może zarządzać kontami.", actionTitle: "Podaj hasło…") {
                    navigation.path = [.root]
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let error = model.error {
                Label(error, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.users.isEmpty, model.isLoading {
                ProgressView("Wczytywanie…").controlSize(.small)
            }
        }
    }
}

/// Kafel osoby: przycisk z etykietą dla VoiceOver i menu kontekstowe ze skrótami do profilu.
private struct PersonTile: View {
    let models: AppModels
    let user: AudiobookshelfClient.ManagedUser
    @Environment(SettingsNavigation.self) private var navigation

    private var isMac: Bool { models.users.isListener(user) }
    private var phones: Int { models.pairing.devices(for: user.id).count }
    private var listening: String? { models.users.listeningNow[user.id] }

    var body: some View {
        Button {
            navigation.path = [.user(id: user.id)]
        } label: {
            VStack(spacing: 8) {
                AvatarView(store: models.avatars, userID: user.id, name: user.username, isMacAccount: isMac, isInactive: !user.isActive)
                Text(user.username)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(isMac ? Color.accentColor : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let title = listening {
                    Label(title, systemImage: "headphones")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help("Słucha teraz: \(title)")
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(user.username), \(caption)\(listening.map { ", słucha teraz: \($0)" } ?? "")")
        .accessibilityHint("Otwiera profil")
        .contextMenu {
            Button("Podłącz telefon…") { open(.pairPhone) }
                .disabled(models.account.state != .ready)
            if isMac, let password = models.account.listenerPassword {
                Button("Kopiuj hasło") { NSPasteboard.copy(password) }
            }
            Button("Zmień hasło…") { open(.changePassword) }
                .disabled(models.account.state != .ready)
        }
    }

    private func open(_ action: SettingsNavigation.ProfileAction) {
        navigation.pendingProfileAction = action
        navigation.path = [.user(id: user.id)]
    }

    private var caption: String {
        var parts: [String] = [isMac ? "Ten Mac" : UserTypeText.role(user.type)]
        if phones > 0 { parts.append(PhoneCount.text(phones)) }
        if !user.isActive { parts.append("nieaktywne") }
        if user.isLocked { parts.append("zablokowane") }
        return parts.joined(separator: " · ")
    }
}

private struct AddPersonTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .foregroundStyle(.tertiary)
                    .frame(width: 96, height: 96)
                    .overlay(Image(systemName: "plus").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary))
                Text("Dodaj osobę").font(.headline).foregroundStyle(.secondary)
                Text(" ").font(.caption)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dodaj osobę…")
    }
}

private struct CreateMacAccountTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Circle()
                    .fill(.orange.opacity(0.15))
                    .frame(width: 96, height: 96)
                    .overlay(Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundStyle(.orange))
                Text("Utwórz konto tego Maca").font(.headline).multilineTextAlignment(.center)
                Text("potrzebne do słuchania").font(.caption).foregroundStyle(.orange)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Utwórz konto tego Maca — wymaga uwagi")
    }
}

enum UserTypeText {
    static func name(_ type: String) -> String {
        switch type {
        case "root": "root"
        case "admin": "administrator"
        case "user": "użytkownik"
        case "guest": "gość"
        default: type
        }
    }

    /// Rola z wielkiej litery (kafel, odznaka w profilu).
    static func role(_ type: String) -> String {
        switch type {
        case "admin": "Administrator"
        case "user": "Użytkownik"
        case "guest": "Gość"
        case "root": "Root"
        default: type
        }
    }
}

enum PhoneCount {
    /// „1 telefon”, „2 telefony”, „5 telefonów”, „12 telefonów”, „22 telefony”.
    static func text(_ count: Int) -> String {
        let lastTwo = count % 100, last = count % 10
        let word = count == 1 ? "telefon" : (2...4).contains(last) && !(12...14).contains(lastTwo) ? "telefony" : "telefonów"
        return "\(count) \(word)"
    }
}
