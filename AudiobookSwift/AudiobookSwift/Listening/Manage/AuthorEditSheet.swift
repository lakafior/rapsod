import SwiftUI

/// Edycja autora (etap 9i; wzorzec: `components/modals/authors/EditModal.vue`): nazwa, ASIN, opis,
/// zdjęcie z adresu, dopasowanie w Audible i usunięcie. Tokenem root (`ItemManager`).
struct AuthorEditSheet: View {
    let browser: LibraryBrowser
    let author: AudiobookshelfClient.AuthorDetail
    /// Po zapisie: identyfikator i nazwa autora (inny `id`, gdy serwer połączył dwóch autorów), `nil` po usunięciu.
    let done: (_ result: (id: String, name: String)?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var asin = ""
    @State private var description = ""
    @State private var imageURL = ""
    @AppStorage("author.matchRegion") private var region = "us"
    @State private var status = AdminStatus()
    @State private var confirmMerge = false
    @State private var confirmDelete = false

    private static let regions: [(String, String)] = [
        ("us", "Stany Zjednoczone"), ("uk", "Wielka Brytania"), ("de", "Niemcy"), ("fr", "Francja"), ("it", "Włochy"),
        ("es", "Hiszpania"), ("ca", "Kanada"), ("au", "Australia"), ("in", "Indie"), ("jp", "Japonia"),
    ]

    private var manager: ItemManager { browser.manager }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Form {
            Section {
                TextField("Nazwa", text: $name)
                TextField("ASIN (Audible)", text: $asin)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Opis")
                    TextEditor(text: $description)
                        .font(.body)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                }
            } header: {
                Text("Autor")
            } footer: {
                if trimmedName != author.name, !trimmedName.isEmpty {
                    Text("Nowa nazwa zmieni się we wszystkich książkach tego autora. Jeśli w bibliotece jest już autor o tej nazwie, serwer połączy obu w jednego.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    TextField("Adres zdjęcia (https://…)", text: $imageURL)
                    Button("Ustaw") { Task { await setImage() } }
                        .disabled(status.isBusy || !(imageURL.hasPrefix("http://") || imageURL.hasPrefix("https://")))
                }
                if author.imagePath != nil {
                    Button("Usuń zdjęcie", role: .destructive) { Task { await removeImage() } }
                        .disabled(status.isBusy)
                }
            } header: {
                Text("Zdjęcie")
            } footer: {
                Text("Serwer sam pobiera zdjęcie z podanego adresu.").foregroundStyle(.secondary)
            }

            Section {
                Picker("Sklep Audible", selection: $region) {
                    ForEach(Self.regions, id: \.0) { Text($0.1).tag($0.0) }
                }
                Button("Szukaj w Audible") { Task { await match() } }
                    .disabled(status.isBusy || (trimmedName.isEmpty && asin.isEmpty))
            } header: {
                Text("Dopasowanie")
            } footer: {
                Text("Szuka po ASIN, a bez niego po nazwie. Uzupełnia opis i ASIN; zdjęcie tylko, gdy autor go nie ma albo zmienił się ASIN.")
                    .foregroundStyle(.secondary)
            }

            Section {
                AdminStatusRows(status: status)
                Button("Usuń autora…", role: .destructive) { confirmDelete = true }
                    .disabled(status.isBusy)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Zapisz") { Task { await save() } }
                    .disabled(status.isBusy || trimmedName.isEmpty)
            }
        }
        .confirmationDialog("Usunąć autora „\(author.name)”?", isPresented: $confirmDelete) {
            Button("Usuń autora", role: .destructive) { Task { await delete() } }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Autor zniknie ze wszystkich książek (\(author.libraryItems?.elements.count ?? 0)) i z listy autorów. Książki i pliki zostają.")
        }
        .onAppear {
            name = author.name
            asin = author.asin ?? ""
            description = author.description ?? ""
        }
    }

    private func update() -> AudiobookshelfClient.AuthorUpdate {
        .init(name: trimmedName, description: description.isEmpty ? nil : description, asin: asin.trimmingCharacters(in: .whitespaces).isEmpty ? nil : asin.trimmingCharacters(in: .whitespaces))
    }

    private func save() async {
        let id = author.id
        let update = update()
        var result: AudiobookshelfClient.AuthorChange?
        let ok = await status.run("Zapisywanie…", failure: "Nie udało się zapisać autora") {
            result = try await manager.run { try await $0.updateAuthor(id: id, update, token: $1) }
        }
        guard ok, let result else { return }
        browser.invalidateFilterData()
        done((result.author.id, result.author.name))
        dismiss()
    }

    private func match() async {
        let id = author.id
        let query = trimmedName
        let asin = asin.trimmingCharacters(in: .whitespaces)
        let region = region
        await status.run("Szukanie w Audible…", failure: "Dopasowanie") {
            do {
                let result = try await manager.run { try await $0.matchAuthor(id: id, query: asin.isEmpty ? query : nil, asin: asin.isEmpty ? nil : asin, region: region, token: $1) }
                browser.listening.authorImageChanged(id: id)
                status.notice = result.updated == true ? "Uzupełniono dane z Audible. Zamknij okno, żeby zobaczyć zmiany." : "Audible nie dodał nic nowego."
                if result.updated == true { done((id, author.name)) }
            } catch AudiobookshelfClient.APIError.http(404, _) {
                throw ItemManager.ManageError.invalid("Audible nie zna takiego autora w tym sklepie.")
            }
        }
    }

    private func setImage() async {
        let id = author.id
        let url = imageURL
        await status.run("Pobieranie zdjęcia…", failure: "Nie udało się ustawić zdjęcia") {
            try await manager.run { try await $0.setAuthorImage(id: id, url: url, token: $1) }
            browser.listening.authorImageChanged(id: id)
            status.notice = "Zdjęcie ustawione."
            imageURL = ""
            done((id, author.name))
        }
    }

    private func removeImage() async {
        let id = author.id
        await status.run("Usuwanie zdjęcia…", failure: "Nie udało się usunąć zdjęcia") {
            try await manager.run { try await $0.removeAuthorImage(id: id, token: $1) }
            browser.listening.authorImageChanged(id: id)
            status.notice = "Zdjęcie usunięte."
            done((id, author.name))
        }
    }

    private func delete() async {
        let id = author.id
        let ok = await status.run("Usuwanie…", failure: "Nie udało się usunąć autora") {
            _ = try await manager.run { try await $0.send("DELETE", "api/authors/\(id)", token: $1) }
        }
        guard ok else { return }
        browser.invalidateFilterData()
        done(nil)
        dismiss()
    }
}
