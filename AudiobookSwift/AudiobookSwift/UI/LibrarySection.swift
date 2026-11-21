import SwiftUI

/// Biblioteki na serwerze i dodawanie folderu — wspólne dla okna powitalnego i podstrony „Biblioteki”.
struct LibrarySection: View {
    let supervisor: ServerSupervisor
    let account: ServerAccount
    /// Skan i dopasowanie istniejących bibliotek (tylko w ustawieniach, nie w oknie powitalnym).
    var tasks: LibraryTasks? = nil
    @Environment(\.openWindow) private var openWindow
    @State private var libraryToRemove: AudiobookshelfClient.Library?
    @State private var libraryToMatch: AudiobookshelfClient.Library?
    @State private var libraryToEdit: AudiobookshelfClient.Library?
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
                    Label(library.name, systemImage: library.mediaType == "podcast" ? "antenna.radiowaves.left.and.right" : "books.vertical")
                        .help(library.mediaType == "podcast" ? "Biblioteka podcastów" : "Biblioteka audiobooków")
                    ForEach(library.folders, id: \.self) { folder in
                        Text(folder.fullPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let tasks, let activity = tasks.activities[library.id] {
                        LibraryActivityRow(activity: activity)
                    }
                }
                Spacer()
                if let tasks {
                    taskMenu(for: library, tasks: tasks)
                    Button("Ustawienia biblioteki „\(library.name)”", systemImage: "slider.horizontal.3") {
                        libraryToEdit = library
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Nazwa, źródło metadanych, skaner, harmonogram skanu i inne ustawienia biblioteki")
                }
                Button("Usuń bibliotekę „\(library.name)”", systemImage: "trash", role: .destructive) {
                    removalError = nil
                    libraryToRemove = library
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Usuń bibliotekę z serwera (pliki zostają na dysku)")
                .disabled(account.isScanning || removing || tasks?.isRunning(library.id) == true)
            }
        }
        if let removalError {
            Label(removalError, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        if let scan = account.scan {
            ScanProgressRow(scan: scan) {
                // Podcasty dodaje się w oknie „Biblioteka” (przycisk „+” w bibliotece podcastów).
                openWindow.bringToFront(id: LibraryWindow.windowID)
            }
        }
        HStack {
            Button("Dodaj folder z audiobookami…") { add(.audiobooks) }
            Button("Dodaj folder z podcastami…") { add(.podcasts) }
        }
        .disabled(account.isScanning)
        .sheet(item: $libraryToEdit) { library in
            LibrarySettingsSheet(account: account, library: library)
        }
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
        .confirmationDialog(
            "Dopasować wszystkie książki w „\(libraryToMatch?.name ?? "")”?",
            isPresented: Binding(
                get: { libraryToMatch != nil },
                set: { if !$0 { libraryToMatch = nil } }
            ),
            presenting: libraryToMatch
        ) { library in
            Button("Dopasuj wszystkie") { tasks?.matchAll(library) }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in
            Text("Serwer wyszuka każdą książkę w domyślnym źródle metadanych tej biblioteki i uzupełni brakujące metadane i okładki. Przy wielu książkach trwa to długo; pojedyncze pozycje wygodniej dopasować w oknie „Biblioteka”.")
        }
    }

    private func taskMenu(for library: AudiobookshelfClient.Library, tasks: LibraryTasks) -> some View {
        Menu {
            Button("Wymuś pełny skan") { tasks.scan(library, force: true) }
            if library.mediaType == "book" {
                Button("Dopasuj wszystkie…") { libraryToMatch = library }
            }
        } label: {
            Text("Skanuj")
        } primaryAction: {
            tasks.scan(library, force: false)
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Skanuj folder biblioteki; strzałka: pełny skan albo dopasowanie wszystkich książek")
        .disabled(tasks.isRunning(library.id) || account.isScanning || removing)
    }

    private func add(_ kind: ServerAccount.LibraryKind) {
        Task {
            guard let folder = await chooseLibraryFolder(for: kind) else { return }
            await account.addLibrary(folder: folder, kind: kind)
        }
    }

    private func remove(_ library: AudiobookshelfClient.Library) {
        removing = true
        Task {
            defer { removing = false }
            do {
                try await account.removeLibrary(library)
                tasks?.forget(library.id)
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

/// Stan ostatniego skanu albo dopasowania biblioteki (pod jej nazwą).
struct LibraryActivityRow: View {
    let activity: LibraryTasks.Activity

    var body: some View {
        Group {
            switch activity.phase {
            case .requested, .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(runningText)
                }
                .foregroundStyle(.secondary)
            case .finished(let results, let canceled):
                Label(finishedText(results, canceled: canceled), systemImage: canceled ? "stop.circle" : "checkmark.circle")
                    .foregroundStyle(canceled ? Color.orange : Color.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
    }

    private var runningText: String {
        switch activity.kind {
        case .scan(let force): force ? "Pełny skan…" : "Skanowanie…"
        case .matchAll: "Dopasowywanie książek…"
        }
    }

    private func finishedText(_ results: AudiobookshelfClient.ServerTask.ScanResults?, canceled: Bool) -> String {
        let (what, done, stopped) = switch activity.kind {
        case .scan: ("Skan", "zakończony", "przerwany")
        case .matchAll: ("Dopasowanie", "zakończone", "przerwane")
        }
        if canceled { return "\(what) \(stopped)." }
        guard let results else { return "\(what) \(done)." }
        var parts: [String] = []
        switch activity.kind {
        case .scan:
            parts.append("dodane: \(results.added ?? 0)")
            parts.append("zmienione: \(results.updated ?? 0)")
            if let missing = results.missing, missing > 0 { parts.append("brakujące: \(missing)") }
        case .matchAll:
            parts.append("zaktualizowane: \(results.updated ?? 0)")
        }
        let elapsed = results.elapsed.map { Self.elapsedText(milliseconds: $0) } ?? ""
        return "\(what) \(done) — " + parts.joined(separator: ", ") + elapsed + "."
    }
}

extension LibraryActivityRow {
    /// „ (12 s)”, „ (3 min 5 s)”; poniżej sekundy nic.
    static func elapsedText(milliseconds: Double) -> String {
        let seconds = Int(milliseconds / 1000)
        guard seconds > 0 else { return "" }
        return seconds < 60 ? " (\(seconds) s)" : " (\(seconds / 60) min \(seconds % 60) s)"
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
        case .finished(let items) where items == 0 && scan.kind == .podcasts:
            HStack {
                Label("Biblioteka podcastów utworzona. Folder jest pusty — podcasty dodasz w bibliotece, wyszukując je lub podając adres RSS.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Spacer()
                Button("Otwórz bibliotekę", action: openLibrary)
            }
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
