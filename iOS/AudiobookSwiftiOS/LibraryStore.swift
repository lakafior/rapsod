// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import OSLog
import AudiobookshelfKit

private let logger = Logger(subsystem: "net.smigi.abswift.ios", category: "Library")

/// Biblioteki serwera połączone w jedną (`CombinedLibraries` z pakietu), postęp słuchania
/// i zdarzenia serwera na żywo. Jedna na połączenie (`ServerSession`).
@MainActor
@Observable
final class LibraryStore {
    enum State {
        case loading
        case ready(CombinedLibraries)
        case failed(String)
    }

    private(set) var state: State = .loading
    /// Rośnie, gdy serwer zgłosi dodane/zmienione/usunięte pozycje — półki i listy mogą się odświeżyć.
    private(set) var itemsRevision = 0
    /// Rośnie po wczytaniu postępu z serwera (np. po powrocie połączenia).
    private(set) var progressRevision = 0
    @ObservationIgnored let progress = ProgressStore()
    @ObservationIgnored private let auth: ListeningAuth
    @ObservationIgnored private var events: ListeningEvents?
    @ObservationIgnored private var itemsChange: Task<Void, Never>?

    init(auth: ListeningAuth) {
        self.auth = auth
    }

    var combined: CombinedLibraries? {
        if case .ready(let combined) = state { return combined }
        return nil
    }

    /// Działa, dopóki trwa zadanie wołającego (widok z `.task`): wczytuje biblioteki i postęp,
    /// słucha zdarzeń serwera, a po anulowaniu zamyka gniazdo.
    func run() async {
        startEvents()
        await load()
        await withTaskCancellationHandler {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stopEvents() }
        }
    }

    func load() async {
        if case .failed = state { state = .loading }
        do {
            let combined = try await CombinedLibraries.load(auth: auth)
            // Postęp przed pokazaniem list: „Ostatnio słuchane” bierze z niego kolejność.
            await refreshProgress()
            state = .ready(combined)
        } catch is CancellationError {
            return
        } catch {
            logger.error("Biblioteki: \(error.localizedDescription, privacy: .public)")
            if combined == nil { state = .failed(Self.message(error)) }
            await refreshProgress()
        }
    }

    /// Postęp konta z `GET /api/me` (ten sam, który widzi Mac i web UI).
    func refreshProgress() async {
        guard let me: AudiobookshelfClient.MeState = try? await auth.perform({ try await $0.me(token: $1) }) else { return }
        progress.replaceAll(me.mediaProgress.elements)
        progressRevision += 1
    }

    static func message(_ error: any Error) -> String {
        if case AudiobookshelfClient.APIError.unauthorized = error {
            return Connector.ConnectError.keyRejected.localizedDescription
        }
        return error.localizedDescription
    }

    // MARK: Zdarzenia serwera

    private func startEvents() {
        guard events == nil else { return }
        let auth = auth
        let events = ListeningEvents(baseURL: auth.baseURL, token: { _ in try await auth.token() }) { [weak self] event in
            self?.handle(event)
        }
        self.events = events
        events.start()
    }

    private func stopEvents() {
        events?.stop()
        events = nil
        itemsChange?.cancel()
    }

    private func handle(_ event: ListeningEvents.Event) {
        switch event {
        case .progress(let entry):
            progress.update(entry)
        case .user(let me):
            progress.replaceAll(me.mediaProgress.elements)
        case .itemsChanged(let libraries, _):
            guard combined.map({ store in libraries.contains { id in store.libraries.contains { $0.id == id } } }) ?? false else { return }
            // Skan dodaje pozycje seriami — jedno odświeżenie po chwili ciszy.
            itemsChange?.cancel()
            itemsChange = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                itemsRevision += 1
            }
        case .reconnected:
            Task { await refreshProgress() }
        default:
            break
        }
    }
}

/// Postęp pozycji z wąską obserwacją: każda pozycja ma własny obiekt, więc zmiana postępu
/// jednej książki (synchronizacja co kilkanaście sekund w trakcie słuchania) przerysowuje
/// tylko jej kartę, a nie całą siatkę.
@MainActor
final class ProgressStore {
    @MainActor
    @Observable
    final class Entry {
        fileprivate(set) var value: AudiobookshelfClient.MediaProgress?

        init(_ value: AudiobookshelfClient.MediaProgress?) { self.value = value }

        /// 0…1 albo `nil`, gdy pozycji nie zaczęto.
        var fraction: Double? {
            guard let value else { return nil }
            if value.isFinished { return 1 }
            guard let progress = value.progress, progress > 0 else { return nil }
            return min(1, progress)
        }
    }

    private var entries: [String: Entry] = [:]
    private var values: [String: AudiobookshelfClient.MediaProgress] = [:]

    /// Obiekt postępu książki (tworzony przy pierwszym pytaniu; odczyt `value` w widoku go obserwuje).
    func entry(_ itemID: String) -> Entry {
        if let entry = entries[itemID] { return entry }
        let entry = Entry(values[itemID])
        entries[itemID] = entry
        return entry
    }

    func value(_ itemID: String) -> AudiobookshelfClient.MediaProgress? { values[itemID] }

    /// Czas ostatniego słuchania (ms) — do sortowania „Ostatnio słuchane” i półki „Słuchaj dalej”.
    var lastUpdate: [String: Double] { values.mapValues(\.lastUpdate) }

    func replaceAll(_ list: [AudiobookshelfClient.MediaProgress]) {
        var fresh: [String: AudiobookshelfClient.MediaProgress] = [:]
        for entry in list where entry.episodeId == nil {
            guard let id = entry.libraryItemId else { continue }
            fresh[id] = entry
        }
        let removed = Set(values.keys).subtracting(fresh.keys)
        values = fresh
        for id in removed { set(id, nil) }
        for (id, entry) in fresh { set(id, entry) }
    }

    func update(_ entry: AudiobookshelfClient.MediaProgress) {
        guard entry.episodeId == nil, let id = entry.libraryItemId else { return }
        values[id] = entry
        set(id, entry)
    }

    func remove(_ itemID: String) {
        values[itemID] = nil
        set(itemID, nil)
    }

    private func set(_ id: String, _ value: AudiobookshelfClient.MediaProgress?) {
        // Przypisanie tylko przy zmianie — inaczej obserwujący widok i tak by się przerysował.
        guard let entry = entries[id], entry.value != value else { return }
        entry.value = value
    }
}
