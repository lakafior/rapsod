// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 10f).

import SwiftUI
import AudiobookshelfKit
import AudiobookshelfPlayback

/// Co pobrać na telefon.
enum DownloadTarget {
    case book(itemID: String)
    /// Odcinek na serwerze.
    case episode(Client.PodcastEpisode, itemID: String, podcastTitle: String?, libraryID: String?)
    /// Odcinek znany tylko z identyfikatora (lista pobranych) — opis dopyta serwer.
    case episodeID(String, itemID: String)

    var itemID: String {
        switch self {
        case .book(let itemID), .episode(_, let itemID, _, _), .episodeID(_, let itemID): itemID
        }
    }

    var episodeID: String? {
        switch self {
        case .book: nil
        case .episode(let episode, _, _, _): episode.id
        case .episodeID(let id, _): id
        }
    }

    @MainActor
    func start(in session: ServerSession) async throws {
        switch self {
        case .book(let itemID):
            try await session.downloads.download(itemID: itemID, session: session)
        case .episode(let episode, let itemID, let podcastTitle, let libraryID):
            try await session.downloads.download(episode: episode, itemID: itemID, podcastTitle: podcastTitle, libraryID: libraryID, session: session)
        case .episodeID(let episodeID, let itemID):
            let item = try await session.auth.perform { try await $0.item(id: itemID, token: $1) }
            guard let episode = item.media.episodes?.elements.first(where: { $0.id == episodeID }) else { throw DownloadsController.AddError.noFiles }
            try await session.downloads.download(episode: episode, itemID: itemID, podcastTitle: item.media.metadata.title, libraryID: item.libraryId, session: session)
        }
    }
}

/// Przycisk na stronie pozycji i w opisie odcinka: stan pobrania i działanie, które mu odpowiada.
/// Obserwuje tylko wpis tej pozycji — procent nie przerysowuje reszty strony.
struct DownloadButton: View {
    let target: DownloadTarget
    let session: ServerSession
    @State private var isStarting = false
    @State private var error: String?
    @State private var confirmsRemoval = false

    var body: some View {
        let manager = session.downloads.manager
        let key = ProgressJournal.key(target.itemID, target.episodeID)
        let status = manager.entry(itemID: target.itemID, episodeID: target.episodeID).status
        Group {
            switch status {
            case .notDownloaded:
                Button {
                    Task { await start() }
                } label: {
                    Label(isStarting ? "Przygotowanie…" : "Pobierz na telefon", systemImage: "arrow.down.circle")
                }
                .disabled(isStarting)
            case .downloaded:
                Button(role: .destructive) {
                    confirmsRemoval = true
                } label: {
                    Label("Pobrano · usuń z telefonu", systemImage: "checkmark.circle.fill")
                }
            case .failed:
                Button { manager.retry(key: key) } label: { Label("Ponów pobieranie", systemImage: "arrow.clockwise") }
            case .paused:
                Button { manager.resume(key: key) } label: { Label("Wznów pobieranie", systemImage: "play.circle") }
            case .queued, .waiting, .downloading:
                Button { manager.pause(key: key) } label: {
                    HStack(spacing: 8) {
                        DownloadBadge(status: status)
                        Text("Wstrzymaj")
                    }
                }
            }
        }
        .buttonStyle(.bordered)
        .accessibilityHint(status.text)
        .confirmationDialog("Usunąć z telefonu?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Usuń pobrane pliki", role: .destructive) { manager.remove(key: key) }
        } message: {
            Text("Pliki znikną z telefonu, postęp słuchania zostaje.")
        }
        .alert("Nie udało się pobrać", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        // Podpis ze stanem pod przyciskiem: procent, oczekiwanie na sieć, błąd.
        if status.isActive {
            Text(status.text)
                .font(.footnote)
                .foregroundStyle(status.isFailure ? .red : .secondary)
                .multilineTextAlignment(.center)
                .contextMenu {
                    Button("Usuń z telefonu", systemImage: "trash", role: .destructive) { manager.remove(key: key) }
                }
        }
    }

    private func start() async {
        isStarting = true
        defer { isStarting = false }
        do {
            try await target.start(in: session)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension DownloadStatus {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Mały znacznik stanu pobrania (wiersz odcinka, karta, lista pobranych). Pusty, gdy nie pobrano.
struct DownloadBadge: View {
    let status: DownloadStatus

    var body: some View {
        Group {
            switch status {
            case .notDownloaded:
                EmptyView()
            case .downloaded:
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            case .queued:
                Image(systemName: "clock").foregroundStyle(.secondary)
            case .waiting(let wait):
                Image(systemName: wait == .connection ? "icloud.slash" : "wifi.exclamationmark").foregroundStyle(.orange)
            case .paused:
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .imageScale(.medium)
        .accessibilityLabel(status.text)
    }
}

/// Znacznik obserwujący wpis jednej pozycji (do list: zmiana procentu przerysowuje tylko go).
struct DownloadEntryBadge: View {
    let entry: DownloadManager.Entry
    var body: some View { DownloadBadge(status: entry.status) }
}

/// Pozycje menu kontekstowego: pobierz / wstrzymaj / wznów / usuń z telefonu.
struct DownloadMenuItems: View {
    let target: DownloadTarget
    let session: ServerSession
    let onError: (String) -> Void

    var body: some View {
        let manager = session.downloads.manager
        let key = ProgressJournal.key(target.itemID, target.episodeID)
        switch manager.entry(itemID: target.itemID, episodeID: target.episodeID).status {
        case .notDownloaded:
            Button("Pobierz na telefon", systemImage: "arrow.down.circle") {
                Task {
                    do { try await target.start(in: session) } catch { onError(error.localizedDescription) }
                }
            }
        case .downloaded:
            Button("Usuń z telefonu", systemImage: "trash", role: .destructive) { manager.remove(key: key) }
        case .paused:
            Button("Wznów pobieranie", systemImage: "play.circle") { manager.resume(key: key) }
            Button("Anuluj pobieranie", systemImage: "xmark.circle", role: .destructive) { manager.remove(key: key) }
        case .failed:
            Button("Ponów pobieranie", systemImage: "arrow.clockwise") { manager.retry(key: key) }
            Button("Anuluj pobieranie", systemImage: "xmark.circle", role: .destructive) { manager.remove(key: key) }
        case .queued, .waiting, .downloading:
            Button("Wstrzymaj pobieranie", systemImage: "pause.circle") { manager.pause(key: key) }
            Button("Anuluj pobieranie", systemImage: "xmark.circle", role: .destructive) { manager.remove(key: key) }
        }
    }
}

// MARK: - Pobrane

/// Lista pobranych i pobieranych pozycji tego serwera. Bez sieci — to, czego da się słuchać.
struct DownloadsList: View {
    let model: AppModel
    let session: ServerSession
    /// Nagłówek nad listą (np. komunikat „brak połączenia”).
    var notice: String?

    var body: some View {
        let manager = session.downloads.manager
        let items = manager.items(scope: session.scope)
        let active = items.filter { !$0.isComplete }
        let books = items.filter { $0.isComplete && !$0.isEpisode }
        let episodes = items.filter { $0.isComplete && $0.isEpisode }
        List {
            if let notice {
                Section {
                    Label(notice, systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if !active.isEmpty {
                Section("Pobierane") {
                    ForEach(active) { DownloadRow(item: $0, model: model, session: session) }
                }
            }
            if !books.isEmpty {
                Section("Książki") {
                    ForEach(books) { DownloadRow(item: $0, model: model, session: session) }
                }
            }
            if !episodes.isEmpty {
                Section("Odcinki podcastów") {
                    ForEach(episodes) { DownloadRow(item: $0, model: model, session: session) }
                }
            }
            if !items.isEmpty {
                Section {
                    LabeledContent("Zajęte miejsce", value: manager.usedBytes(scope: session.scope).formatted(.byteCount(style: .file)))
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("Nic nie pobrano", systemImage: "arrow.down.circle",
                                       description: Text("Na stronie książki albo przy odcinku wybierz „Pobierz na telefon”, żeby słuchać bez sieci."))
            }
        }
        .alert("Nie udało się odtworzyć", isPresented: Binding(get: { model.playback.loadError != nil && model.playback.player.book == nil }, set: { if !$0 { model.playback.loadError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.playback.loadError ?? "")
        }
    }
}

/// Wiersz pobranej pozycji: okładka z dysku, tytuł, stan pobrania albo postęp słuchania.
/// Dotknięcie gra (albo zatrzymuje) pobraną pozycję.
private struct DownloadRow: View {
    let item: DownloadedItem
    let model: AppModel
    let session: ServerSession
    @State private var error: String?
    @ScaledMetric(relativeTo: .body) private var coverSize: CGFloat = 52
    @Environment(\.dynamicTypeSize) private var typeSize

    private var cover: some View {
        ItemCover(itemID: item.itemID, session: session, points: 60)
            .frame(width: min(coverSize, 90))
    }

    private func texts(entry: DownloadManager.Entry, lineLimit: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(.body.weight(.medium)).lineLimit(lineLimit)
            if let author = item.author, !author.isEmpty {
                Text(author).font(.footnote).foregroundStyle(.secondary).lineLimit(lineLimit == nil ? nil : 1)
            }
            if item.isComplete {
                PositionLine(entry: session.journal.positionEntry(itemID: item.itemID, episodeID: item.episodeID), duration: item.duration)
            } else {
                DownloadStatusLine(entry: entry)
            }
        }
    }

    @ViewBuilder
    private func trailing(entry: DownloadManager.Entry, isCurrent: Bool) -> some View {
        if item.isComplete {
            Image(systemName: isCurrent && model.playback.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        } else {
            DownloadEntryBadge(entry: entry)
        }
    }

    var body: some View {
        let entry = session.downloads.manager.entry(itemID: item.itemID, episodeID: item.episodeID)
        let key = PlaybackTimeline.key(item.itemID, item.episodeID)
        let isCurrent = model.playback.nowPlayingKey == key
        Button {
            guard item.isComplete else { return }
            Task { await model.playback.play(itemID: item.itemID, episodeID: item.episodeID) }
        } label: {
            Group {
                if typeSize.isAccessibilitySize {
                    // Największy tekst: okładka i przycisk w jednym rzędzie, tekst pod nimi bez ucinania.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            cover
                            Spacer(minLength: 0)
                            trailing(entry: entry, isCurrent: isCurrent)
                        }
                        texts(entry: entry, lineLimit: nil)
                    }
                } else {
                    HStack(spacing: 12) {
                        cover
                        texts(entry: entry, lineLimit: 2)
                        Spacer(minLength: 0)
                        trailing(entry: entry, isCurrent: isCurrent)
                    }
                }
            }
            .contentShape(.rect)
            // Na zawartości przycisku, nie na nim — inaczej VoiceOver widzi dwa elementy (etap 10d).
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .accessibilityHint(item.isComplete ? (isCurrent && model.playback.player.isPlaying ? "Zatrzymuje" : "Odtwarza z telefonu") : "")
        .contextMenu {
            DownloadMenuItems(target: target, session: session) { error = $0 }
        }
        .swipeActions(edge: .trailing) {
            Button("Usuń", systemImage: "trash", role: .destructive) {
                session.downloads.manager.remove(key: item.id)
            }
        }
        .alert("Nie udało się", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var target: DownloadTarget {
        item.episodeID.map { .episodeID($0, itemID: item.itemID) } ?? .book(itemID: item.itemID)
    }
}

/// Stan pobierania jednym wierszem (obserwuje tylko wpis tej pozycji).
private struct DownloadStatusLine: View {
    let entry: DownloadManager.Entry
    var body: some View {
        Text(entry.status.text)
            .font(.caption)
            .foregroundStyle(entry.status.isFailure ? .red : .secondary)
            .lineLimit(2)
    }
}

/// Postęp słuchania z dziennika na telefonie (działa bez sieci).
private struct PositionLine: View {
    let entry: ProgressJournal.PositionEntry
    let duration: Double

    var body: some View {
        if let value = entry.value, value.isFinished {
            Label("Ukończone", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        } else if let value = entry.value, value.currentTime > 0 {
            // Wąsko (duży tekst): pasek nad podpisem zamiast obok — bez łamania słów.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { bar(value); remaining(value).fixedSize() }
                VStack(alignment: .leading, spacing: 4) { bar(value); remaining(value) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Przesłuchane \(Int((duration > 0 ? value.currentTime / duration : 0) * 100)) procent")
        } else {
            Text(TimeText.long(duration)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func bar(_ value: PositionRecord) -> some View {
        ProgressView(value: duration > 0 ? min(1, value.currentTime / duration) : 0)
            .frame(maxWidth: 120)
    }

    private func remaining(_ value: PositionRecord) -> some View {
        Text("zostało \(TimeText.long(max(0, duration - value.currentTime)))")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// Ekran „Pobrane” (z Ustawień i ze Startu).
struct DownloadsScreen: View {
    let model: AppModel
    let session: ServerSession

    var body: some View {
        DownloadsList(model: model, session: session, notice: model.isOffline ? "Brak połączenia z serwerem — słuchasz tego, co jest na telefonie." : nil)
            .navigationTitle("Pobrane")
    }
}

/// Zamiast błędu wczytywania, gdy nie ma połączenia: pobrane pozycje (jeśli są), inaczej błąd.
struct OfflineFallback: View {
    let model: AppModel
    let session: ServerSession
    let message: String?
    let retry: () -> Void

    var body: some View {
        if !session.downloads.manager.items(scope: session.scope).isEmpty {
            DownloadsList(model: model, session: session, notice: "Brak połączenia z serwerem — pokazuję to, co jest pobrane na telefon. Telefon spróbuje ponownie po zmianie sieci.")
                .refreshable { await model.reconnect() }
        } else if let message {
            LoadFailureView(message: message, retry: retry)
        } else {
            ContentUnavailableView {
                Label("Brak połączenia", systemImage: "wifi.slash")
            } description: {
                Text("Serwer jest teraz nieosiągalny, a na telefonie nie ma pobranych pozycji. Pobieraj książki i odcinki na telefon, żeby słuchać bez sieci.")
            } actions: {
                Button("Spróbuj ponownie", action: retry)
            }
        }
    }
}
