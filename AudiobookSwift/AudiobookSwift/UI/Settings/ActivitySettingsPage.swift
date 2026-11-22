import AppKit
import SwiftUI

/// Aktywność: sesje słuchania (`client/pages/config/sessions.vue`) i otwarte kanały RSS
/// (`client/pages/config/rss-feeds.vue`), przełączane u góry strony.
struct ActivitySettingsPage: View {
    enum Tab: String, CaseIterable, Identifiable {
        case sessions = "Sesje słuchania"
        case feeds = "Kanały RSS"
        var id: Self { self }
    }

    let models: AppModels
    @State private var tab: Tab = .sessions
    // Modele kart trzymane tutaj, żeby przełączenie karty nie wyrzucało ich (i stanu filtrów) — wracając, karta tylko się odświeża.
    @State private var sessionsModel: SessionsModel?
    @State private var feedsModel: FeedsModel?

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
            case .sessions:
                AdminPage(account: models.account, title: "Sesje słuchania", make: { cachedSessionsModel() }, load: { await $0.load() }) { model in
                    SessionsContent(model: model)
                }
            case .feeds:
                AdminPage(account: models.account, title: "Kanały RSS", make: { cachedFeedsModel() }, load: { await $0.load() }) { model in
                    FeedsContent(model: model)
                }
            }
        }
    }

    private func cachedSessionsModel() -> SessionsModel {
        if let sessionsModel { return sessionsModel }
        let made = SessionsModel(account: models.account)
        sessionsModel = made
        return made
    }

    private func cachedFeedsModel() -> FeedsModel {
        if let feedsModel { return feedsModel }
        let made = FeedsModel(account: models.account)
        feedsModel = made
        return made
    }
}

// MARK: - Sesje

private struct SessionsContent: View {
    @Bindable var model: SessionsModel
    @State private var details: AudiobookshelfClient.ListeningSession?
    @State private var confirmDelete: [String]?

    var body: some View {
        Section {
            if model.open.isEmpty {
                Text("Nikt teraz nie słucha.").foregroundStyle(.secondary)
            }
            ForEach(model.open) { session in
                SessionRow(session: session, isThisMac: model.isThisMac(session), live: true) {
                    Button("Zamknij") { Task { await model.close(session) } }
                        .disabled(model.status.isBusy)
                        .help("Zamyka sesję na serwerze i zapisuje ją w historii. Odtwarzacz zapisze dalej sam postęp.")
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { details = session }
                .contextMenu {
                    Button("Pokaż szczegóły") { details = session }
                }
                .accessibilityAction(named: "Pokaż szczegóły") { details = session }
            }
        } header: {
            HStack {
                Text("Otwarte teraz")
                Spacer()
                Button("Odśwież") { Task { await model.load() } }
                    .buttonStyle(.borderless)
                    .disabled(model.status.isBusy)
            }
        }

        Section {
            AdminStatusRows(status: model.status)
            Picker("Użytkownik", selection: $model.userFilter) {
                Text("Wszyscy").tag(String?.none)
                ForEach(model.users) { Text($0.username).tag(String?.some($0.id)) }
            }
            .onChange(of: model.userFilter) {
                model.pageIndex = 0
                Task { await model.load() }
            }
            if let page = model.page {
                if page.sessions.isEmpty {
                    Text("Brak zapisanych sesji.").foregroundStyle(.secondary)
                }
                ForEach(page.sessions) { session in
                    HStack {
                        Toggle("Zaznacz", isOn: Binding(
                            get: { model.selection.contains(session.id) },
                            set: { if $0 { model.selection.insert(session.id) } else { model.selection.remove(session.id) } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        SessionRow(session: session, isThisMac: model.isThisMac(session), live: false) {
                            Button("Szczegóły") { details = session }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    Button("Usuń zaznaczone (\(model.selection.count))", role: .destructive) { confirmDelete = Array(model.selection) }
                        .disabled(model.selection.isEmpty || model.status.isBusy)
                    Spacer()
                    Text(pageText(page)).foregroundStyle(.secondary).monospacedDigit()
                    Button("Poprzednia strona", systemImage: "chevron.left") { go(-1) }
                        .labelStyle(.iconOnly)
                        .disabled(model.pageIndex == 0 || model.status.isBusy)
                        .help("Poprzednia strona")
                    Button("Następna strona", systemImage: "chevron.right") { go(1) }
                        .labelStyle(.iconOnly)
                        .disabled(model.pageIndex + 1 >= page.numPages || model.status.isBusy)
                        .help("Następna strona")
                }
            }
        } header: {
            Text("Historia")
        } footer: {
            Text("Każde słuchanie na dowolnym urządzeniu to sesja: ile i gdzie słuchano. Z sesji liczą się statystyki słuchania; postęp książek jest zapisany osobno i usunięcie sesji go nie zmienia.")
                .foregroundStyle(.secondary)
        }
        .sheet(item: $details) { session in
            SessionDetailsSheet(session: session, isThisMac: model.isThisMac(session)) { delete in
                details = nil
                if delete { confirmDelete = [session.id] }
            }
        }
        .confirmationDialog(confirmDelete?.count == 1 ? "Usunąć sesję?" : "Usunąć \(confirmDelete?.count ?? 0) sesje?",
                            item: $confirmDelete) { ids in
            Button("Usuń", role: .destructive) { Task { await model.delete(ids: ids) } }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in
            Text("Sesje znikną z historii i ze statystyk słuchania. Otwarta sesja zostanie zamknięta bez zapisu.")
        }
    }

    private func pageText(_ page: AudiobookshelfClient.SessionPage) -> String {
        guard page.total > 0 else { return "" }
        let first = page.page * page.itemsPerPage + 1
        let last = min(page.total, first + page.sessions.count - 1)
        return "\(first)–\(last) z \(page.total)"
    }

    private func go(_ delta: Int) {
        model.pageIndex += delta
        Task { await model.load() }
    }
}

private struct SessionRow<Trailing: View>: View {
    let session: AudiobookshelfClient.ListeningSession
    let isThisMac: Bool
    let live: Bool
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.displayTitle ?? "—").font(.body.weight(.medium)).lineLimit(1)
                    if isThisMac {
                        Text("ten Mac").font(.caption).padding(.horizontal, 5).background(.quaternary, in: Capsule())
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            trailing()
        }
    }

    private var subtitle: String {
        var parts = [session.user?.username ?? "konto usunięte"]
        if let device = session.deviceInfo?.summary, !device.isEmpty { parts.append(device) }
        parts.append("słuchano \(Formats.duration(session.timeListening))")
        if let date = live ? session.started : session.updated {
            parts.append((live ? "od " : "") + Formats.dateTime(date))
        }
        return parts.joined(separator: " · ")
    }
}

private struct SessionDetailsSheet: View {
    let session: AudiobookshelfClient.ListeningSession
    let isThisMac: Bool
    let close: (_ delete: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.displayTitle ?? "Sesja").font(.headline)
            Form {
                row("Autor", session.displayAuthor)
                row("Użytkownik", session.user?.username ?? "konto usunięte")
                row("Rozpoczęta", session.started.map(Formats.dateTime))
                row("Ostatnia aktualizacja", session.updated.map(Formats.dateTime))
                row("Czas słuchania", Formats.duration(session.timeListening))
                row("Pozycja", "od \(Formats.duration(session.startTime)) do \(Formats.duration(session.currentTime)) z \(Formats.duration(session.duration))")
                row("Sposób odtwarzania", session.playMethodText)
                row("Odtwarzacz", session.mediaPlayer)
                row("Urządzenie", (session.deviceInfo?.summary).flatMap { $0.isEmpty ? nil : $0 }.map { isThisMac ? "\($0) (ten Mac)" : $0 })
                row("Adres IP", session.deviceInfo?.ipAddress)
                row("Wersja serwera", session.serverVersion)
                row("Identyfikator", session.id)
            }
            .formStyle(.grouped)
        }
        .padding(20)
        .frame(width: 520, height: 520)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("Usuń…", role: .destructive) { close(true) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Zamknij") { close(false) }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label) { Text(value).textSelection(.enabled) }
        }
    }
}

// MARK: - Kanały RSS

private struct FeedsContent: View {
    let model: FeedsModel
    @State private var feedToClose: AudiobookshelfClient.Feed?

    var body: some View {
        Section {
            AdminStatusRows(status: model.status)
            if model.feeds.isEmpty, model.isLoaded {
                Text("Żaden kanał nie jest otwarty.").foregroundStyle(.secondary)
            }
            ForEach(model.feeds) { feed in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feed.meta?.title ?? feed.slug ?? feed.id).font(.body.weight(.medium))
                        if let url = feed.url {
                            Text(url.absoluteString).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        }
                        Text(details(feed)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = feed.url {
                        Button("Kopiuj adres kanału", systemImage: "doc.on.doc") {
                            NSPasteboard.copy(url.absoluteString)
                        }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Kopiuj adres kanału")
                    }
                    Button("Zamknij…") { feedToClose = feed }
                        .disabled(model.status.isBusy)
                }
            }
        } header: {
            HStack {
                Text("Otwarte kanały RSS")
                Spacer()
                Button("Odśwież") { Task { await model.load() } }
                    .buttonStyle(.borderless)
                    .disabled(model.status.isBusy)
            }
        } footer: {
            Text("Kanał RSS udostępnia książkę albo podcast jako podcast pod publicznym adresem — bez logowania, dla każdego, kto zna adres. Kanał dla książki otwierasz z menu „Więcej” na jej stronie w oknie „Biblioteka”.")
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Zamknąć kanał „\(feedToClose?.meta?.title ?? "")”?", item: $feedToClose) { feed in
            Button("Zamknij kanał", role: .destructive) { Task { await model.close(feed) } }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in
            Text("Adres kanału przestanie działać we wszystkich aplikacjach do podcastów, które go subskrybują.")
        }
    }

    private func details(_ feed: AudiobookshelfClient.Feed) -> String {
        var parts = [feed.entityText]
        if let created = feed.createdAt { parts.append("otwarty " + Formats.dateTime(Date(timeIntervalSince1970: created / 1000))) }
        if feed.meta?.preventIndexing == false { parts.append("widoczny dla wyszukiwarek") }
        return parts.joined(separator: " · ")
    }
}
