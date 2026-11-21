import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Kopie zapasowe: lista, tworzenie, przywracanie, wgrywanie z pliku i automat
/// (wzorzec: `client/pages/config/backups.vue` i `BackupsTable.vue` upstreamu).
struct BackupsSettingsPage: View {
    let models: AppModels
    @State private var model: BackupsModel?

    var body: some View {
        SettingsForm {
            if models.account.state == .ready, let model {
                BackupsContent(model: model, account: models.account)
            } else {
                Section("Kopie zapasowe") {
                    AdminUnavailableRow(account: models.account)
                }
            }
        }
        .task(id: models.account.state) {
            guard models.account.state == .ready else { return }
            let model = model ?? BackupsModel(account: models.account)
            self.model = model
            await model.load()
        }
    }
}

/// Wiersz zamiast treści podstrony administracyjnej, gdy konto root nie działa.
struct AdminUnavailableRow: View {
    let account: ServerAccount

    var body: some View {
        switch account.state {
        case .connecting:
            ProgressView("Łączenie z serwerem…").controlSize(.small)
        case .needsPassword:
            Text("Wymaga konta root — podaj jego hasło na podstronie „Konta”.").foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case .disconnected, .ready:
            Text("Dostępne, gdy serwer działa.").foregroundStyle(.secondary)
        }
    }
}

private struct BackupsContent: View {
    @Bindable var model: BackupsModel
    let account: ServerAccount
    @State private var backupToRestore: AudiobookshelfClient.Backup?
    @State private var backupToDelete: AudiobookshelfClient.Backup?

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
            }
            if model.backups.isEmpty {
                Text(model.isLoading ? "Wczytywanie…" : "Nie ma jeszcze żadnej kopii zapasowej.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.backups) { backup in
                BackupRow(
                    backup: backup,
                    operation: model.operation,
                    restore: { backupToRestore = backup },
                    delete: { backupToDelete = backup }
                )
            }
            HStack {
                if let operation = model.operation {
                    ProgressView().controlSize(.small)
                    Text(Self.progressText(operation)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Wgraj z pliku…", action: chooseUpload)
                Button("Utwórz kopię teraz") { Task { await model.create() } }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(model.operation != nil)
        } header: {
            Text("Kopie zapasowe")
        } footer: {
            Text("Kopia zawiera bazę serwera (konta, biblioteki, postęp słuchania, kolekcje) oraz okładki i metadane pozycji i autorów — bez plików audio. Gdy kopii jest więcej, niż każe trzymać ustawienie poniżej, nowa kopia usuwa najstarszą.")
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Przywrócić stan z \(backupToRestore.map(BackupsModel.dateText) ?? "")?",
            isPresented: Binding(get: { backupToRestore != nil }, set: { if !$0 { backupToRestore = nil } }),
            presenting: backupToRestore
        ) { backup in
            Button("Przywróć i nadpisz obecne dane", role: .destructive) {
                Task { await model.restore(backup) }
            }
            Button("Anuluj", role: .cancel) {}
        } message: { backup in
            Text("Obecna baza serwera zostanie zastąpiona stanem z kopii (\(BackupsModel.dateText(backup))): konta użytkowników i ich hasła, biblioteki, postęp słuchania, zakładki, kolekcje, playlisty oraz metadane i okładki pozycji. Wszystko, co zmieniło się od tamtej pory, zniknie bez możliwości cofnięcia — chyba że najpierw utworzysz kopię obecnego stanu. Pliki audio na dysku zostają nietknięte. Odtwarzanie się zatrzyma, a aplikacja połączy się z serwerem od nowa.")
        }
        .confirmationDialog(
            "Usunąć kopię z \(backupToDelete.map(BackupsModel.dateText) ?? "")?",
            isPresented: Binding(get: { backupToDelete != nil }, set: { if !$0 { backupToDelete = nil } }),
            presenting: backupToDelete
        ) { backup in
            Button("Usuń kopię", role: .destructive) { Task { await model.delete(backup) } }
            Button("Anuluj", role: .cancel) {}
        } message: { backup in
            Text("Plik „\(backup.filename)” zostanie usunięty z dysku.")
        }

        if let settings = model.settings {
            BackupScheduleSection(model: model, settings: settings)
        }

        Section("Folder kopii") {
            if let location = model.location {
                LabeledContent("Folder") {
                    Text(location)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            }
            if model.locationFromEnvironment {
                Text("Folder jest ustawiony zmienną środowiskową BACKUP_PATH i nie da się go tu zmienić.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Pokaż w Finderze") {
                    if let location = model.location {
                        NSWorkspace.shared.open(URL(fileURLWithPath: location, isDirectory: true))
                    }
                }
                .disabled(model.location == nil)
                Button("Zmień…", action: chooseLocation)
                    .disabled(model.locationFromEnvironment || model.operation != nil)
            }
        }
    }

    private static func progressText(_ operation: BackupsModel.Operation) -> String {
        switch operation {
        case .creating: "Tworzenie kopii…"
        case .uploading: "Wgrywanie kopii…"
        case .restoring: "Przywracanie kopii — serwer podmienia bazę…"
        case .deleting: "Usuwanie kopii…"
        case .savingSettings: "Zapisywanie ustawień…"
        case .changingPath: "Zmiana folderu kopii…"
        }
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.title = "Wybierz kopię zapasową audiobookshelf"
        panel.prompt = "Wgraj"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: "audiobookshelf") {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.upload(url) }
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.title = "Folder kopii zapasowych"
        panel.prompt = "Wybierz"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let location = model.location {
            panel.directoryURL = URL(fileURLWithPath: location, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.changeLocation(to: url) }
    }
}

private struct BackupRow: View {
    let backup: AudiobookshelfClient.Backup
    let operation: BackupsModel.Operation?
    let restore: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(BackupsModel.dateText(backup))
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if operation == .restoring(backup.id) || operation == .deleting(backup.id) {
                ProgressView().controlSize(.small)
            }
            Button("Przywróć…", action: restore)
                .disabled(operation != nil || backup.serverVersion == nil)
                .help(backup.serverVersion == nil ? "Kopia sprzed wersji 2.0 — nie da się jej przywrócić" : "Zastąp obecne dane serwera stanem z tej kopii")
            Button("Pokaż w Finderze", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: backup.fullPath)])
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Pokaż plik kopii w Finderze")
            Button("Usuń kopię", systemImage: "trash", role: .destructive, action: delete)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Usuń plik kopii")
                .disabled(operation != nil)
        }
    }

    private var details: String {
        var parts: [String] = []
        if let size = backup.fileSize { parts.append(size.formatted(.byteCount(style: .file))) }
        if let version = backup.serverVersion { parts.append("serwer \(version)") }
        parts.append(backup.filename)
        return parts.joined(separator: " · ")
    }
}

/// Automat kopii: harmonogram, liczba trzymanych kopii, limit rozmiaru.
private struct BackupScheduleSection: View {
    let model: BackupsModel
    let settings: AudiobookshelfClient.BackupSettings

    @State private var choice: BackupScheduleChoice = .disabled
    @State private var keep = 2
    @State private var maxSize = 1.0

    private enum Mode: Hashable { case disabled, daily, weekly, custom }

    var body: some View {
        Section {
            if choice == .disabled {
                HStack {
                    Label("Automatyczne kopie są wyłączone.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Włącz codziennie o 1:30") {
                        save(.daily(hour: 1, minute: 30))
                    }
                    .disabled(model.operation != nil)
                }
            }
            Picker("Harmonogram", selection: modeBinding) {
                Text("Wyłączony").tag(Mode.disabled)
                Text("Codziennie").tag(Mode.daily)
                Text("Co tydzień").tag(Mode.weekly)
                if case .custom = choice { Text("Własny (cron)").tag(Mode.custom) }
            }
            if case .weekly(let weekday, _, _) = choice {
                Picker("Dzień", selection: Binding(
                    get: { weekday },
                    set: { if case .weekly(_, let hour, let minute) = choice { choice = .weekly(weekday: $0, hour: hour, minute: minute) } }
                )) {
                    ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { day in
                        Text(Self.weekdayName(day)).tag(day)
                    }
                }
            }
            if let time = timeBinding {
                DatePicker("Godzina", selection: time, displayedComponents: .hourAndMinute)
            }
            if case .custom(let expression) = choice {
                LabeledContent("Wyrażenie cron", value: expression)
                Text("Harmonogram ustawiony w web UI. Zostanie bez zmian, dopóki nie wybierzesz innego.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Stepper(value: $keep, in: 1...99) {
                LabeledContent("Trzymaj kopii", value: "\(keep)")
            }
            LabeledContent("Limit rozmiaru kopii") {
                HStack(spacing: 4) {
                    TextField("Limit", value: $maxSize, format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Text("GB")
                }
            }
            HStack {
                Text("0 GB = bez limitu. Kopia większa od limitu jest przerywana i usuwana.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cofnij zmiany") { reset() }
                    .disabled(!hasChanges)
                Button("Zapisz") { save(choice) }
                    .disabled(!hasChanges || model.operation != nil)
            }
        } header: {
            Text("Automatyczne kopie")
        } footer: {
            Text("Kopie robi serwer, gdy działa (aplikacja na pasku menu). Godzina jest czasem tego Maca.")
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: reset)
        .onChange(of: settings) { reset() }
    }

    private var hasChanges: Bool {
        choice.schedule != settings.backupSchedule || keep != settings.backupsToKeep || maxSize != settings.maxBackupSize
    }

    private func reset() {
        choice = BackupScheduleChoice(settings.backupSchedule)
        keep = min(max(settings.backupsToKeep, 1), 99)
        maxSize = settings.maxBackupSize
    }

    private func save(_ choice: BackupScheduleChoice) {
        let schedule = choice.schedule
        Task { await model.updateSettings(schedule: schedule, backupsToKeep: keep, maxBackupSize: maxSize) }
    }

    private var mode: Mode {
        switch choice {
        case .disabled: .disabled
        case .daily: .daily
        case .weekly: .weekly
        case .custom: .custom
        }
    }

    private var modeBinding: Binding<Mode> {
        Binding(get: { mode }, set: { newMode in
            let (hour, minute) = currentTime ?? (1, 30)
            switch newMode {
            case .disabled: choice = .disabled
            case .daily: choice = .daily(hour: hour, minute: minute)
            case .weekly: choice = .weekly(weekday: 1, hour: hour, minute: minute)
            case .custom: choice = BackupScheduleChoice(settings.backupSchedule)
            }
        })
    }

    private var currentTime: (Int, Int)? {
        switch choice {
        case .daily(let hour, let minute), .weekly(_, let hour, let minute): (hour, minute)
        case .disabled, .custom: nil
        }
    }

    private var timeBinding: Binding<Date>? {
        guard let (hour, minute) = currentTime else { return nil }
        return Binding(
            get: { Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                let hour = parts.hour ?? 0
                let minute = parts.minute ?? 0
                switch choice {
                case .daily: choice = .daily(hour: hour, minute: minute)
                case .weekly(let weekday, _, _): choice = .weekly(weekday: weekday, hour: hour, minute: minute)
                case .disabled, .custom: break
                }
            }
        )
    }

    private static func weekdayName(_ cronDay: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "pl_PL")
        return calendar.standaloneWeekdaySymbols[cronDay % 7]
    }
}
