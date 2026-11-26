import AudiobookshelfKit
import SwiftUI

/// Okno po upuszczeniu plików albo folderów na ikonę na pasku menu (etap 14d): wgrać je jako
/// książkę (kopia do folderu biblioteki — arkusz wgrywania z 9e/9h rozpoznaje `Autor/Seria/Tytuł`)
/// czy dodać folder w miejscu, w którym leży, jako kolejny folder biblioteki.
struct DropWindow: View {
    static let windowID = "menuBarDrop"
    static let title = "Dodaj do Rapsodu"

    enum Choice: Hashable { case upload, addFolder }

    let account: ServerAccount
    let menuBar: MenuBarModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var choice = Choice.upload
    @State private var libraryID: String?
    @State private var busy = false
    @State private var error: String?

    private var urls: [URL] { menuBar.dropped }
    private var folders: [URL] { menuBar.droppedFolders }
    /// Foldery można dodać do biblioteki tylko wtedy, gdy upuszczono same foldery.
    private var canAddFolder: Bool { !folders.isEmpty && folders.count == urls.count }
    private var isReady: Bool { account.state == .ready && !account.libraries.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFiles: urls.map(\.path)) ?? NSWorkspace.shared.icon(for: .folder))
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline).font(.headline)
                    Text(urls.prefix(4).map(\.lastPathComponent).joined(separator: ", ") + (urls.count > 4 ? "…" : ""))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            if !isReady {
                Label(account.state == .ready ? "Najpierw dodaj bibliotekę w Ustawieniach." : "Serwer nie działa — uruchom go z menu na pasku menu.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Co zrobić?", selection: $choice) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wgraj jako książkę")
                        Text("Pliki zostaną skopiowane do folderu biblioteki. Folder z podfolderami Autor/Seria/Tytuł rozłoży się na kilka książek.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .tag(Choice.upload)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folders.count > 1 ? "Dodaj foldery do biblioteki" : "Dodaj folder do biblioteki")
                        Text(canAddFolder
                             ? "Pliki zostaną na miejscu; serwer przeskanuje folder i będzie śledził zmiany."
                             : "Tylko dla upuszczonych folderów.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .tag(Choice.addFolder)
                    .disabled(!canAddFolder)
                }
                .pickerStyle(.radioGroup)

                if choice == .addFolder {
                    Picker("Biblioteka", selection: $libraryID) {
                        ForEach(account.libraries) { library in
                            Text(library.name).tag(Optional(library.id))
                        }
                    }
                    .fixedSize()
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Anuluj", role: .cancel) { finish() }
                    .keyboardShortcut(.cancelAction)
                Button(choice == .upload ? "Dalej…" : "Dodaj") { perform() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isReady || busy || urls.isEmpty || (choice == .addFolder && libraryID == nil))
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: reset)
        .onChange(of: menuBar.dropRequest) { reset() }
    }

    private var headline: String {
        if canAddFolder { return folders.count == 1 ? "Upuszczono folder" : "Upuszczono foldery: \(folders.count)" }
        return urls.count == 1 ? "Upuszczono plik" : "Upuszczono pliki: \(urls.count)"
    }

    private func reset() {
        choice = .upload
        error = nil
        busy = false
        libraryID = account.libraries.first { $0.mediaType != "podcast" }?.id ?? account.libraries.first?.id
    }

    private func perform() {
        switch choice {
        case .upload:
            menuBar.libraryRequest = .upload(urls)
            finish()
            openWindow.bringToFront(id: LibraryWindow.windowID)
        case .addFolder:
            guard let libraryID else { return }
            busy = true
            error = nil
            Task {
                defer { busy = false }
                let model = LibrarySettingsModel(account: account, libraryID: libraryID)
                await model.load()
                if let failure = model.status.error {
                    error = failure
                    return
                }
                for folder in folders {
                    await model.addFolder(folder)
                    if let failure = model.status.error {
                        error = failure
                        return
                    }
                }
                finish()
            }
        }
    }

    private func finish() {
        menuBar.clearDrop()
        dismissWindow(id: Self.windowID)
    }
}
