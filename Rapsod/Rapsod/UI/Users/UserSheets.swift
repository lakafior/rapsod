import AppKit
import AudiobookshelfKit
import SwiftUI

/// Statystyki słuchania wybranego konta (etap 9i; wzorzec: `pages/config/users/_id/index.vue`).
struct UserStatsSheet: View {
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


/// Arkusz „Dodaj osobę”: nazwa, hasło, rola, uprawnienia, biblioteki i tagi nowego konta.
struct NewPersonSheet: View {
    let model: UsersModel
    @State private var draft = UsersModel.Draft()
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Nazwa użytkownika", text: $draft.username)
                    SecureField("Hasło", text: $draft.password, prompt: Text("wymagane"))
                    Picker("Rola", selection: Binding(get: { draft.type }, set: { draft.setType($0) })) {
                        Text("Gość").tag("guest")
                        Text("Użytkownik").tag("user")
                        Text("Administrator").tag("admin")
                    }
                    Toggle("Aktywne", isOn: $draft.isActive)
                    if draft.type == "admin" {
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
                Button("Dodaj osobę", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
            .padding()
        }
        .frame(width: 520, height: 600)
        .navigationTitle("Nowa osoba")
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

/// Wspólny szkielet arkuszy z formularzem i paskiem „Anuluj / Zapisz”.
private struct DraftSheet<Content: View>: View {
    let title: String
    let model: UsersModel
    @Binding var draft: UsersModel.Draft
    var height: CGFloat = 520
    @ViewBuilder let content: Content
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form { content }
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
                Button("Zapisz", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
            .padding()
        }
        .frame(width: 520, height: height)
        .navigationTitle(title)
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

@MainActor
private func membership(_ draft: Binding<UsersModel.Draft>, _ keyPath: WritableKeyPath<UsersModel.Draft, Set<String>> & Sendable, _ value: String) -> Binding<Bool> {
    Binding(
        get: { draft.wrappedValue[keyPath: keyPath].contains(value) },
        set: { isOn in
            if isOn { draft.wrappedValue[keyPath: keyPath].insert(value) } else { draft.wrappedValue[keyPath: keyPath].remove(value) }
        }
    )
}

/// „Zarządzaj dostępem…”: uprawnienia i biblioteki osoby (rola jest na profilu).
struct AccessSheet: View {
    let model: UsersModel
    @State private var draft: UsersModel.Draft

    init(model: UsersModel, user: AudiobookshelfClient.ManagedUser) {
        self.model = model
        _draft = State(initialValue: UsersModel.Draft(user))
    }

    var body: some View {
        DraftSheet(title: "Dostęp — \(draft.username)", model: model, draft: $draft, height: 560) {
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
                        Toggle(library.name, isOn: membership($draft, \.libraries, library.id))
                    }
                }
            }
        }
    }
}

/// Dostęp według tagów (profil › Zaawansowane).
struct TagsSheet: View {
    let model: UsersModel
    @State private var draft: UsersModel.Draft

    init(model: UsersModel, user: AudiobookshelfClient.ManagedUser) {
        self.model = model
        _draft = State(initialValue: UsersModel.Draft(user))
    }

    var body: some View {
        DraftSheet(title: "Tagi — \(draft.username)", model: model, draft: $draft, height: 460) {
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
                        Toggle(tag, isOn: membership($draft, \.tags, tag))
                    }
                }
            }
        }
    }
}

/// Wybór awatara: symbol na kolorze, zdjęcie albo inicjały. Zapis tylko na tym Macu.
struct AvatarSheet: View {
    let store: AvatarStore
    let user: AudiobookshelfClient.ManagedUser
    let isMacAccount: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var color: Int
    @State private var error: String?

    init(store: AvatarStore, user: AudiobookshelfClient.ManagedUser, isMacAccount: Bool) {
        self.store = store
        self.user = user
        self.isMacAccount = isMacAccount
        if case .symbol(_, let saved) = store.avatar(for: user.id) {
            _color = State(initialValue: saved)
        } else {
            _color = State(initialValue: AvatarStore.defaultColor(for: user.id))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                AvatarView(store: store, userID: user.id, name: user.username, size: 72, isMacAccount: isMacAccount)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Awatar — \(user.username)").font(.title2.bold())
                    Text("Awatar jest zapisany tylko na tym Macu (w folderze danych serwera). Telefony go nie widzą, a kopia zapasowa audiobookshelf go nie obejmuje.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Kolor").font(.headline)
            HStack(spacing: 10) {
                ForEach(AvatarStore.palette.indices, id: \.self) { index in
                    Button {
                        color = index
                    } label: {
                        Circle()
                            .fill(LinearGradient(colors: AvatarStore.palette[index], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(Color.primary, lineWidth: color == index ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Kolor \(index + 1)")
                    .accessibilityAddTraits(color == index ? .isSelected : [])
                }
            }
            Text("Symbol").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 8), count: 8), spacing: 8) {
                ForEach(AvatarStore.symbols, id: \.self) { symbol in
                    Button {
                        save { try store.setSymbol(symbol, color: color, for: user.id) }
                    } label: {
                        Text(symbol)
                            .font(.system(size: 22))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Symbol \(symbol)")
                }
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Button("Wybierz zdjęcie…", action: choosePhoto)
                Button("Inicjały") {
                    store.reset(user.id)
                }
                Spacer()
                Button("Gotowe") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func save(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = "Nie udało się zapisać awatara: \(error.localizedDescription)"
        }
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Wybierz zdjęcie do awatara (środek zostanie przycięty do koła)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        save { try store.setPhoto(from: url, for: user.id) }
    }
}

/// „Utwórz konto tego Maca”: ten sam formularz co w oknach Biblioteka i web UI (X8).
struct CreateMacAccountSheet: View {
    let account: ServerAccount
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    UserAccountSection(account: account)
                } header: {
                    Text("Konto tego Maca")
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Zamknij") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 520, height: 340)
        .onChange(of: account.userState) {
            if case .ready = account.userState { dismiss() }
        }
    }
}
