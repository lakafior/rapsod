import AppKit
import AudiobookshelfKit
import SwiftUI

/// Historia słuchania (Użytkownicy › „Historia słuchania wszystkich…” albo profil osoby ›
/// „Historia słuchania…”; etap 5 planu, dawna strona „Aktywność”, wzorzec `client/pages/config/sessions.vue`):
/// kto słucha teraz (z „Zamknij”) i zapisane sesje z filtrem osoby, szczegółami i usuwaniem.
struct ListeningHistoryPage: View {
    let models: AppModels
    /// Osoba, od której zaczyna się filtr (z profilu); `nil` — wszyscy.
    let userID: String?

    var body: some View {
        AdminPage(account: models.account, title: "Sesje słuchania", make: { SessionsModel(account: models.account, userFilter: userID) }, load: { await $0.load() }) { model in
            SessionsContent(model: model)
        }
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        guard let userID, let name = models.users.user(id: userID)?.username else { return "Historia słuchania" }
        return "Historia słuchania — \(name)"
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
