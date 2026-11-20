import AppKit
import SwiftUI

/// Stan arkusza zarządzania pozycją. Szkice (szczegóły, rozdziały) są brane z pozycji raz,
/// przy otwarciu arkusza i po własnym zapisie — przeładowanie strony książki po zdarzeniu
/// serwera ich nie nadpisuje, więc zapis okładki nie kasuje niezapisanych zmian w szczegółach.
@MainActor
@Observable
final class ItemEditorModel {
    enum Tab: Hashable {
        case details, cover, chapters, match
    }

    struct Message: Equatable {
        let text: String
        let isError: Bool
    }

    let browser: LibraryBrowser
    private(set) var item: AudiobookshelfClient.ItemDetail
    var tab: Tab
    var details: DetailsDraft
    private(set) var detailsBase: DetailsDraft
    var chapters: [ChapterDraft]
    private(set) var chaptersBase: [ChapterDraft]
    /// Trwająca operacja (opis w stopce).
    private(set) var busy: String?
    var message: Message?
    let match = MatchSearch()
    let covers = CoverSearch()

    init(browser: LibraryBrowser, item: AudiobookshelfClient.ItemDetail, tab: Tab) {
        self.browser = browser
        self.item = item
        self.tab = tab
        let details = DetailsDraft(item)
        self.details = details
        detailsBase = details
        let chapters = ChapterDraft.list(item)
        self.chapters = chapters
        chaptersBase = chapters
    }

    var manager: ItemManager { browser.manager }
    var listening: ListeningController { browser.listening }
    var duration: Double { item.media.duration ?? 0 }
    var hasAudio: Bool { !(item.media.tracks?.elements.isEmpty ?? true) }
    var detailsDirty: Bool { !details.isSame(as: detailsBase) }
    var chaptersDirty: Bool { chapters != chaptersBase }
    var isBusy: Bool { busy != nil }

    /// Wykonuje operację z opisem w stopce; błąd trafia do stopki zamiast alertu.
    func perform(_ label: String, failure: String, _ work: () async throws -> String?) async {
        guard busy == nil else { return }
        busy = label
        message = nil
        defer { busy = nil }
        do {
            if let done = try await work() { message = Message(text: done, isError: false) }
        } catch is CancellationError {
        } catch let reported as Reported {
            message = Message(text: reported.text, isError: true)
        } catch {
            message = Message(text: ItemManager.message(for: error, action: failure), isError: true)
        }
    }

    /// Tokenem root: po oznaczeniu „dla dorosłych” konto słuchacza może już nie widzieć pozycji.
    private func reload() async throws {
        let id = item.id
        item = try await manager.run { try await $0.item(id: id, token: $1) }
    }

    /// `false`, gdy konto słuchacza nie widzi treści dla dorosłych (ostrzeżenie przy przełączniku).
    private(set) var listenerSeesExplicit: Bool?

    func loadListenerPermissions() async {
        guard listenerSeesExplicit == nil else { return }
        listenerSeesExplicit = try? await listening.api { try await $0.canAccessExplicitContent(token: $1) }
    }

    /// Przy otwarciu: strona książki bywa chwilę nieaktualna po zapisie (albo wcale, gdy słuchacz
    /// stracił dostęp), więc arkusz bierze świeży stan tokenem root. Szkiców z niezapisanymi zmianami nie rusza.
    func refreshOnOpen() async {
        guard (try? await reload()) != nil else { return }
        if !detailsDirty { resetDetails() }
        if !chaptersDirty { resetChapters() }
    }

    func resetDetails() {
        details = DetailsDraft(item)
        detailsBase = details
    }

    func resetChapters() {
        chapters = ChapterDraft.list(item)
        chaptersBase = chapters
    }

    // MARK: Szczegóły

    func saveDetails() async {
        if let problem = details.problem {
            message = Message(text: problem, isError: true)
            return
        }
        let update = details.update(from: detailsBase)
        guard !update.isEmpty else { return }
        await perform("Zapisywanie szczegółów…", failure: "Nie udało się zapisać szczegółów") {
            let id = item.id
            let updated = try await manager.run { try await $0.updateMedia(itemID: id, update, token: $1) }
            try await reload()
            resetDetails()
            browser.invalidateFilterData()
            if updated, update.metadata.explicit == true, listenerSeesExplicit == false {
                return "Zapisano szczegóły. Konto słuchacza nie ma dostępu do treści dla dorosłych — ta książka zniknęła z jego biblioteki (także na telefonie)."
            }
            return updated ? "Zapisano szczegóły." : "Nic się nie zmieniło."
        }
    }

    // MARK: Dopasowanie

    /// Zapis wybranych pól wyniku. Okładka idzie osobnym zapytaniem po metadanych, żeby błąd
    /// pobrania obrazka nie przekreślał reszty (w upstreamie `url` w PATCH przerywa cały zapis).
    func applyMatch(_ update: AudiobookshelfClient.MediaUpdate, coverURL: String?) async {
        guard !update.isEmpty || coverURL != nil else { return }
        await perform("Zapisywanie dopasowania…", failure: "Nie udało się zapisać dopasowania") {
            let id = item.id
            var notes: [String] = []
            if !update.isEmpty {
                let updated = try await manager.run { try await $0.updateMedia(itemID: id, update, token: $1) }
                notes.append(updated ? "Zapisano dane z dopasowania." : "Dane bez zmian.")
            }
            if let coverURL {
                do {
                    try await manager.run { try await $0.setCover(itemID: id, url: coverURL, token: $1) }
                    notes.append("Okładka zmieniona.")
                } catch {
                    // Metadane już zapisane — pokaż je i powiedz, czego brakuje.
                    try? await reload()
                    resetDetails()
                    browser.invalidateFilterData()
                    match.selected = nil
                    let text = (notes + [ItemManager.message(for: error, action: "Okładki nie udało się pobrać")]).joined(separator: " ")
                    throw Reported(text: text)
                }
            }
            try await reload()
            resetDetails()
            browser.invalidateFilterData()
            if coverURL != nil { listening.coverChanged(itemID: id, path: item.media.coverPath) }
            match.selected = nil
            tab = .details
            return notes.joined(separator: " ")
        }
    }

    /// Błąd z gotowym komunikatem (np. częściowy sukces).
    private struct Reported: Error {
        let text: String
    }

    // MARK: Okładka

    func changeCover(_ label: String, failure: String, _ operation: @escaping @Sendable (AudiobookshelfClient, String, String) async throws -> Void) async {
        await perform(label, failure: failure) {
            let id = item.id
            try await manager.run { try await operation($0, id, $1) }
            try await reload()
            listening.coverChanged(itemID: id, path: item.media.coverPath)
            return item.media.coverPath == nil ? "Okładka usunięta." : "Okładka zmieniona."
        }
    }

    // MARK: Rozdziały

    func saveChapters() async {
        if let problem = ChapterDraft.problem(in: chapters, duration: duration) {
            message = Message(text: problem, isError: true)
            return
        }
        let payload = ChapterDraft.payload(chapters, duration: duration)
        await perform("Zapisywanie rozdziałów…", failure: "Nie udało się zapisać rozdziałów") {
            let id = item.id
            let updated = try await manager.run { try await $0.updateChapters(itemID: id, payload, token: $1) }
            try await reload()
            resetChapters()
            let chapters = (item.media.chapters ?? []).map { AudiobookPlayer.Chapter(id: $0.id, start: $0.start, end: $0.end, title: $0.title) }
            listening.chaptersChanged(itemID: id, chapters: chapters)
            return updated ? "Zapisano rozdziały (\(payload.count))." : "Nic się nie zmieniło."
        }
    }
}

/// Arkusz „Edycja pozycji” nad oknem biblioteki: zakładki jak w modalu web UI.
struct ItemEditorSheet: View {
    @State private var model: ItemEditorModel
    @State private var confirmClose = false
    @Environment(\.dismiss) private var dismiss

    init(browser: LibraryBrowser, item: AudiobookshelfClient.ItemDetail, tab: ItemEditorModel.Tab) {
        _model = State(initialValue: ItemEditorModel(browser: browser, item: item, tab: tab))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView(selection: $model.tab) {
                DetailsTab(model: model).tabItem { Text("Szczegóły") }.tag(ItemEditorModel.Tab.details)
                CoverTab(model: model).tabItem { Text("Okładka") }.tag(ItemEditorModel.Tab.cover)
                if model.hasAudio {
                    ChaptersTab(model: model).tabItem { Text("Rozdziały") }.tag(ItemEditorModel.Tab.chapters)
                }
                MatchTab(model: model).tabItem { Text("Dopasuj") }.tag(ItemEditorModel.Tab.match)
            }
            .padding([.horizontal, .bottom], 16)
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 880, minHeight: 640, idealHeight: 720)
        .interactiveDismissDisabled(model.detailsDirty || model.chaptersDirty)
        .task {
            await model.refreshOnOpen()
            await model.loadListenerPermissions()
            await model.browser.loadFilterData()
        }
        .confirmationDialog("Odrzucić niezapisane zmiany?", isPresented: $confirmClose) {
            Button("Odrzuć zmiany", role: .destructive) { dismiss() }
            Button("Wróć do edycji", role: .cancel) {}
        } message: {
            Text(unsavedSummary)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AsyncCover(listening: model.listening, itemID: model.item.id, path: model.item.media.coverPath, size: 44)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.item.title).font(.headline).lineLimit(1)
                let authors = (model.item.media.metadata.authors ?? []).map(\.name).joined(separator: ", ")
                if !authors.isEmpty { Text(authors).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).foregroundStyle(.secondary)
            } else if let message = model.message {
                Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(message.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.green))
                Text(message.text)
                    .foregroundStyle(message.isError ? .primary : .secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .accessibilityIdentifier("editor.message")
            }
            Spacer()
            Button("Zamknij") {
                // Najpierw kończy edycję pola, żeby niezatwierdzony tekst (np. żeton bez przecinka) też się liczył.
                NSApp.keyWindow?.makeFirstResponder(nil)
                if model.detailsDirty || model.chaptersDirty { confirmClose = true } else { dismiss() }
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("editor.close")
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var unsavedSummary: String {
        var parts: [String] = []
        if model.detailsDirty { parts.append("szczegóły") }
        if model.chaptersDirty { parts.append("rozdziały") }
        return "Niezapisane: \(parts.joined(separator: " i ")). Zamknięcie je odrzuci."
    }
}
