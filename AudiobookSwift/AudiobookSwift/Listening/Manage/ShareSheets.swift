import AppKit
import SwiftUI

/// Kanał RSS pozycji (wzorzec: `components/modals/rssfeed/OpenCloseModal.vue`): otwarcie
/// z wyborem adresu serwera, podgląd otwartego kanału z kopiowaniem i zamknięcie. Tokenem root.
struct RSSFeedSheet: View {
    let manager: ItemManager
    let item: AudiobookshelfClient.ItemDetail
    @Environment(SharingController.self) private var sharing: SharingController?
    @Environment(\.dismiss) private var dismiss

    @State private var feed: AudiobookshelfClient.Feed?
    @State private var loaded = false
    @State private var slug = ""
    @State private var address = ""
    @State private var preventIndexing = true
    @State private var ownerName = ""
    @State private var ownerEmail = ""
    @State private var status = AdminStatus()

    /// Adresy, pod którymi kanał może być widoczny: spoza domu, w sieci lokalnej, ten Mac.
    private var addresses: [(url: String, label: String)] {
        var list: [(String, String)] = []
        if let external = sharing?.externalURL { list.append((Self.trim(external), "spoza domu")) }
        if sharing?.isEnabled == true {
            list += (sharing?.localURLs ?? []).map { (Self.trim($0), "sieć lokalna") }
        }
        list.append(("http://\(ServerEnvironment.host):\(ServerEnvironment.port)", "tylko ten Mac"))
        return list
    }

    private static func trim(_ url: URL) -> String {
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    var body: some View {
        Form {
            if let feed {
                Section {
                    LabeledContent("Adres kanału") {
                        Text(feed.url?.absoluteString ?? "—").textSelection(.enabled).font(.callout.monospaced())
                    }
                    if feed.meta?.preventIndexing == false {
                        Text("Kanał jest widoczny dla katalogów podcastów i wyszukiwarek.").foregroundStyle(.secondary)
                    }
                    AdminStatusRows(status: status)
                    HStack {
                        Button("Kopiuj adres") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(feed.url?.absoluteString ?? "", forType: .string)
                            status.notice = "Adres skopiowany."
                        }
                        Spacer()
                        Button("Zamknij kanał", role: .destructive) { Task { await close(feed) } }
                    }
                    .disabled(status.isBusy)
                } header: {
                    Text("Kanał RSS jest otwarty")
                } footer: {
                    Text("Każdy, kto zna ten adres, może słuchać tej pozycji w aplikacji do podcastów — bez logowania.").foregroundStyle(.secondary)
                }
            } else if loaded {
                Section {
                    TextField("Końcówka adresu", text: $slug)
                    Picker("Adres serwera", selection: $address) {
                        ForEach(addresses, id: \.url) { Text("\($0.url) (\($0.label))").tag($0.url) }
                    }
                    if address.contains(ServerEnvironment.host) {
                        Label("Ten adres działa tylko na tym Macu. Żeby słuchać na telefonie, włącz udostępnianie w sieci albo dostęp spoza domu w Ustawieniach → Udostępnianie.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("Ukryj przed katalogami podcastów i wyszukiwarkami", isOn: $preventIndexing)
                    TextField("Właściciel (opcjonalnie)", text: $ownerName)
                    TextField("E-mail właściciela (opcjonalnie)", text: $ownerEmail)
                    Text("Adres kanału: \(address)/feed/\(slug)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    AdminStatusRows(status: status)
                } header: {
                    Text("Otwórz kanał RSS")
                } footer: {
                    Text("Kanał udostępnia „\(item.title)” jako podcast pod publicznym adresem, bez logowania. Zamkniesz go tutaj albo w Ustawieniach → Aktywność → Kanały RSS.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section { AdminStatusRows(status: status) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(feed == nil ? "Anuluj" : "Gotowe") { dismiss() } }
            if feed == nil, loaded {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Otwórz kanał") { Task { await open() } }
                        .disabled(status.isBusy || slug.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        await status.run("Wczytywanie…", failure: "Nie udało się sprawdzić kanałów") {
            feed = try await manager.run { try await $0.feeds(token: $1) }.first { $0.entityType == "libraryItem" && $0.entityId == item.id }
        }
        slug = item.id
        address = addresses.first?.url ?? ""
        loaded = true
    }

    private func open() async {
        let slug = slug.trimmingCharacters(in: .whitespaces)
        await status.run("Otwieranie…", failure: "Nie udało się otworzyć kanału") {
            guard slug.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                throw ItemManager.ManageError.invalid("Końcówka adresu może zawierać tylko litery, cyfry, „-” i „_”.")
            }
            var options = AudiobookshelfClient.FeedOptions(serverAddress: address, slug: slug)
            options.metadataDetails.preventIndexing = preventIndexing
            options.metadataDetails.ownerName = ownerName.isEmpty ? nil : ownerName
            options.metadataDetails.ownerEmail = ownerEmail.isEmpty ? nil : ownerEmail
            let opened = try await manager.run { try await $0.openFeed(itemID: item.id, options: options, token: $1) }
            // Odpowiedź (`toOldJSONMinified`) nie ma `serverAddress`, a `feedUrl` jest względny.
            feed = try await manager.run { try await $0.feeds(token: $1) }.first { $0.id == opened.id } ?? opened
        }
    }

    private func close(_ feed: AudiobookshelfClient.Feed) async {
        await status.run("Zamykanie…", failure: "Nie udało się zamknąć kanału") {
            try await manager.run { try await $0.closeFeed(id: feed.id, token: $1) }
            self.feed = nil
        }
    }
}

/// Wysłanie e-booka pozycji e-mailem na czytnik (`POST /api/emails/send-ebook-to-device`).
struct SendEbookSheet: View {
    let manager: ItemManager
    let item: AudiobookshelfClient.ItemDetail
    let openSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var settings: AudiobookshelfClient.EmailSettings?
    @State private var device = ""
    @State private var status = AdminStatus()
    @State private var sent = false

    var body: some View {
        Form {
            Section {
                if let settings {
                    if (settings.host ?? "").isEmpty {
                        Label("Serwer nie ma ustawionej poczty wychodzącej (SMTP).", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else if settings.ereaderDevices.isEmpty {
                        Label("Nie ma żadnego czytnika.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        Picker("Czytnik", selection: $device) {
                            ForEach(settings.ereaderDevices) { Text("\($0.name) (\($0.email))").tag($0.name) }
                        }
                        if let file = item.media.ebookFile?.metadata?.filename {
                            LabeledContent("Plik", value: file)
                        }
                    }
                }
                AdminStatusRows(status: status)
                if settings?.host?.isEmpty ?? true || settings?.ereaderDevices.isEmpty ?? false {
                    if settings != nil {
                        Button("Otwórz Ustawienia → Powiadomienia i e-mail") { openSettings(); dismiss() }
                    }
                }
            } header: {
                Text("Wyślij e-book na czytnik")
            } footer: {
                Text("Serwer wyśle plik e-booka „\(item.title)” e-mailem na adres czytnika.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(sent ? "Gotowe" : "Anuluj") { dismiss() } }
            if !sent {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Wyślij") { Task { await send() } }
                        .disabled(status.isBusy || device.isEmpty)
                }
            }
        }
        .task {
            await status.run("Wczytywanie…", failure: "Nie udało się wczytać czytników") {
                let loaded = try await manager.run { try await $0.emailSettings(token: $1) }
                settings = loaded
                device = loaded.ereaderDevices.first?.name ?? ""
            }
        }
    }

    private func send() async {
        let device = device
        let ok = await status.run("Wysyłanie…", failure: "Nie udało się wysłać e-booka") {
            try await manager.run { try await $0.sendEbook(itemID: item.id, deviceName: device, token: $1) }
            status.notice = "Wysłano na „\(device)”."
        }
        if ok { sent = true }
    }
}
