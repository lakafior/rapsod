import SwiftUI

/// Biblioteki na serwerze i dodawanie folderu — wspólne dla okna powitalnego i okna statusu.
struct LibrarySection: View {
    let supervisor: ServerSupervisor
    let account: ServerAccount
    @Environment(\.openWindow) private var openWindow
    @State private var libraryToRemove: AudiobookshelfClient.Library?
    @State private var removing = false
    @State private var removalError: String?

    var body: some View {
        switch account.state {
        case .disconnected:
            Label("Serwer nie działa — biblioteki są niedostępne.", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        case .connecting:
            ProgressView("Łączenie z serwerem…")
                .controlSize(.small)
        case .needsPassword(let reason):
            RootPasswordForm(account: account, reason: reason)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Button("Połącz ponownie") { reconnect() }
            }
        case .ready:
            ready
        }
    }

    @ViewBuilder
    private var ready: some View {
        if account.libraries.isEmpty {
            Text("Na serwerze nie ma jeszcze żadnej biblioteki.")
                .foregroundStyle(.secondary)
        }
        ForEach(account.libraries) { library in
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(library.name)
                    ForEach(library.folders, id: \.self) { folder in
                        Text(folder.fullPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                Button("Usuń bibliotekę „\(library.name)”", systemImage: "trash", role: .destructive) {
                    removalError = nil
                    libraryToRemove = library
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Usuń bibliotekę z serwera (pliki zostają na dysku)")
                .disabled(account.isScanning || removing)
            }
        }
        if let removalError {
            Label(removalError, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        if let scan = account.scan {
            ScanProgressRow(scan: scan) {
                openWindow.bringToFront(id: WebUIWindow.windowID)
            }
        }
        Button("Dodaj folder z audiobookami…") {
            Task {
                guard let folder = await chooseLibraryFolder() else { return }
                await account.addLibrary(folder: folder)
            }
        }
        .disabled(account.isScanning)
        .confirmationDialog(
            "Usunąć bibliotekę „\(libraryToRemove?.name ?? "")”?",
            isPresented: Binding(
                get: { libraryToRemove != nil },
                set: { if !$0 { libraryToRemove = nil } }
            ),
            presenting: libraryToRemove
        ) { library in
            Button("Usuń bibliotekę", role: .destructive) { remove(library) }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in
            Text("Biblioteka zniknie z serwera razem z postępem słuchania, kolekcjami i metadanymi jej pozycji. Pliki w folderze zostaną na dysku nietknięte.")
        }
    }

    private func remove(_ library: AudiobookshelfClient.Library) {
        removing = true
        Task {
            defer { removing = false }
            do {
                try await account.removeLibrary(library)
            } catch {
                removalError = "Nie udało się usunąć biblioteki „\(library.name)”: \(error.localizedDescription)"
            }
        }
    }

    private func reconnect() {
        guard let environment = supervisor.environment, supervisor.state == .running else { return }
        Task { await account.connect(environment: environment) }
    }
}

struct ScanProgressRow: View {
    let scan: ServerAccount.ScanProgress
    let openLibrary: () -> Void

    var body: some View {
        switch scan.phase {
        case .creating:
            ProgressView("Tworzenie biblioteki „\(scan.folder.lastPathComponent)”…")
                .controlSize(.small)
        case .scanning:
            ProgressView("Skanowanie folderu „\(scan.folder.lastPathComponent)”…")
                .controlSize(.small)
        case .finished(let items) where items == 0:
            Label(
                "Biblioteka utworzona, ale skan nie znalazł audiobooków. Sprawdź, czy pliki audio są w podfolderach i czy aplikacja ma dostęp do folderu (Ustawienia systemowe → Prywatność i ochrona).",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        case .finished(let items):
            HStack {
                Label("Zeskanowano: \(Self.itemsText(items)).", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Spacer()
                Button("Otwórz bibliotekę", action: openLibrary)
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    static func itemsText(_ count: Int) -> String {
        let lastTwo = count % 100
        let last = count % 10
        let noun = if count == 1 {
            "pozycja"
        } else if (2...4).contains(last) && !(12...14).contains(lastTwo) {
            "pozycje"
        } else {
            "pozycji"
        }
        return "\(count) \(noun)"
    }
}

/// Formularz hasła roota, gdy w pęku kluczy go brak albo jest nieaktualne.
struct RootPasswordForm: View {
    let account: ServerAccount
    let reason: String

    @State private var username = ServerEnvironment.rootUsername
    @State private var password = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(reason)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Użytkownik", text: $username)
            SecureField("Hasło", text: $password)
                .onSubmit(submit)
            if let error {
                Text(error).foregroundStyle(.red)
            }
            Button("Zaloguj i zapamiętaj w pęku kluczy", action: submit)
                .disabled(username.isEmpty || working)
        }
    }

    private func submit() {
        working = true
        Task {
            defer { working = false }
            do {
                try await account.submit(username: username, password: password)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
