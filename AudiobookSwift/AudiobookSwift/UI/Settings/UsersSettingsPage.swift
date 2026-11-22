import AudiobookshelfKit
import SwiftUI

/// Użytkownicy serwera: lista, dodawanie, edycja uprawnień i usuwanie
/// (wzorzec: `client/pages/config/users` i `AccountModal.vue` upstreamu).
struct UsersSettingsPage: View {
    let models: AppModels
    @State private var model: UsersModel?

    var body: some View {
        SettingsForm {
            if models.account.state == .ready, let model {
                UsersContent(model: model)
            } else {
                Section("Użytkownicy") {
                    AdminUnavailableRow(account: models.account)
                }
            }
        }
        .task(id: models.account.state) {
            guard models.account.state == .ready else { return }
            let model = model ?? UsersModel(account: models.account)
            self.model = model
            await model.load()
        }
    }
}

private struct UsersContent: View {
    @Bindable var model: UsersModel
    @State private var editing: UsersModel.Draft?
    @State private var userToDelete: AudiobookshelfClient.ManagedUser?
    @State private var statsUser: AudiobookshelfClient.ManagedUser?

    var body: some View {
        Section {
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
            ForEach(model.users) { user in
                UserRow(
                    user: user,
                    isListener: model.isListener(user),
                    isDeleting: model.deleting == user.id,
                    edit: { editing = UsersModel.Draft(user) },
                    delete: { userToDelete = user },
                    stats: { statsUser = user }
                )
            }
            HStack {
                Spacer()
                Button("Dodaj użytkownika…") {
                    model.notice = nil
                    editing = UsersModel.Draft()
                }
            }
        } header: {
            Text("Konta na serwerze")
        } footer: {
            Text("Każda osoba w domu może mieć własne konto z osobnym postępem słuchania. Konto root zarządza serwerem z tej aplikacji; jego hasło jest w pęku kluczy.")
                .foregroundStyle(.secondary)
        }
        .sheet(item: Binding(
            get: { editing.map(EditingDraft.init) },
            set: { editing = $0?.draft }
        )) { item in
            UserEditorSheet(model: model, draft: item.draft, isListener: item.draft.id.flatMap { id in model.users.first { $0.id == id } }.map(model.isListener) ?? false)
        }
        .sheet(item: $statsUser) { user in
            UserStatsSheet(model: model, user: user)
        }
        .confirmationDialog(
            "Usunąć konto „\(userToDelete?.username ?? "")”?",
            item: $userToDelete
        ) { user in
            Button(model.isListener(user) ? "Usuń konto używane przez aplikację" : "Usuń konto", role: .destructive) {
                Task { await model.delete(user) }
            }
            Button("Anuluj", role: .cancel) {}
        } message: { user in
            if model.isListener(user) {
                Text("Na tym koncie słuchasz na Macu i w telefonie. Po usunięciu znikną jego postęp słuchania, zakładki i playlisty, odtwarzanie się zatrzyma, a telefon zostanie wylogowany. Aplikacja poprosi o nowe konto do słuchania.")
            } else {
                Text("Znikną postęp słuchania, zakładki i playlisty tego konta; urządzenia zalogowane na nie zostaną wylogowane. Pliki audio zostają.")
            }
        }
    }

    /// `sheet(item:)` potrzebuje `Identifiable`; nowe konto ma stały identyfikator.
    private struct EditingDraft: Identifiable {
        let draft: UsersModel.Draft
        var id: String { draft.id ?? "new" }
    }
}

private struct UserRow: View {
    let user: AudiobookshelfClient.ManagedUser
    let isListener: Bool
    let isDeleting: Bool
    let edit: () -> Void
    let delete: () -> Void
    let stats: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Label(user.username, systemImage: user.isRoot ? "key" : "person")
                    if !user.isRoot || user.username != "root" {
                        Text(UserTypeText.name(user.type))
                            .font(.caption)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if !user.isActive {
                        Text("nieaktywne").font(.caption).foregroundStyle(.orange)
                    }
                    if user.isLocked {
                        Text("zablokowane").font(.caption).foregroundStyle(.orange)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isListener ? Color.accentColor : .secondary)
            }
            Spacer()
            if isDeleting {
                ProgressView().controlSize(.small)
            }
            Button("Statystyki słuchania „\(user.username)”", systemImage: "chart.bar", action: stats)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Statystyki słuchania i ostatnie sesje tego konta")
            Button("Edytuj konto „\(user.username)”", systemImage: "pencil", action: edit)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(user.isRoot)
                .help(user.isRoot ? "Konta root nie edytuje się tutaj — aplikacja zarządza nim sama" : "Edytuj konto i uprawnienia")
            Button("Usuń konto „\(user.username)”", systemImage: "trash", role: .destructive, action: delete)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(user.isRoot || isDeleting)
                .help(user.isRoot ? "Konta root nie da się usunąć" : "Usuń konto z serwera")
        }
    }

    private var subtitle: String {
        if user.isRoot { return "Zarządzanie serwerem z tej aplikacji" }
        var parts: [String] = []
        if isListener { parts.append("Konto do słuchania tej aplikacji (Mac i telefon)") }
        if let lastSeen = user.lastSeen {
            parts.append("ostatnio: " + Date(timeIntervalSince1970: lastSeen / 1000).formatted(.relative(presentation: .named).locale(Locale(identifier: "pl_PL"))))
        } else {
            parts.append("jeszcze się nie logowało")
        }
        return parts.joined(separator: " · ")
    }
}

/// Statystyki słuchania wybranego konta (etap 9i; wzorzec: `pages/config/users/_id/index.vue`).
private struct UserStatsSheet: View {
    let model: UsersModel
    let user: AudiobookshelfClient.ManagedUser
    @Environment(\.dismiss) private var dismiss
    @State private var stats: AudiobookshelfClient.ListeningStats?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Słuchanie: \(user.username)", systemImage: "chart.bar").font(.headline)
                Spacer()
            }
            .padding(14)
            Divider()
            Group {
                if let stats {
                    ListeningStatsContent(stats: stats, finished: nil)
                } else if let error {
                    ContentUnavailableView("Nie udało się wczytać", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 520, height: 600)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Gotowe") { dismiss() } }
        }
        .task {
            do {
                stats = try await model.listeningStats(user)
            } catch {
                self.error = ItemManager.message(for: error, action: "Statystyki słuchania")
            }
        }
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
}

/// Arkusz dodawania i edycji konta.
private struct UserEditorSheet: View {
    let model: UsersModel
    let isListener: Bool
    @State private var draft: UsersModel.Draft
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    init(model: UsersModel, draft: UsersModel.Draft, isListener: Bool) {
        self.model = model
        self.isListener = isListener
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Nazwa użytkownika", text: $draft.username)
                    SecureField(
                        draft.isNew ? "Hasło" : "Nowe hasło",
                        text: $draft.password,
                        prompt: Text(draft.isNew ? "wymagane" : "puste = bez zmiany")
                    )
                    Picker("Typ konta", selection: Binding(get: { draft.type }, set: { draft.setType($0) })) {
                        Text("Użytkownik").tag("user")
                        Text("Gość").tag("guest")
                        Text("Administrator").tag("admin")
                    }
                    .disabled(isListener)
                    Toggle("Aktywne", isOn: $draft.isActive)
                        .disabled(isListener)
                    if isListener {
                        Text("Tego konta używa aplikacja (okno „Biblioteka”) i telefon, więc jego typu ani aktywności nie zmienisz. Nowa nazwa lub hasło trafią od razu do pęku kluczy; telefon trzeba będzie zalogować ponownie.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if draft.type == "admin" {
                        Text("Administrator zarządza serwerem: użytkownikami, bibliotekami i ustawieniami. Na co dzień wystarczy zwykłe konto.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Uprawnienia") {
                    Toggle("Pobieranie plików", isOn: $draft.permissions.download)
                    Toggle("Edycja pozycji (metadane, okładki, rozdziały)", isOn: $draft.permissions.update)
                    Toggle("Usuwanie pozycji", isOn: $draft.permissions.delete)
                    Toggle("Wgrywanie plików", isOn: $draft.permissions.upload)
                    Toggle("Treści dla dorosłych", isOn: $draft.permissions.accessExplicitContent)
                }

                Section("Dostęp do bibliotek") {
                    Toggle("Wszystkie biblioteki", isOn: $draft.permissions.accessAllLibraries)
                    if !draft.permissions.accessAllLibraries {
                        if model.libraries.isEmpty {
                            Text("Na serwerze nie ma bibliotek.").foregroundStyle(.secondary)
                        }
                        ForEach(model.libraries) { library in
                            Toggle(library.name, isOn: membership(\.libraries, library.id))
                        }
                    }
                }

                Section("Dostęp według tagów") {
                    Toggle("Wszystkie tagi", isOn: $draft.permissions.accessAllTags)
                    if !draft.permissions.accessAllTags {
                        Picker("Wybrane tagi", selection: $draft.permissions.selectedTagsNotAccessible) {
                            Text("są dostępne (tylko one)").tag(false)
                            Text("są niedostępne").tag(true)
                        }
                        if model.tags.isEmpty {
                            Text("Pozycje nie mają jeszcze żadnych tagów (dodasz je w edycji pozycji).").foregroundStyle(.secondary)
                        }
                        ForEach(model.tags, id: \.self) { tag in
                            Toggle(tag, isOn: membership(\.tags, tag))
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Anuluj", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Dodaj konto" : "Zapisz", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
            .padding()
        }
        .frame(width: 520, height: 600)
        .navigationTitle(draft.isNew ? "Nowe konto" : "Konto „\(draft.username)”")
    }

    private func membership(_ keyPath: WritableKeyPath<UsersModel.Draft, Set<String>>, _ value: String) -> Binding<Bool> {
        Binding(
            get: { draft[keyPath: keyPath].contains(value) },
            set: { isOn in
                if isOn { draft[keyPath: keyPath].insert(value) } else { draft[keyPath: keyPath].remove(value) }
            }
        )
    }

    private func save() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            if let message = await model.save(draft) {
                error = message
            } else {
                dismiss()
            }
        }
    }
}
