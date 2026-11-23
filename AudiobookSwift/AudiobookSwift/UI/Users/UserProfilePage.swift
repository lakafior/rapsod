import AudiobookshelfKit
import SwiftUI

/// Profil osoby (Użytkownicy › osoba): wszystkie akcje jednego konta w jednym miejscu —
/// telefony, hasło, rola i dostęp, słuchanie, zaawansowane i usuwanie (etap 2 planu).
struct UserProfilePage: View {
    let models: AppModels
    let userID: String
    @Environment(SettingsNavigation.self) private var navigation

    private var model: UsersModel { models.users }

    var body: some View {
        Group {
            if let user = model.user(id: userID) {
                ProfileContent(models: models, user: user)
                    .navigationSubtitle("Użytkownicy › \(user.username)")
            } else {
                Form {
                    Section {
                        if model.isLoading || !model.hasLoaded {
                            ProgressView("Wczytywanie…").controlSize(.small)
                        } else {
                            Text("Tego konta już nie ma na serwerze.").foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
                .navigationSubtitle("Użytkownicy")
            }
        }
        .task(id: models.account.state) {
            guard models.account.state == .ready else { return }
            if !model.hasLoaded { await model.load() }
            await models.pairing.refresh()
            // Konto usunięte poza tym profilem (np. w web UI): powrót do siatki.
            if model.hasLoaded, model.user(id: userID) == nil, navigation.path.last == .user(id: userID) {
                navigation.path.removeLast()
            }
        }
    }
}

private struct ProfileContent: View {
    let models: AppModels
    let user: AudiobookshelfClient.ManagedUser
    @Environment(SettingsNavigation.self) private var navigation

    @State private var pairingPhone = false
    @State private var addressesCode: AddressesCode?
    @State private var disconnecting: PhonePairing.Device?
    @State private var changingPassword = false
    @State private var showingCredentials = false
    @State private var confirmingAdmin = false
    @State private var editingAccess = false
    @State private var editingTags = false
    @State private var showingStats = false
    @State private var choosingAvatar = false
    @State private var confirmingDelete = false
    @State private var newName = ""
    @State private var working = false
    @State private var error: String?

    private var model: UsersModel { models.users }
    private var pairing: PhonePairing { models.pairing }
    private var account: ServerAccount { models.account }
    private var isMac: Bool { model.isListener(user) }
    private var isReady: Bool { account.state == .ready }
    private var devices: [PhonePairing.Device] { pairing.devices(for: user.id) }

    var body: some View {
        Form {
            header
            if !isReady {
                Section {
                    Label(account.state == .connecting ? "Łączenie z serwerem…" : "Serwer nie działa — zmiany konta są chwilowo niedostępne.", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                }
            }
            if let error = error ?? model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            phones
            password
            role
            listening
            advanced
            deleteSection
        }
        .formStyle(.grouped)
        .disabled(working)
        .onAppear {
            newName = user.username
            consumePendingAction()
        }
        .onChange(of: navigation.pendingProfileAction) { consumePendingAction() }
        .onChange(of: user.username) { newName = user.username }
        .sheet(isPresented: $pairingPhone) { PairPhoneSheet(models: models, user: user) }
        .sheet(item: $addressesCode) { AddressesCodeSheet(url: $0.url) }
        .sheet(isPresented: $changingPassword) { changePasswordSheet }
        .sheet(isPresented: $showingCredentials) {
            CredentialsSheet(models: models, username: user.username, password: account.listenerPassword)
        }
        .sheet(isPresented: $editingAccess) { AccessSheet(model: model, user: user) }
        .sheet(isPresented: $editingTags) { TagsSheet(model: model, user: user) }
        .sheet(isPresented: $showingStats) { UserStatsSheet(model: model, user: user) }
        .sheet(isPresented: $choosingAvatar) { AvatarSheet(store: models.avatars, user: user, isMacAccount: isMac) }
        .confirmationDialog(
            "Odłączyć telefon „\(disconnecting?.name ?? "")”?",
            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
            presenting: disconnecting
        ) { device in
            Button("Odłącz", role: .destructive) { disconnect(device) }
        } message: { _ in
            Text("Telefon straci dostęp do konta „\(user.username)” przy następnym połączeniu. Żeby znów go użyć, podłącz go ponownie.")
        }
        .confirmationDialog("Nadać kontu „\(user.username)” rolę „Administrator”?", isPresented: $confirmingAdmin) {
            Button("Nadaj rolę „Administrator”") { setRole("admin") }
        } message: {
            Text(AdminExplanation.text(username: user.username))
        }
        .confirmationDialog("Usunąć konto „\(user.username)”?", isPresented: $confirmingDelete) {
            Button(isMac ? "Usuń konto „\(user.username)” używane przez ten Mac" : "Usuń konto „\(user.username)”", role: .destructive) { delete() }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text(deleteExplanation)
        }
    }

    // MARK: Nagłówek

    private var header: some View {
        Section {
            HStack(spacing: 18) {
                Button { choosingAvatar = true } label: {
                    AvatarView(store: models.avatars, userID: user.id, name: user.username, size: 72, isMacAccount: isMac, isInactive: !user.isActive)
                }
                .buttonStyle(.plain)
                .help("Zmień awatar…")
                .accessibilityLabel("Zmień awatar…")
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.username)
                        .font(.title.weight(.semibold))
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        if isMac { Chip(text: "Konto tego Maca", systemImage: "laptopcomputer", tint: .accentColor) }
                        Chip(text: UserTypeText.role(user.type), systemImage: user.type == "admin" ? "person.badge.key" : "person", tint: .secondary)
                        if !user.isActive { Chip(text: "nieaktywne", systemImage: "moon", tint: .orange) }
                        if user.isLocked { Chip(text: "zablokowane", systemImage: "lock", tint: .orange) }
                    }
                    Text(lastSeen)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private var lastSeen: String {
        guard let lastSeen = user.lastSeen else { return "Jeszcze się nie logowało" }
        return "Ostatnio: " + Date(timeIntervalSince1970: lastSeen / 1000).formatted(.relative(presentation: .named).locale(Locale(identifier: "pl_PL")))
    }

    // MARK: Telefony

    private var phones: some View {
        Section {
            if devices.isEmpty {
                LabeledContent("Telefony", value: pairing.isLoading ? "Wczytywanie…" : "brak")
            }
            ForEach(devices) { device in
                DeviceRow(device: device) { disconnecting = device }
            }
            HStack {
                if !pairing.devices.isEmpty {
                    Button("Kod z adresami…") { addressesCode = pairing.addressesCode().map(AddressesCode.init) }
                        .disabled(pairing.addresses.isEmpty)
                        .help("Aktualizuje adresy serwera na podłączonych telefonach bez ponownego podłączania")
                }
                Spacer()
                Button("Podłącz telefon…", systemImage: "qrcode") { pairingPhone = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(pairing.unavailableReason(for: user) != nil)
            }
            if let reason = pairing.unavailableReason(for: user) {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let loadError = pairing.loadError {
                Text(loadError).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Telefony")
        } footer: {
            Text("Telefon z aplikacją AudiobookSwift dostaje własny klucz tego konta — bez hasła i bez konta root\(isMac ? "; postęp słuchania jest wspólny z tym Makiem" : ""). Klucz nie wygasa; „Odłącz” cofa go od razu. Po zmianie adresów serwera „Kod z adresami” aktualizuje telefony wszystkich osób.")
        }
    }

    // MARK: Hasło

    private var password: some View {
        Section {
            PasswordRow(password: isMac ? account.listenerPassword : nil, unknownText: "znane tylko tej osobie", change: isReady ? { changingPassword = true } : nil)
            if isMac {
                LabeledContent("Do innych aplikacji") {
                    Button("Dane logowania (adres, nazwa, hasło)…") { showingCredentials = true }
                }
            }
        } header: {
            Text("Hasło")
        } footer: {
            if !isMac {
                Text("Serwer nie zdradza haseł. Po zmianie hasło i dane logowania do innych aplikacji pokażą się raz.")
            }
        }
    }

    private var changePasswordSheet: some View {
        ChangePasswordSheet(
            models: models,
            username: user.username,
            remembered: isMac,
            note: isMac
                ? "Aplikacja zapamięta nowe hasło w pęku kluczy. Telefony z aplikacją AudiobookSwift działają dalej; w innych aplikacjach trzeba będzie zalogować się ponownie."
                : "Telefony z aplikacją AudiobookSwift działają dalej; w innych aplikacjach trzeba będzie zalogować się ponownie."
        ) { newPassword in
            try await model.setPassword(newPassword, of: user)
        }
    }

    // MARK: Rola i dostęp

    private var role: some View {
        Section {
            Picker("Rola", selection: Binding(get: { user.type }, set: chooseRole)) {
                if !isMac || user.type == "guest" { Text("Gość").tag("guest") }
                Text("Użytkownik").tag("user")
                Text("Administrator").tag("admin")
            }
            .pickerStyle(.segmented)
            .disabled(!isReady)
            if user.type == "admin", !user.permissions.update {
                // Typ administratora nadany przed etapem 10e albo w web UI — telefon nie zleci pobrań.
                ActionBanner(text: "Administrator bez „Edycji pozycji”: telefon nie zleci pobierania odcinków.", actionTitle: "Napraw") {
                    perform("Nie udało się zmienić uprawnień") { _ = try await model.setRole("admin", of: user) }
                }
            }
            LabeledContent("Uprawnienia", value: permissionsSummary)
            LabeledContent("Biblioteki", value: librariesSummary)
            HStack {
                Spacer()
                Button("Zarządzaj dostępem…") { editingAccess = true }
                    .disabled(!isReady)
            }
        } header: {
            Text("Rola i dostęp")
        } footer: {
            Text("Administrator (z „Edycją pozycji”) jest potrzebny tylko do zlecania z telefonu pobierania odcinków podcastów. Daje jednak zarządzanie całym serwerem z każdego podłączonego telefonu. Gość tylko słucha.")
        }
    }

    private func chooseRole(_ role: String) {
        guard role != user.type else { return }
        if role == "admin" {
            confirmingAdmin = true
        } else {
            setRole(role)
        }
    }

    private var permissionsSummary: String {
        let p = user.permissions
        let names = [
            p.download ? "pobieranie" : nil,
            p.update ? "edycja pozycji" : nil,
            p.delete ? "usuwanie" : nil,
            p.upload ? "wgrywanie" : nil,
            p.accessExplicitContent ? "treści dla dorosłych" : nil,
        ].compactMap { $0 }
        return names.isEmpty ? "tylko słuchanie" : names.joined(separator: ", ")
    }

    private var librariesSummary: String {
        if user.permissions.accessAllLibraries { return "wszystkie" }
        let names = model.libraries.filter { user.librariesAccessible.contains($0.id) }.map(\.name)
        return names.isEmpty ? "żadna" : names.joined(separator: ", ")
    }

    // MARK: Słuchanie

    private var listening: some View {
        Section("Słuchanie") {
            LabeledContent("Statystyki i ostatnie sesje") {
                Button("Statystyki słuchania…") { showingStats = true }
                    .disabled(!isReady)
            }
        }
    }

    // MARK: Zaawansowane i usuwanie

    private var advanced: some View {
        AdvancedSection(summary: isMac ? "Nazwa konta na serwerze, klucze API i dostęp według tagów" : "Nazwa konta na serwerze, aktywność, klucze API i dostęp według tagów") {
            LabeledContent("Nazwa konta") {
                HStack {
                    TextField("Nazwa konta", text: $newName)
                        .labelsHidden()
                        .frame(maxWidth: 200)
                        .onSubmit(rename)
                    Button("Zmień nazwę", action: rename)
                        .disabled(!isReady || newName.trimmingCharacters(in: .whitespaces).isEmpty || newName == user.username)
                }
            }
            if !isMac {
                Toggle("Aktywne (może się logować)", isOn: Binding(get: { user.isActive }, set: setActive))
                    .disabled(!isReady)
            }
            LabeledContent("Inne klucze API tego konta") {
                HStack {
                    Text("\(pairing.otherKeyCounts[user.id] ?? 0)").foregroundStyle(.secondary)
                    Button("Klucze API…") {
                        navigation.pendingAdvanced = .sharing
                        navigation.page = .sharing
                    }
                }
            }
            LabeledContent("Dostęp według tagów") {
                HStack {
                    Text(tagsSummary).foregroundStyle(.secondary)
                    Button("Zmień…") { editingTags = true }
                        .disabled(!isReady)
                }
            }
        } footer: {
            if isMac {
                Text("Konta tego Maca nie da się dezaktywować — aplikacja przestałaby działać. Nowa nazwa trafia od razu do pęku kluczy; telefony z aplikacją AudiobookSwift działają dalej.")
            }
        }
    }

    private var tagsSummary: String {
        let p = user.permissions
        if p.accessAllTags { return "wszystkie tagi" }
        let tags = user.itemTagsSelected.joined(separator: ", ")
        return p.selectedTagsNotAccessible ? "bez: \(tags)" : "tylko: \(tags)"
    }

    private var deleteSection: some View {
        Section {
            HStack {
                Button("Usuń konto…", role: .destructive) { confirmingDelete = true }
                    .disabled(!isReady)
                if model.deleting == user.id { ProgressView().controlSize(.small) }
            }
        } footer: {
            Text(deleteExplanation)
        }
    }

    private var deleteExplanation: String {
        isMac
            ? "Usunięcie konta tego Maca zatrzyma odtwarzanie, odłączy telefony tego konta i skasuje jego postęp słuchania, zakładki i playlisty. Aplikacja poprosi o nowe konto. Pliki audio zostają."
            : "Znikną postęp słuchania, zakładki i playlisty tego konta; jego telefony i inne urządzenia zostaną wylogowane. Pliki audio zostają."
    }

    // MARK: Akcje

    private func consumePendingAction() {
        guard let action = navigation.pendingProfileAction else { return }
        navigation.pendingProfileAction = nil
        switch action {
        case .pairPhone: pairingPhone = true
        case .changePassword: changingPassword = true
        }
    }

    private func perform(_ failure: String, _ operation: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await operation()
            } catch {
                self.error = ItemManager.message(for: error, action: failure)
            }
        }
    }

    private func setRole(_ role: String) {
        perform("Nie udało się zmienić roli") { _ = try await model.setRole(role, of: user) }
    }

    private func disconnect(_ device: PhonePairing.Device) {
        perform("Nie udało się odłączyć telefonu") { try await pairing.revoke(keyID: device.id) }
    }

    private func rename() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != user.username else { return }
        perform("Nie udało się zmienić nazwy") {
            if let message = await model.rename(user, to: name) { throw ProfileError(message: message) }
        }
    }

    private func setActive(_ isActive: Bool) {
        perform("Nie udało się zmienić aktywności") {
            if let message = await model.setActive(isActive, of: user) { throw ProfileError(message: message) }
        }
    }

    private func delete() {
        let id = user.id
        perform("Nie udało się usunąć konta") {
            await model.delete(user)
            guard model.user(id: id) == nil else { return }
            models.avatars.reset(id)
            await pairing.refresh()
            if navigation.path.last == .user(id: id) { navigation.path.removeLast() }
        }
    }

    private struct ProfileError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

/// Odznaka w nagłówku profilu.
struct Chip: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}
