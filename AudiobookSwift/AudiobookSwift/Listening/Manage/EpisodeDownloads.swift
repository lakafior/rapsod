import SwiftUI

/// Kolejka pobierania odcinków podcastów. Serwer pobiera po jednym odcinku naraz i nie podaje
/// procentów — zgłasza tylko „w kolejce”, „pobieranie” i „gotowe/błąd”
/// (`PodcastManager.js`). Zakończone pobrania serwer zapomina, więc lista „Ostatnio pobrane”
/// istnieje tylko w tej aplikacji, od otwarcia okna.
@MainActor
@Observable
final class EpisodeDownloads {
    enum Phase: Sendable {
        case queued, started, finished
    }

    private(set) var current: AudiobookshelfClient.EpisodeDownload?
    private(set) var queue: [AudiobookshelfClient.EpisodeDownload] = []
    /// Ostatnie zakończone (najnowsze pierwsze), najwyżej 50.
    private(set) var recent: [AudiobookshelfClient.EpisodeDownload] = []

    func apply(_ download: AudiobookshelfClient.EpisodeDownload, _ phase: Phase) {
        switch phase {
        case .queued:
            if current?.id != download.id, !queue.contains(where: { $0.id == download.id }) { queue.append(download) }
        case .started:
            queue.removeAll { $0.id == download.id }
            current = download
        case .finished:
            queue.removeAll { $0.id == download.id }
            if current?.id == download.id { current = nil }
            recent.removeAll { $0.id == download.id }
            recent.insert(download, at: 0)
            if recent.count > 50 { recent.removeLast(recent.count - 50) }
        }
    }

    func clear(itemID: String) {
        queue.removeAll { $0.libraryItemId == itemID }
    }

    /// Stan z serwera (po otwarciu widoku albo powrocie połączenia).
    func replace(with state: AudiobookshelfClient.DownloadQueue, libraryID: String) {
        if let current, current.libraryId == libraryID, state.currentDownload?.id != current.id {
            // Zniknął bez zdarzenia „finished” (np. przerwa w połączeniu) — pokaż go jako zakończony.
            recent.insert(current, at: 0)
        }
        if state.currentDownload != nil || current?.libraryId == libraryID { current = state.currentDownload }
        queue.removeAll { $0.libraryId == libraryID }
        queue.append(contentsOf: state.queue?.elements ?? [])
    }

    func clearRecent() { recent = [] }

    /// Aktywne (w kolejce i pobierane) w bibliotece — licznik w pasku bocznym.
    func activeCount(libraryID: String?) -> Int {
        (current.map { $0.libraryId == libraryID ? 1 : 0 } ?? 0) + queue.filter { $0.libraryId == libraryID }.count
    }

    /// Czy podcast ma coś w kolejce (wyłącza ponowne pobranie tego samego odcinka na liście kanału).
    func isActive(itemID: String) -> Bool {
        current?.libraryItemId == itemID || queue.contains { $0.libraryItemId == itemID }
    }
}

/// Sekcja „Pobieranie” biblioteki podcastów: bieżące pobranie, kolejka, ostatnio zakończone.
struct DownloadsView: View {
    let browser: LibraryBrowser
    let libraryID: String
    @State private var error: String?
    @State private var clearing: String?

    private var downloads: EpisodeDownloads { browser.listening.episodeDownloads }

    var body: some View {
        let current = downloads.current?.libraryId == libraryID ? downloads.current : nil
        let queue = downloads.queue.filter { $0.libraryId == libraryID }
        let recent = downloads.recent.filter { $0.libraryId == libraryID }
        List {
            Section("Teraz") {
                if let current {
                    row(current) {
                        ProgressView().controlSize(.small)
                        Text("Pobieranie…").foregroundStyle(.secondary)
                    }
                } else {
                    Text(queue.isEmpty ? "Nic się nie pobiera." : "Za chwilę zacznie się następne.").foregroundStyle(.secondary)
                }
            }
            if !queue.isEmpty {
                Section {
                    ForEach(queue) { download in
                        row(download) { Text("W kolejce").foregroundStyle(.secondary) }
                    }
                } header: {
                    HStack {
                        Text("W kolejce (\(queue.count))")
                        Spacer()
                        clearMenu(queue)
                    }
                }
            }
            if !recent.isEmpty {
                Section {
                    ForEach(recent) { download in
                        row(download) {
                            if download.failed == true {
                                Label("Błąd pobierania", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            } else {
                                Label("Pobrano", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Ostatnio zakończone")
                        Spacer()
                        Button("Wyczyść listę") { downloads.clearRecent() }.buttonStyle(.link).font(.caption)
                    }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        .navigationTitle("Pobieranie")
        .task(id: browser.revision) { await load() }
        .accessibilityIdentifier("downloads")
    }

    private func row(_ download: AudiobookshelfClient.EpisodeDownload, @ViewBuilder status: () -> some View) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(download.episodeDisplayTitle ?? "Odcinek").lineLimit(2)
                HStack(spacing: 6) {
                    Button(download.podcastTitle ?? "Podcast") { browser.open(.item(download.libraryItemId)) }
                        .buttonStyle(.link)
                    if let season = download.season, !season.isEmpty { Text("Sezon \(season)") }
                    if let number = download.episode, !number.isEmpty { Text("Odcinek \(number)") }
                    if let ms = download.publishedAt { Text(Formats.day(Date(timeIntervalSince1970: ms / 1000))) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) { status() }.font(.callout)
        }
        .padding(.vertical, 2)
    }

    /// Serwer czyści kolejkę jednego podcastu naraz (bez bieżącego pobrania).
    @ViewBuilder private func clearMenu(_ queue: [AudiobookshelfClient.EpisodeDownload]) -> some View {
        let podcasts = Dictionary(grouping: queue, by: \.libraryItemId)
        Menu("Wyczyść kolejkę") {
            ForEach(podcasts.keys.sorted(), id: \.self) { itemID in
                let title = podcasts[itemID]?.first?.podcastTitle ?? "Podcast"
                Button("\(title) (\(podcasts[itemID]?.count ?? 0))") { clear(itemID) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
        .disabled(!browser.manager.isAvailable || clearing != nil)
        .help(browser.manager.isAvailable ? "Usuwa z kolejki odcinki, które jeszcze się nie zaczęły pobierać" : browser.manager.unavailableReason)
    }

    private func clear(_ itemID: String) {
        clearing = itemID
        Task {
            defer { clearing = nil }
            do {
                try await browser.manager.run { try await $0.clearDownloadQueue(itemID: itemID, token: $1) }
                downloads.clear(itemID: itemID)
                error = nil
            } catch {
                self.error = ItemManager.message(for: error, action: "Nie udało się wyczyścić kolejki")
            }
        }
    }

    private func load() async {
        do {
            let state = try await browser.listening.api { try await $0.episodeDownloadQueue(libraryID: libraryID, token: $1) }
            downloads.replace(with: state, libraryID: libraryID)
            error = nil
        } catch {
            self.error = "Nie udało się wczytać kolejki: \(error.localizedDescription)"
        }
    }
}
