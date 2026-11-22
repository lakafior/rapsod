import SwiftUI

/// Własni dostawcy metadanych audiobookshelf (etap 9g; wzorzec:
/// `pages/config/item-metadata-utils/custom-metadata-providers.vue`): lista, dodanie i usunięcie.
/// Upstream nie ma edycji wpisu. Wpis wbudowanych źródeł aplikacji jest zablokowany — dodaje go
/// i usuwa przełącznik „Polskie źródła metadanych” wyżej. Tokenem root.
@MainActor
@Observable
final class CustomProvidersModel {
    let account: ServerAccount
    let status = AdminStatus()
    private(set) var providers: [AudiobookshelfClient.CustomMetadataProvider] = []
    private(set) var loaded = false

    init(account: ServerAccount) {
        self.account = account
    }

    func load() async {
        await status.run("Wczytywanie…", failure: "Nie udało się wczytać dostawców") {
            providers = try await account.withAdminToken { try await $0.customMetadataProviders(token: $1) }
            loaded = true
        }
    }

    func isBuiltIn(_ provider: AudiobookshelfClient.CustomMetadataProvider) -> Bool {
        provider.name == MetadataSourcesController.providerName
    }

    func add(name: String, url: String, mediaType: String, auth: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        let url = url.trimmingCharacters(in: .whitespaces)
        let auth = auth.trimmingCharacters(in: .whitespaces)
        return await status.run("Dodawanie…", failure: "Nie udało się dodać dostawcy") {
            guard !name.isEmpty else { throw ItemManager.ManageError.invalid("Podaj nazwę dostawcy.") }
            guard name != MetadataSourcesController.providerName else {
                throw ItemManager.ManageError.invalid("Ta nazwa jest zarezerwowana dla wbudowanych źródeł aplikacji.")
            }
            guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else {
                throw ItemManager.ManageError.invalid("Adres musi zaczynać się od http:// albo https://.")
            }
            let created = try await account.withAdminToken {
                try await $0.createCustomMetadataProvider(name: name, url: url, mediaType: mediaType, authHeaderValue: auth.isEmpty ? nil : auth, token: $1)
            }
            providers.append(created)
            status.notice = "Dodano „\(created.name)”. Wybierzesz go jako źródło w ustawieniach biblioteki albo w oknie dopasowania."
        }
    }

    func delete(_ provider: AudiobookshelfClient.CustomMetadataProvider) async {
        await status.run("Usuwanie…", failure: "Nie udało się usunąć dostawcy") {
            try await account.withAdminToken { try await $0.deleteCustomMetadataProvider(id: provider.id, token: $1) }
            providers.removeAll { $0.id == provider.id }
            try? await account.refreshLibraries()
        }
    }
}

struct CustomProvidersSection: View {
    let account: ServerAccount
    /// Zmienia się, gdy aplikacja dodaje albo usuwa wpis wbudowanych źródeł — lista wczytuje się wtedy od nowa.
    var refreshKey = ""
    @State private var model: CustomProvidersModel
    @State private var adding = false
    @State private var removing: AudiobookshelfClient.CustomMetadataProvider?

    init(account: ServerAccount, refreshKey: String = "") {
        self.account = account
        self.refreshKey = refreshKey
        _model = State(initialValue: CustomProvidersModel(account: account))
    }

    var body: some View {
        Section {
            if account.state != .ready {
                AdminUnavailableRow(account: account)
            } else {
                if model.loaded, model.providers.isEmpty {
                    Text("Brak własnych dostawców.").foregroundStyle(.secondary)
                }
                ForEach(model.providers) { provider in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                            Text(verbatim: "\(provider.url) · \(provider.mediaType == "podcast" ? "podcasty" : "książki")\(provider.authHeaderValue?.isEmpty == false ? " · z nagłówkiem autoryzacji" : "")")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        if model.isBuiltIn(provider) {
                            Text("wbudowany").font(.caption).foregroundStyle(.secondary)
                                .help("Ten wpis dodaje i usuwa przełącznik „Polskie źródła metadanych”.")
                        } else {
                            Button("Usuń „\(provider.name)”", systemImage: "trash", role: .destructive) { removing = provider }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .disabled(model.status.isBusy)
                        }
                    }
                }
                AdminStatusRows(status: model.status)
                Button("Dodaj dostawcę…") { adding = true }
                    .disabled(model.status.isBusy)
            }
        } header: {
            Text("Własni dostawcy metadanych (serwer audiobookshelf)")
        } footer: {
            Text("Serwer pyta dostawcę o `GET <adres>/search` zgodnie ze specyfikacją audiobookshelf. Usunięcie dostawcy przestawia biblioteki, które go używały, na Google Books.")
                .foregroundStyle(.secondary)
        }
        .task(id: "\(account.state)|\(refreshKey)") {
            guard account.state == .ready else { return }
            await model.load()
        }
        .sheet(isPresented: $adding) { AddCustomProviderSheet(model: model) }
        .confirmationDialog("Usunąć dostawcę „\(removing?.name ?? "")”?", item: $removing) { provider in
            Button("Usuń", role: .destructive) { Task { await model.delete(provider) } }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in
            Text("Biblioteki, które miały go jako domyślne źródło, przejdą na Google Books.")
        }
    }
}

private struct AddCustomProviderSheet: View {
    let model: CustomProvidersModel
    @State private var name = ""
    @State private var url = ""
    @State private var mediaType = "book"
    @State private var auth = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("Nazwa", text: $name)
                TextField("Adres", text: $url, prompt: Text(verbatim: "https://example.com/api"))
                Picker("Typ", selection: $mediaType) {
                    Text("Książki").tag("book")
                    Text("Podcasty").tag("podcast")
                }
                SecureField("Nagłówek Authorization (opcjonalnie)", text: $auth)
                AdminStatusRows(status: model.status)
            } header: {
                Text("Nowy dostawca metadanych")
            } footer: {
                Text("Wartość nagłówka serwer wysyła dostawcy przy każdym zapytaniu; zapisuje ją w swojej bazie.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Dodaj") {
                    Task { if await model.add(name: name, url: url, mediaType: mediaType, auth: auth) { dismiss() } }
                }
                .disabled(model.status.isBusy || name.isEmpty || url.isEmpty)
            }
        }
    }
}
