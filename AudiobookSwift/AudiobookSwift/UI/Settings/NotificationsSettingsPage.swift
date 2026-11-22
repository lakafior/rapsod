import AudiobookshelfKit
import SwiftUI

/// Powiadomienia (Apprise, `client/pages/config/notifications.vue`) i e-mail (SMTP oraz czytniki
/// e-booków, `client/pages/config/email.vue`), przełączane u góry strony. Hasła trzyma serwer;
/// pola haseł są zamaskowane, a wartości nie trafiają do logów.
struct NotificationsSettingsPage: View {
    enum Tab: String, CaseIterable, Identifiable {
        case notifications = "Powiadomienia"
        case email = "E-mail i czytniki"
        var id: Self { self }
    }

    let models: AppModels
    @State private var tab: Tab = .notifications
    // Modele kart trzymane tutaj, żeby przełączenie karty nie wyrzucało ich (i stanu filtrów) — wracając, karta tylko się odświeża.
    @State private var notificationsModel: NotificationsModel?
    @State private var emailModel: EmailModel?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Widok", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 12)
            switch tab {
            case .notifications:
                AdminPage(account: models.account, title: "Powiadomienia", make: { cachedNotificationsModel() }, load: { await $0.load() }) { model in
                    NotificationsContent(model: model)
                }
            case .email:
                AdminPage(account: models.account, title: "E-mail", make: { cachedEmailModel() }, load: { await $0.load() }) { model in
                    EmailContent(model: model)
                }
            }
        }
    }

    private func cachedNotificationsModel() -> NotificationsModel {
        if let notificationsModel { return notificationsModel }
        let made = NotificationsModel(account: models.account)
        notificationsModel = made
        return made
    }

    private func cachedEmailModel() -> EmailModel {
        if let emailModel { return emailModel }
        let made = EmailModel(account: models.account)
        emailModel = made
        return made
    }
}

// MARK: - Powiadomienia

private struct NotificationsContent: View {
    let model: NotificationsModel
    @State private var url = ""
    @State private var maxFailed = 5
    @State private var maxQueue = 20
    @State private var editing: NotificationDraft?
    @State private var toDelete: AudiobookshelfClient.AppNotification?

    var body: some View {
        Section {
            AdminStatusRows(status: model.status)
            TextField("Adres API Apprise", text: $url, prompt: Text(verbatim: "http://192.168.1.10:8000/notify"))
            Stepper("Wyłącz po nieudanych próbach: \(maxFailed)", value: $maxFailed, in: 1...100)
            Stepper("Najwięcej powiadomień w kolejce: \(maxQueue)", value: $maxQueue, in: 1...1000)
            HStack {
                Spacer()
                Button("Zapisz") { Task { await model.saveServer(url: url, maxFailedAttempts: maxFailed, maxQueue: maxQueue) } }
                    .disabled(model.status.isBusy || !serverChanged)
            }
        } header: {
            Text("Serwer Apprise")
        } footer: {
            Text("Audiobookshelf nie wysyła powiadomień sam: przekazuje je do serwera Apprise (osobny program, np. kontener „caronc/apprise”), który dostarcza je do Discorda, Telegrama, ntfy, poczty itd. Podaj adres jego punktu „/notify”.")
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: resetServer)
        .onChange(of: model.settings) { resetServer() }

        Section {
            if model.settings?.notifications.isEmpty ?? true {
                Text("Brak powiadomień.").foregroundStyle(.secondary)
            }
            ForEach(model.settings?.notifications ?? []) { notification in
                NotificationRow(notification: notification, event: model.event(named: notification.eventName), model: model,
                                edit: { editing = NotificationDraft(notification) }, delete: { toDelete = notification })
            }
            HStack {
                Spacer()
                Button("Nowe powiadomienie…") { editing = NotificationDraft(event: model.events.first) }
                    .disabled(model.status.isBusy || model.events.isEmpty)
            }
        } header: {
            Text("Powiadomienia")
        } footer: {
            if model.settings?.appriseApiUrl == nil {
                Text("Bez adresu serwera Apprise powiadomienia nie są wysyłane.").foregroundStyle(.orange)
            }
        }
        .sheet(item: $editing) { draft in
            NotificationEditor(model: model, draft: draft)
        }
        .confirmationDialog("Usunąć powiadomienie?", item: $toDelete) { notification in
            Button("Usuń", role: .destructive) { Task { await model.delete(notification) } }
            Button("Anuluj", role: .cancel) {}
        }
    }

    private var serverChanged: Bool {
        guard let settings = model.settings else { return false }
        return url.trimmingCharacters(in: .whitespaces) != (settings.appriseApiUrl ?? "")
            || maxFailed != settings.maxFailedAttempts || maxQueue != settings.maxNotificationQueue
    }

    private func resetServer() {
        guard let settings = model.settings else { return }
        url = settings.appriseApiUrl ?? ""
        maxFailed = settings.maxFailedAttempts
        maxQueue = settings.maxNotificationQueue
    }
}

/// Opis zdarzeń po polsku (upstream ma tylko angielskie `description`).
enum NotificationEventText {
    static func title(_ name: String) -> String {
        switch name {
        case "onPodcastEpisodeDownloaded": "Pobrano nowy odcinek podcastu"
        case "onBackupCompleted": "Kopia zapasowa utworzona"
        case "onBackupFailed": "Kopia zapasowa nieudana"
        case "onRSSFeedFailed": "Kanał RSS podcastu nie odpowiada"
        case "onRSSFeedDisabled": "Automatyczne pobieranie wyłączone (błędy kanału)"
        case "onTest": "Zdarzenie próbne"
        default: name
        }
    }
}

private struct NotificationRow: View {
    let notification: AudiobookshelfClient.AppNotification
    let event: AudiobookshelfClient.NotificationEvent?
    let model: NotificationsModel
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(NotificationEventText.title(notification.eventName)).font(.body.weight(.medium))
                    if !notification.enabled { Text("wyłączone").font(.caption).foregroundStyle(.secondary) }
                }
                Text(details).font(.caption).foregroundStyle(notification.lastAttemptFailed == true ? .red : .secondary)
            }
            Spacer()
            Button(notification.enabled ? "Wyłącz" : "Włącz") { Task { await model.setEnabled(notification, !notification.enabled) } }
                .disabled(model.status.isBusy)
            Menu {
                Button("Edytuj…", action: edit)
                Button("Wyślij próbę") { Task { await model.test(notification) } }
                    .disabled(model.settings?.appriseApiUrl == nil)
                Divider()
                Button("Usuń…", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Więcej działań")
            .help("Więcej działań")
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.status.isBusy)
        }
    }

    private var details: String {
        var parts = ["adresy: \(notification.urls.count)"]
        if let libraryID = notification.libraryId, let library = model.libraries.first(where: { $0.id == libraryID }) {
            parts.append("biblioteka: \(library.name)")
        }
        if let fired = notification.lastFiredAt {
            parts.append("ostatnio " + Formats.dateTime(Date(timeIntervalSince1970: fired / 1000)) + (notification.lastAttemptFailed == true ? " (nieudane)" : ""))
        }
        if let count = notification.numTimesFired, count > 0 { parts.append("wysłane \(count)×") }
        return parts.joined(separator: " · ")
    }
}

private struct NotificationDraft: Identifiable {
    let id: String?
    var eventName: String
    var libraryID: String?
    var urls: String
    var title: String
    var body: String
    var enabled: Bool
    var type: String

    init(_ notification: AudiobookshelfClient.AppNotification) {
        id = notification.id
        eventName = notification.eventName
        libraryID = notification.libraryId
        urls = notification.urls.joined(separator: "\n")
        title = notification.titleTemplate
        body = notification.bodyTemplate
        enabled = notification.enabled
        type = notification.type ?? "info"
    }

    init(event: AudiobookshelfClient.NotificationEvent?) {
        id = nil
        eventName = event?.name ?? ""
        libraryID = nil
        urls = ""
        title = event?.defaults?.title ?? ""
        body = event?.defaults?.body ?? ""
        enabled = true
        type = "info"
    }

    var changes: AudiobookshelfClient.NotificationChanges {
        .init(id: id, libraryId: libraryID, eventName: eventName,
              urls: urls.split(whereSeparator: { $0.isNewline || $0 == " " || $0 == "," }).map(String.init),
              titleTemplate: title, bodyTemplate: body, enabled: enabled, type: type)
    }
}

extension NotificationDraft: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct NotificationEditor: View {
    let model: NotificationsModel
    @State private var draft: NotificationDraft
    @Environment(\.dismiss) private var dismiss

    init(model: NotificationsModel, draft: NotificationDraft) {
        self.model = model
        _draft = State(initialValue: draft)
    }

    private var event: AudiobookshelfClient.NotificationEvent? { model.event(named: draft.eventName) }

    var body: some View {
        Form {
            Section {
                Picker("Zdarzenie", selection: $draft.eventName) {
                    ForEach(model.events) { Text(NotificationEventText.title($0.name)).tag($0.name) }
                }
                .onChange(of: draft.eventName) { old, new in
                    // Domyślne teksty nowego zdarzenia, jeśli użytkownik nie zmienił poprzednich.
                    let oldDefaults = model.event(named: old)?.defaults
                    if draft.title.isEmpty || draft.title == oldDefaults?.title { draft.title = model.event(named: new)?.defaults?.title ?? "" }
                    if draft.body.isEmpty || draft.body == oldDefaults?.body { draft.body = model.event(named: new)?.defaults?.body ?? "" }
                    if event?.requiresLibrary != true { draft.libraryID = nil }
                }
                if event?.requiresLibrary == true {
                    Picker("Biblioteka", selection: $draft.libraryID) {
                        Text("Wszystkie").tag(String?.none)
                        ForEach(model.libraries.filter { event?.libraryMediaType == nil || $0.mediaType == event?.libraryMediaType }, id: \.id) {
                            Text($0.name).tag(String?.some($0.id))
                        }
                    }
                }
                TextField("Adresy Apprise", text: $draft.urls, prompt: Text(verbatim: "np. ntfy://temat albo tgram://token/czat"), axis: .vertical)
                    .lineLimit(2...5)
                TextField("Tytuł", text: $draft.title)
                TextField("Treść", text: $draft.body, axis: .vertical).lineLimit(2...6)
                Picker("Rodzaj", selection: $draft.type) {
                    Text("Informacja").tag("info")
                    Text("Sukces").tag("success")
                    Text("Ostrzeżenie").tag("warning")
                    Text("Błąd").tag("failure")
                }
                Toggle("Włączone", isOn: $draft.enabled)
                AdminStatusRows(status: model.status)
            } header: {
                Text(draft.id == nil ? "Nowe powiadomienie" : "Powiadomienie")
            } footer: {
                if let variables = event?.variables, !variables.isEmpty {
                    Text("Adresy Apprise (jeden w wierszu) mogą zawierać tokeny i hasła usług — serwer zapisuje je u siebie. W tytule i treści możesz użyć: " + variables.map { "{{\($0)}}" }.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Zapisz") {
                    Task { if await model.save(id: draft.id, draft.changes) { dismiss() } }
                }
                .disabled(model.status.isBusy)
            }
        }
    }
}

// MARK: - E-mail

private struct EmailContent: View {
    let model: EmailModel
    @State private var draft: AudiobookshelfClient.EmailSettings?
    @State private var editingDevice: DeviceDraft?
    @State private var deviceToDelete: AudiobookshelfClient.EreaderDevice?

    var body: some View {
        if let draft = Binding($draft) {
            Section {
                AdminStatusRows(status: model.status)
                TextField("Serwer SMTP", text: optional(draft.host), prompt: Text(verbatim: "smtp.example.com"))
                TextField("Port", value: draft.port, format: .number.grouping(.never))
                Toggle(isOn: draft.secure) {
                    Text("Szyfrowane połączenie (TLS)")
                    Text("Włącz dla portu 465. Dla 587 i 25 wyłącz — połączenie i tak przejdzie na STARTTLS, jeśli serwer je oferuje.")
                }
                Toggle(isOn: draft.rejectUnauthorized) {
                    Text("Odrzucaj nieważne certyfikaty")
                    Text("Wyłącz tylko dla własnego serwera poczty z certyfikatem bez podpisu zaufanego urzędu.")
                }
                TextField("Użytkownik", text: optional(draft.user))
                SecureField("Hasło", text: optional(draft.pass))
                TextField("Nadawca (From)", text: optional(draft.fromAddress), prompt: Text(verbatim: "Audiobookshelf <ksiazki@example.com>"))
                TextField("Adres do próbnej wiadomości", text: optional(draft.testAddress))
                HStack {
                    Button("Wyślij próbny e-mail") { Task { await model.sendTest() } }
                        .disabled(model.status.isBusy || !model.isConfigured || hasChanges)
                        .help(hasChanges ? "Najpierw zapisz zmiany." : "Serwer wyśle wiadomość na zapisany adres do próby.")
                    Spacer()
                    Button("Przywróć") {
                        model.status.error = nil
                        self.draft = model.settings
                    }
                        .disabled(!hasChanges || model.status.isBusy)
                    Button("Zapisz") {
                        Task {
                            await model.save(draft.wrappedValue)
                            if model.status.error == nil { self.draft = model.settings }
                        }
                    }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!hasChanges || model.status.isBusy)
                }
            } header: {
                Text("Poczta wychodząca (SMTP)")
            } footer: {
                Text("Serwer wysyła e-maile tylko z e-bookami na czytniki (np. Kindle) i próbne wiadomości. Hasło zapisuje serwer w swojej bazie, nie w pęku kluczy.")
                    .foregroundStyle(.secondary)
            }
            devicesSection
        } else {
            Section("E-mail") { AdminStatusRows(status: model.status) }
                .onAppear { draft = model.settings }
                .onChange(of: model.settings) { draft = model.settings }
        }
    }

    private var hasChanges: Bool {
        guard let draft, var settings = model.settings else { return false }
        settings.ereaderDevices = draft.ereaderDevices
        return draft != settings
    }

    private var devices: [AudiobookshelfClient.EreaderDevice] { model.settings?.ereaderDevices ?? [] }

    private var devicesSection: some View {
        Section {
            if devices.isEmpty {
                Text("Brak czytników.").foregroundStyle(.secondary)
            }
            ForEach(devices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.body.weight(.medium))
                        Text("\(device.email) · \(availabilityText(device))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edytuj…") { editingDevice = DeviceDraft(original: device.name, device: device) }
                    Button("Usuń czytnik", systemImage: "trash", role: .destructive) { deviceToDelete = device }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Usuń czytnik")
                }
                .disabled(model.status.isBusy)
            }
            HStack {
                Spacer()
                Button("Dodaj czytnik…") { editingDevice = DeviceDraft(original: nil, device: .init()) }
                    .disabled(model.status.isBusy)
            }
        } header: {
            Text("Czytniki e-booków")
        } footer: {
            Text("E-book pozycji wyślesz na czytnik z menu „Więcej” na jej stronie w oknie „Biblioteka”. Adres nadawcy musi być dopuszczony po stronie czytnika (np. na liście zatwierdzonych adresów Kindle).")
                .foregroundStyle(.secondary)
        }
        .sheet(item: $editingDevice) { draft in
            DeviceEditor(model: model, draft: draft, devices: devices)
        }
        .confirmationDialog("Usunąć czytnik „\(deviceToDelete?.name ?? "")”?", item: $deviceToDelete) { device in
            Button("Usuń", role: .destructive) { Task { _ = await model.saveDevices(devices.filter { $0.name != device.name }) } }
            Button("Anuluj", role: .cancel) {}
        }
    }

    private func availabilityText(_ device: AudiobookshelfClient.EreaderDevice) -> String {
        switch device.availabilityOption {
        case "userOrUp": "dla użytkowników i administratorów"
        case "guestOrUp": "dla wszystkich kont"
        case "specificUsers": "dla wybranych: " + device.users.compactMap { id in model.users.first { $0.id == id }?.username }.joined(separator: ", ")
        default: "tylko dla administratorów"
        }
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

private struct DeviceDraft: Identifiable {
    let id = UUID()
    let original: String?
    var device: AudiobookshelfClient.EreaderDevice
}

private struct DeviceEditor: View {
    let model: EmailModel
    @State private var draft: DeviceDraft
    let devices: [AudiobookshelfClient.EreaderDevice]
    @Environment(\.dismiss) private var dismiss

    init(model: EmailModel, draft: DeviceDraft, devices: [AudiobookshelfClient.EreaderDevice]) {
        self.model = model
        _draft = State(initialValue: draft)
        self.devices = devices
    }

    var body: some View {
        Form {
            Section {
                TextField("Nazwa", text: $draft.device.name, prompt: Text(verbatim: "np. Kindle Ani"))
                TextField("Adres e-mail czytnika", text: $draft.device.email, prompt: Text(verbatim: "nazwa@kindle.com"))
                Picker("Dostępny dla", selection: $draft.device.availabilityOption) {
                    Text("Administratorów").tag("adminOrUp")
                    Text("Użytkowników i administratorów").tag("userOrUp")
                    Text("Wszystkich kont (także gości)").tag("guestOrUp")
                    Text("Wybranych kont").tag("specificUsers")
                }
                if draft.device.availabilityOption == "specificUsers" {
                    ForEach(model.users) { user in
                        Toggle(user.username, isOn: Binding(
                            get: { draft.device.users.contains(user.id) },
                            set: { on in
                                draft.device.users.removeAll { $0 == user.id }
                                if on { draft.device.users.append(user.id) }
                            }
                        ))
                    }
                }
                AdminStatusRows(status: model.status)
            } header: {
                Text(draft.original == nil ? "Nowy czytnik" : "Czytnik")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Zapisz") {
                    var device = draft.device
                    device.name = device.name.trimmingCharacters(in: .whitespaces)
                    device.email = device.email.trimmingCharacters(in: .whitespaces)
                    if device.availabilityOption != "specificUsers" { device.users = [] }
                    var list = devices
                    if let original = draft.original, let index = list.firstIndex(where: { $0.name == original }) {
                        list[index] = device
                    } else {
                        list.append(device)
                    }
                    Task { if await model.saveDevices(list) { dismiss() } }
                }
                .disabled(model.status.isBusy || (draft.device.availabilityOption == "specificUsers" && draft.device.users.isEmpty))
            }
        }
    }
}
