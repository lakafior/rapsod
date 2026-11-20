import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Stan wyszukiwania okładek (żyje z arkuszem, więc przełączanie zakładek go nie gubi).
@MainActor
@Observable
final class CoverSearch {
    var provider = "best"
    var title = ""
    var author = ""
    var results: [String] = []
    var hasSearched = false
}

/// Okładka: plik z dysku, adres, obraz z folderu książki, wyszukiwanie u dostawców, usunięcie.
struct CoverTab: View {
    @Bindable var model: ItemEditorModel
    @State private var urlText = ""
    @State private var confirmRemove = false
    @State private var providers: [AudiobookshelfClient.SearchProvider] = []

    private var search: CoverSearch { model.covers }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                AsyncCover(listening: model.listening, itemID: model.item.id, path: model.item.media.coverPath, size: 180)
                    .frame(width: 180, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(radius: 4, y: 2)
                    .accessibilityIdentifier("cover.current")
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button("Wybierz plik…", systemImage: "folder") { chooseFile() }
                            .accessibilityIdentifier("cover.file")
                        Button("Usuń okładkę", systemImage: "trash", role: .destructive) { confirmRemove = true }
                            .disabled(model.item.media.coverPath == nil)
                            .accessibilityIdentifier("cover.remove")
                    }
                    .disabled(model.isBusy)
                    HStack {
                        TextField("Adres obrazka", text: $urlText, prompt: Text("https://…"))
                            .onSubmit(useURL)
                            .accessibilityIdentifier("cover.url")
                        Button("Użyj adresu", action: useURL)
                            .disabled(!Self.isWebURL(urlText) || model.isBusy)
                            .accessibilityIdentifier("cover.useURL")
                    }
                    if !localImages.isEmpty {
                        Text("Obrazy w folderze książki").font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(localImages, id: \.path) { file in
                                Button {
                                    let path = file.path ?? ""
                                    Task { await model.changeCover("Ustawianie okładki…", failure: "Nie udało się ustawić okładki") { try await $0.setLocalCover(itemID: $1, path: path, token: $2) } }
                                } label: {
                                    RemoteThumbnail(url: URL(filePath: file.path ?? ""), size: 56)
                                }
                                .buttonStyle(.plain)
                                .help(file.filename ?? "")
                                .accessibilityLabel("Ustaw okładkę z pliku \(file.filename ?? "")")
                                .accessibilityIdentifier("cover.local")
                            }
                        }
                    }
                    Text("Obsługiwane: JPEG, PNG, WebP.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Picker("Źródło", selection: Bindable(search).provider) {
                    ForEach(providers) { Text(Self.providerName($0)).tag($0.value) }
                }
                .frame(maxWidth: 260)
                TextField("Tytuł", text: Bindable(search).title).onSubmit(runSearch)
                TextField("Autor", text: Bindable(search).author).onSubmit(runSearch)
                    .frame(maxWidth: 200)
                Button("Szukaj okładek", action: runSearch)
                    .disabled(search.title.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy)
                    .accessibilityIdentifier("cover.search")
            }
            if search.results.isEmpty {
                if search.hasSearched {
                    Text("Brak okładek. Pierwsze zapytanie po przerwie budzi źródła metadanych i może nie zdążyć — spróbuj ponownie albo wybierz inne źródło.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                        ForEach(search.results, id: \.self) { url in
                            Button {
                                Task { await model.changeCover("Pobieranie okładki…", failure: "Nie udało się pobrać okładki") { try await $0.setCover(itemID: $1, url: url, token: $2) } }
                            } label: {
                                RemoteThumbnail(url: URL(string: url), size: 110)
                            }
                            .buttonStyle(.plain)
                            .help("Ustaw tę okładkę\n\(url)")
                            .accessibilityLabel("Ustaw tę okładkę")
                            .accessibilityIdentifier("cover.result")
                            .disabled(model.isBusy)
                        }
                    }
                }
                .accessibilityIdentifier("cover.results")
            }
        }
        .padding(.top, 12)
        .task { await prepare() }
        .confirmationDialog("Usunąć okładkę?", isPresented: $confirmRemove) {
            Button("Usuń okładkę", role: .destructive) {
                Task { await model.changeCover("Usuwanie okładki…", failure: "Nie udało się usunąć okładki") { try await $0.removeCover(itemID: $1, token: $2) } }
            }
        } message: {
            Text("Pozycja straci okładkę; plik obrazu zostaje na dysku.")
        }
    }

    private var localImages: [AudiobookshelfClient.ItemDetail.Media.FileMetadata] {
        (model.item.libraryFiles?.elements ?? []).filter { $0.fileType == "image" && $0.metadata.path != model.item.media.coverPath }.map(\.metadata)
    }

    static func isWebURL(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        return (text.hasPrefix("http://") || text.hasPrefix("https://")) && URL(string: text) != nil
    }

    static func providerName(_ provider: AudiobookshelfClient.SearchProvider) -> String {
        switch provider.value {
        case "best": "Najlepsze (Google, FantLab, Audible)"
        case "all": "Wszystkie"
        default: provider.text
        }
    }

    private func useURL() {
        let url = urlText.trimmingCharacters(in: .whitespaces)
        guard Self.isWebURL(url) else { return }
        Task {
            await model.changeCover("Pobieranie okładki…", failure: "Nie udało się pobrać okładki z adresu") { try await $0.setCover(itemID: $1, url: url, token: $2) }
            if model.message?.isError == false { urlText = "" }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .webP]
        panel.allowsMultipleSelection = false
        panel.message = "Wybierz obraz okładki"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let type = UTType(filenameExtension: url.pathExtension)
        let mime = type?.preferredMIMEType ?? "image/jpeg"
        let filename = url.lastPathComponent
        Task {
            guard let data = try? Data(contentsOf: url) else {
                model.message = .init(text: "Nie udało się odczytać pliku „\(filename)”.", isError: true)
                return
            }
            await model.changeCover("Wysyłanie okładki…", failure: "Nie udało się wysłać okładki") {
                try await $0.uploadCover(itemID: $1, data: data, filename: filename, mimeType: mime, token: $2)
            }
        }
    }

    private func prepare() async {
        if search.title.isEmpty {
            search.title = model.detailsBase.title
            search.author = model.detailsBase.authors.first ?? ""
        }
        guard providers.isEmpty, let loaded = try? await model.manager.loadProviders() else { return }
        providers = loaded.booksCovers
        // Domyślnie dostawca biblioteki (zwykle wbudowane źródła z polskimi okładkami), potem „Najlepsze”.
        if search.provider == "best", let library = model.browser.library?.provider, providers.contains(where: { $0.value == library }) {
            search.provider = library
        }
        if !providers.contains(where: { $0.value == search.provider }) { search.provider = providers.first?.value ?? "google" }
    }

    private func runSearch() {
        let title = search.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let provider = search.provider, author = search.author.trimmingCharacters(in: .whitespaces)
        Task {
            await model.perform("Szukanie okładek…", failure: "Nie udało się wyszukać okładek") {
                let results = try await model.manager.run { try await $0.searchCovers(provider: provider, title: title, author: author, token: $1) }
                search.results = results
                search.hasSearched = true
                return nil
            }
        }
    }
}

/// Miniatura obrazka z adresu (albo pliku), zmniejszana przy dekodowaniu — wyniki wyszukiwania
/// bywają w pełnej rozdzielczości, a w pamięci zostaje tylko miniatura.
struct RemoteThumbnail: View {
    let url: URL?
    let size: CGFloat
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if failed {
                Image(systemName: "photo").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            image = nil
            failed = false
            guard let url, let (data, _) = try? await URLSession.shared.data(from: url) else { failed = true; return }
            image = await CoverCache.thumbnail(data: data, pixels: Int(size * 2))
            failed = image == nil
        }
    }
}
