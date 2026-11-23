import AppKit
import AudiobookshelfKit
import SwiftUI

/// Wspólny opis roli administratora przy telefonach (profil i arkusz „Podłącz telefon”).
enum AdminExplanation {
    static func text(username: String) -> String {
        "Rola „Administrator” (razem z „Edycją pozycji”, której serwer też wymaga) jest potrzebna tylko do zlecania z telefonu pobierania odcinków podcastów na serwer. Oznacza jednak, że konto „\(username)” może zarządzać całym serwerem (użytkownicy, biblioteki, ustawienia) z każdego klienta — z każdego podłączonego telefonu i z każdej aplikacji, w której wpisano jego hasło. Konto root nigdy nie trafia do telefonu. Rolę zmienisz w profilu w każdej chwili."
    }
}

/// Wiersz podłączonego telefonu z „Odłącz…”.
struct DeviceRow: View {
    let device: PhonePairing.Device
    let disconnect: () -> Void

    var body: some View {
        LabeledContent {
            Button("Odłącz…", role: .destructive, action: disconnect)
                .accessibilityLabel("Odłącz telefon „\(device.name)”…")
        } label: {
            Label {
                Text(device.name)
                Text(details)
            } icon: {
                Image(systemName: "iphone").foregroundStyle(Color.accentColor)
            }
        }
    }

    private var details: String {
        var parts: [String] = []
        if let created = device.createdAt {
            parts.append("podłączony \(created.formatted(date: .abbreviated, time: .shortened))")
        }
        // Serwer v2.38.0 nie zapisuje ostatniego użycia klucza — pokazujemy je tylko, jeśli kiedyś zacznie.
        if let used = device.lastUsedAt {
            parts.append("ostatnio \(used.formatted(.relative(presentation: .named)))")
        }
        if device.isExpired {
            parts.append("klucz wygasł")
        } else if !device.isActive {
            parts.append("klucz wyłączony")
        }
        return parts.joined(separator: " · ")
    }
}

/// Arkusz „Podłącz telefon”: nazwa telefonu, pytanie o rolę administratora (nie dla gościa),
/// w razie potrzeby włączenie sieci domowej, potem ukryty kod QR.
///
/// Klucz istnieje tylko w pamięci tego widoku: kod trzeba odsłonić kliknięciem, zakrywa się
/// sam po `visibleFor` i przy przejściu do innej aplikacji, a znika z pamięci po upływie
/// `lifetime` i przy zamknięciu arkusza (także razem z oknem ustawień albo powrotem z profilu).
///
/// Włączenie sieci domowej restartuje serwer: konto root rozłącza się i łączy ponownie. Profil
/// i ten arkusz zostają na ekranie (lista kont jest w `UsersModel`), a klucz powstaje dopiero
/// wtedy, gdy serwer znów jest gotowy i ma adresy w sieci.
struct PairPhoneSheet: View {
    let models: AppModels
    let user: AudiobookshelfClient.ManagedUser

    @Environment(\.dismiss) private var dismiss
    @State private var deviceName = "iPhone"
    @State private var grantAdmin = false
    @State private var enableHomeNetwork = false
    @State private var phase: String?
    @State private var error: String?
    @State private var code: PhonePairing.Code?
    @State private var image: CGImage?
    @State private var isRevealed = false
    @State private var hideTask: Task<Void, Never>?
    @State private var expired = false
    @State private var createdKeyID: String?

    private static let visibleFor: Duration = .seconds(60)
    private static let lifetime: Duration = .seconds(5 * 60)
    private static let restartTimeout: Duration = .seconds(90)

    private var pairing: PhonePairing { models.pairing }
    private var isMacAccount: Bool { models.users.isListener(user) }
    /// Aktualny stan konta (np. po nadaniu roli), z listy w modelu.
    private var current: AudiobookshelfClient.ManagedUser { models.users.user(id: user.id) ?? user }
    private var needsHomeNetwork: Bool { pairing.addresses.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Podłącz telefon — \(user.username)").font(.title2.bold())
            if let code, let image {
                codeView(code: code, image: image)
            } else if expired {
                Text("Kod zniknął z ekranu. Jeśli telefon zdążył go zeskanować, wszystko jest gotowe; jeśli nie — odłącz ten telefon na liście i podłącz go jeszcze raz.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Gotowe") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                form
            }
        }
        .padding(24)
        .frame(width: 480)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            hide()
        }
        .onDisappear { forget() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Nazwa telefonu", text: $deviceName, prompt: Text("np. iPhone Ani"))
                if current.type != "guest" {
                    if PhonePairing.canOrderDownloads(current) {
                        Text("Konto ma rolę „Administrator”: telefon może zlecać pobieranie odcinków. Rolę zmienisz w profilu.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Toggle("Pozwolić z telefonu zlecać pobieranie odcinków (rola „Administrator”)", isOn: $grantAdmin)
                        Text(AdminExplanation.text(username: user.username))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if needsHomeNetwork, phase == nil {
                    if pairing.canEnableHomeNetwork {
                        Toggle("Włącz udostępnianie w sieci domowej", isOn: $enableHomeNetwork)
                        Text("Telefon nie ma teraz jak połączyć się z Makiem. Sieć domowa działa po zwykłym HTTP: hasła i treść są widoczne dla innych urządzeń w tej samej sieci. Włączenie uruchomi serwer ponownie (odtwarzanie na Macu na chwilę się zatrzyma). Wyłączysz ją w Ustawieniach → Dostęp zdalny.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let reason = pairing.unavailableReason(for: current) {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.columns)

            if !pairing.addresses.isEmpty {
                Text("Adresy w kodzie: \(pairing.addresses.map(\.url.absoluteString).joined(separator: ", "))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !pairing.addresses.contains(where: { $0.kind == .remote }) {
                Text("Bez dostępu spoza domu telefon połączy się tylko w tej samej sieci co Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let phase {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(phase)
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Anuluj") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(phase != nil)
                Button("Utwórz kod") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(phase != nil || (needsHomeNetwork && !enableHomeNetwork && !models.sharing.isBusy))
            }
        }
    }

    private func codeView(code: PhonePairing.Code, image: CGImage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Zeskanuj kod aparatem iPhone’a albo w aplikacji AudiobookSwift („\(code.deviceName)”). Kod zawiera klucz dostępu do konta „\(user.username)” — nie pokazuj go innym.")
                .fixedSize(horizontal: false, vertical: true)
            ZStack {
                Image(decorative: image, scale: 2)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 256, height: 256)
                    .blur(radius: isRevealed ? 0 : 24)
                    .opacity(isRevealed ? 1 : 0.15)
                    .accessibilityHidden(!isRevealed)
                if !isRevealed {
                    Button("Kliknij, aby pokazać kod") { reveal() }
                        .controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .onTapGesture { if !isRevealed { reveal() } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Kod podłączenia telefonu")

            Text(isRevealed ? "Kod zakryje się sam po minucie." : "Kod jest zakryty. Odsłoń go, gdy telefon będzie gotowy do skanowania.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button("Anuluj i odłącz telefon", role: .destructive) { cancelAndRevoke() }
                Spacer()
                Button("Gotowe") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func create() {
        error = nil
        Task {
            defer { phase = nil }
            do {
                if needsHomeNetwork {
                    try await turnOnHomeNetwork()
                }
                var target = current
                if grantAdmin, target.type != "guest", !PhonePairing.canOrderDownloads(target) {
                    phase = "Nadawanie roli „Administrator”…"
                    target = try await models.users.setRole("admin", of: target)
                }
                phase = "Tworzenie klucza telefonu…"
                let code = try await pairing.pair(deviceName: deviceName, user: target)
                guard let image = PairingQRCode.image(for: code.url) else {
                    error = "Nie udało się utworzyć obrazu kodu."
                    return
                }
                self.code = code
                self.image = image
                createdKeyID = code.keyID
                scheduleExpiry()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Włącza sieć domową (restart serwera) i czeka, aż serwer z kontem root znów będzie gotowy
    /// i będzie miał adresy w sieci — dopiero wtedy kod ma sens.
    private func turnOnHomeNetwork() async throws {
        let sharing = models.sharing
        if !sharing.isEnabled {
            guard enableHomeNetwork else { throw PhonePairing.PairingError.noAddresses }
            phase = "Włączanie sieci domowej i ponowne uruchamianie serwera…"
            await sharing.setEnabled(true)
            if let message = sharing.lastError { throw SheetError(message: message) }
        }
        phase = "Czekanie na serwer…"
        let deadline = ContinuousClock.now + Self.restartTimeout
        while models.account.state != .ready || pairing.addresses.isEmpty || sharing.isBusy {
            guard ContinuousClock.now < deadline else {
                throw SheetError(message: "Serwer nie wrócił w ciągu 90 sekund. Sprawdź stan w Ustawieniach → Ogólne i spróbuj jeszcze raz.")
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        // Po restarcie lista kont mogła się zmienić (np. zmiana w web UI); profil też się odświeży.
        await models.users.load()
        await pairing.refresh()
    }

    private struct SheetError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func reveal() {
        isRevealed = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    private func hide() {
        isRevealed = false
        hideTask?.cancel()
    }

    private func scheduleExpiry() {
        Task {
            try? await Task.sleep(for: Self.lifetime)
            guard code != nil else { return }
            forget()
            expired = true
        }
    }

    /// Usuwa kod (a z nim klucz) z pamięci widoku.
    private func forget() {
        hide()
        code = nil
        image = nil
    }

    private func cancelAndRevoke() {
        let keyID = createdKeyID
        forget()
        Task {
            if let keyID { try? await pairing.revoke(keyID: keyID) }
            dismiss()
        }
    }
}

/// Kod z samymi adresami serwera (bez klucza), dla już podłączonych telefonów wszystkich osób.
struct AddressesCodeSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Kod z adresami").font(.headline)
            Text("Zeskanuj kod aparatem iPhone’a albo w aplikacji AudiobookSwift („Zeskanuj kod z Maca”). Zaktualizuje adresy serwera na telefonie bez ponownego podłączania. Kod nie zawiera klucza — działa dla telefonów wszystkich osób.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let image = PairingQRCode.image(for: url) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                    .accessibilityLabel(Text("Kod z adresami serwera"))
            }
            Button("Gotowe") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 380)
    }
}

struct AddressesCode: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// „Dane logowania do innych aplikacji” (oficjalna aplikacja audiobookshelf, Plappa, ShelfPlayer):
/// adres serwera, nazwa i hasło do przepisania.
struct CredentialsRows: View {
    let models: AppModels
    let username: String
    let password: String?

    private var sharing: SharingController { models.sharing }
    private var isReachable: Bool {
        models.supervisor.state == .running && models.supervisor.environment?.listensOnLAN == true
    }

    var body: some View {
        if sharing.isEnabled, isReachable {
            ForEach(Array(sharing.localURLs.enumerated()), id: \.element) { index, url in
                CopyableRow(title: index == 0 ? "Adres w sieci domowej" : "", value: url.absoluteString)
            }
        }
        if let external = sharing.externalURL {
            CopyableRow(title: "Adres spoza domu", value: external.absoluteString)
        }
        if !(sharing.isEnabled && isReachable), sharing.externalURL == nil {
            Text("Serwer jest dostępny tylko z tego Maca. Sieć domową albo dostęp spoza domu włączysz w Ustawieniach → Dostęp zdalny.")
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        CopyableRow(title: "Nazwa użytkownika", value: username)
        PasswordRow(password: password)
    }
}

struct CredentialsSheet: View {
    let models: AppModels
    let username: String
    let password: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    CredentialsRows(models: models, username: username, password: password)
                } header: {
                    Text("Dane logowania — \(username)")
                } footer: {
                    Text("Dla innych aplikacji audiobookshelf (np. oficjalnej, Plappa, ShelfPlayer). Aplikacja AudiobookSwift na telefonie hasła nie potrzebuje — podłączasz ją kodem QR w profilu.")
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Gotowe") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 380)
    }
}

/// Zmiana hasła: wspólna dla osób i roota. Puste pole = losowe hasło. Gdy aplikacja nie
/// zapamiętuje hasła (inne osoby), po zmianie pokazuje je raz razem z danymi logowania.
struct ChangePasswordSheet: View {
    let models: AppModels
    let username: String
    /// Czy nowe hasło trafia do pęku kluczy (konto tego Maca, root) — wtedy nie trzeba go pokazywać.
    let remembered: Bool
    let note: String
    let change: (String) async throws -> String

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var repeated = ""
    @State private var working = false
    @State private var error: String?
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                if let result {
                    Section {
                        CredentialsRows(models: models, username: username, password: result)
                    } header: {
                        Text("Hasło zmienione")
                    } footer: {
                        Text(remembered ? "Nowe hasło jest w pęku kluczy tego Maca." : "Aplikacja nie zapamiętuje haseł innych osób — przepisz je teraz albo zmień później jeszcze raz.")
                    }
                } else {
                    Section {
                        SecureField("Nowe hasło", text: $password, prompt: Text("puste = losowe"))
                        if !password.isEmpty {
                            SecureField("Powtórz hasło", text: $repeated)
                        }
                    } header: {
                        Text("Zmień hasło — \(username)")
                    } footer: {
                        Text(note)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                if result == nil {
                    Button("Anuluj", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Zmień hasło", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || (!password.isEmpty && password != repeated))
                } else {
                    Button("Gotowe") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 560, height: result == nil ? 300 : 400)
        .onDisappear {
            // Hasło nie zostaje w pamięci widoku dłużej niż trzeba.
            password = ""
            repeated = ""
            result = nil
        }
    }

    private func save() {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let newPassword = try await change(password)
                if remembered {
                    dismiss()
                } else {
                    result = newPassword
                }
            } catch let failure as ServerAccount.RootPasswordError {
                if case .keychain(_, let newPassword) = failure { result = newPassword }
                error = failure.localizedDescription
            } catch {
                self.error = ItemManager.message(for: error, action: "Nie udało się zmienić hasła")
            }
        }
    }
}
