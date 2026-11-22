import AppKit
import SwiftUI

/// Czego dotyczy kanał RSS: pozycji, serii albo kolekcji (etap 9g; `Feed.entityType` upstreamu).
struct FeedTarget: Identifiable, Hashable {
    enum Kind: String { case item = "libraryItem", series, collection }
    let kind: Kind
    let id: String
    let title: String

    static func item(_ item: AudiobookshelfClient.ItemDetail) -> Self { .init(kind: .item, id: item.id, title: item.title) }

    var openPath: String {
        switch kind {
        case .item: "api/feeds/item/\(id)/open"
        case .series: "api/feeds/series/\(id)/open"
        case .collection: "api/feeds/collection/\(id)/open"
        }
    }

    /// „tej pozycji”, „tej serii”…
    var noun: String {
        switch kind {
        case .item: "tej pozycji"
        case .series: "książek tej serii"
        case .collection: "książek tej kolekcji"
        }
    }
}

/// Adresy, pod którymi serwer jest widoczny: spoza domu, w sieci lokalnej, ten Mac (kanały RSS, linki).
enum ServerAddresses {
    @MainActor
    static func list(sharing: SharingController?) -> [(url: String, label: String)] {
        var list: [(String, String)] = []
        if let external = sharing?.externalURL { list.append((trim(external), "spoza domu")) }
        if sharing?.isEnabled == true {
            list += (sharing?.localURLs ?? []).map { (trim($0), "sieć lokalna") }
        }
        list.append(("http://\(ServerEnvironment.host):\(ServerEnvironment.port)", "tylko ten Mac"))
        return list
    }

    private static func trim(_ url: URL) -> String {
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

/// Kanał RSS pozycji, serii albo kolekcji (wzorzec: `components/modals/rssfeed/OpenCloseModal.vue`):
/// otwarcie z wyborem adresu serwera, podgląd otwartego kanału z kopiowaniem i zamknięcie. Tokenem root.
struct RSSFeedSheet: View {
    let manager: ItemManager
    let target: FeedTarget
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

    private var addresses: [(url: String, label: String)] { ServerAddresses.list(sharing: sharing) }

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
                    Text("Każdy, kto zna ten adres, może słuchać \(target.noun) w aplikacji do podcastów — bez logowania.").foregroundStyle(.secondary)
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
                    Text("Kanał udostępnia „\(target.title)” jako podcast pod publicznym adresem, bez logowania. Zamkniesz go tutaj albo w Ustawieniach → Aktywność → Kanały RSS.")
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
            feed = try await manager.run { try await $0.feeds(token: $1) }.first { $0.entityType == target.kind.rawValue && $0.entityId == target.id }
        }
        slug = target.id
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
            let opened = try await manager.run { try await $0.openFeed(path: target.openPath, options: options, token: $1) }
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

/// Publiczny link do książki (etap 9i; wzorzec: `components/modals/ShareModal.vue`): strona odtwarzacza
/// bez logowania pod `<adres>/audiobookshelf/share/<końcówka>`, z czasem ważności i opcjonalnym pobieraniem.
/// Tokenem root (upstream: tylko administrator). Stronę odtwarzacza serwuje klient web serwera.
struct ShareLinkSheet: View {
    let manager: ItemManager
    let item: AudiobookshelfClient.ItemDetail
    @Environment(SharingController.self) private var sharing: SharingController?
    @Environment(\.dismiss) private var dismiss

    enum Expiry: String, CaseIterable, Identifiable {
        case never, hour, day, week, month
        var id: String { rawValue }
        var label: String {
            switch self {
            case .never: "nigdy"
            case .hour: "za godzinę"
            case .day: "za dobę"
            case .week: "za tydzień"
            case .month: "za 30 dni"
            }
        }
        var seconds: Double? {
            switch self {
            case .never: nil
            case .hour: 3600
            case .day: 86400
            case .week: 7 * 86400
            case .month: 30 * 86400
            }
        }
    }

    @State private var mediaID: String?
    @State private var share: AudiobookshelfClient.MediaItemShare?
    @State private var loaded = false
    @State private var slug = ""
    @State private var expiry = Expiry.week
    @State private var downloadable = false
    @State private var address = ""
    @State private var status = AdminStatus()

    private var addresses: [(url: String, label: String)] { ServerAddresses.list(sharing: sharing) }

    private func link(_ slug: String) -> String { "\(address)\(ServerEnvironment.routerBasePath)/share/\(slug)" }

    var body: some View {
        Form {
            if let share {
                Section {
                    Picker("Adres serwera", selection: $address) {
                        ForEach(addresses, id: \.url) { Text("\($0.url) (\($0.label))").tag($0.url) }
                    }
                    LabeledContent("Link") {
                        Text(link(share.slug)).textSelection(.enabled).font(.callout.monospaced())
                    }
                    LabeledContent("Wygasa", value: share.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .shortened) } ?? "nigdy")
                    LabeledContent("Pobieranie", value: share.isDownloadable == true ? "dozwolone" : "wyłączone")
                    AdminStatusRows(status: status)
                    HStack {
                        Button("Kopiuj link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link(share.slug), forType: .string)
                            status.notice = "Link skopiowany."
                        }
                        Spacer()
                        Button("Usuń link", role: .destructive) { Task { await remove(share) } }
                    }
                    .disabled(status.isBusy)
                } header: {
                    Text("Link jest aktywny")
                } footer: {
                    Text("Każdy, kto zna link, może słuchać „\(item.title)” w przeglądarce — bez konta.").foregroundStyle(.secondary)
                }
            } else if loaded {
                Section {
                    TextField("Końcówka linku", text: $slug)
                    Picker("Adres serwera", selection: $address) {
                        ForEach(addresses, id: \.url) { Text("\($0.url) (\($0.label))").tag($0.url) }
                    }
                    if address.contains(ServerEnvironment.host) {
                        Label("Ten adres działa tylko na tym Macu. Żeby wysłać link komuś innemu, włącz dostęp spoza domu w Ustawieniach → Udostępnianie.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Picker("Wygasa", selection: $expiry) {
                        ForEach(Expiry.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Pozwól pobrać pliki", isOn: $downloadable)
                    Text("Link: \(link(slug))").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    AdminStatusRows(status: status)
                } header: {
                    Text("Utwórz publiczny link")
                } footer: {
                    Text("Strona z odtwarzaczem tej książki, bez logowania. Postęp słuchania odbiorcy nie trafia na żadne konto.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section { AdminStatusRows(status: status) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(share == nil ? "Anuluj" : "Gotowe") { dismiss() } }
            if share == nil, loaded {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Utwórz link") { Task { await create() } }
                        .disabled(status.isBusy || mediaID == nil || slug.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        address = addresses.first?.url ?? ""
        let id = item.id
        await status.run("Wczytywanie…", failure: "Nie udało się sprawdzić linku") {
            let state = try await manager.run { try await $0.shareState(itemID: id, token: $1) }
            mediaID = state.mediaID
            share = state.share
        }
        // Losowa końcówka jak w web UI — trudna do zgadnięcia.
        slug = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        loaded = true
    }

    private func create() async {
        guard let mediaID else { return }
        let slug = slug.trimmingCharacters(in: .whitespaces)
        let expiresAt = expiry.seconds.map { (Date.now.timeIntervalSince1970 + $0) * 1000 } ?? 0
        let downloadable = downloadable
        await status.run("Tworzenie…", failure: "Nie udało się utworzyć linku") {
            guard slug.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                throw ItemManager.ManageError.invalid("Końcówka linku może zawierać tylko litery, cyfry, „-” i „_”.")
            }
            do {
                share = try await manager.run { try await $0.createShare(mediaID: mediaID, slug: slug, expiresAt: expiresAt.rounded(), downloadable: downloadable, token: $1) }
            } catch AudiobookshelfClient.APIError.http(409, let body) {
                throw ItemManager.ManageError.invalid(body.contains("Slug") ? "Ta końcówka jest już zajęta — wybierz inną." : "Ta książka ma już link.")
            }
        }
    }

    private func remove(_ share: AudiobookshelfClient.MediaItemShare) async {
        await status.run("Usuwanie…", failure: "Nie udało się usunąć linku") {
            try await manager.run { try await $0.deleteShare(id: share.id, token: $1) }
            self.share = nil
        }
    }
}
