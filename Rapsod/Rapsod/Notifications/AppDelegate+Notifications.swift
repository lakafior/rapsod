import AudiobookshelfKit
import Foundation
import OSLog
import RapsodIntegration

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Rapsod", category: "Notifications")

/// Połączenie powiadomień (etap 14e) z resztą aplikacji: źródła zdarzeń i kliknięcia.
extension AppDelegate {
    static func notificationCenter() -> any NotificationCenterClient {
        #if DEBUG
        if NotificationsTour.isRequested { return NotificationsTour.center }
        #endif
        return SystemNotificationCenter()
    }

    func configureNotifications() {
        notifications.relevantWindows = [
            .libraryScan: [SettingsWindow.windowID],
            .newEpisodes: [LibraryWindow.windowID],
            .uploads: [LibraryWindow.windowID],
            .appUpdate: [UpdateWindow.windowID],
        ]
        notifications.onRoute = { [weak self] route, action in self?.follow(route, action: action) }
        // Stałe gniazdo zdarzeń: dla powiadomień albo dla Spotlight (etap 14f).
        notifications.onNeedsServerEventsChanged = { [weak self] _ in self?.updateServerEventsWanted() }
        spotlight.onEnabledChanged = { [weak self] _ in self?.updateServerEventsWanted() }
        notifications.activate()

        activityMonitor.onEvent = { [weak self] event in self?.serverEvent(event) }
        activityMonitor.activate()
        updateServerEventsWanted()

        libraryTasks.onFinished = { [weak self] libraryID, activity in
            guard let self, let library = account.libraries.first(where: { $0.id == libraryID }) else { return }
            notifications.scanFinished(library: library, activity: activity)
        }
        updates.onUpdateFound = { [weak self] update in
            self?.notifications.updateFound(version: update.version.string, title: update.title) ?? false
        }
        listening.skip.onDetected = { [weak self] item, episode, segments, automatic in
            self?.notifications.sponsorSegmentsDetected(itemID: item.id, libraryID: item.libraryId, episodeID: episode.id,
                                                        podcastTitle: item.media.metadata.title, episodeTitle: episode.title,
                                                        count: segments, automatic: automatic)
        }
    }

    // MARK: Zdarzenia serwera

    /// Zdarzenie ze stałego gniazda — do tych samych modeli, które czyta panel na pasku menu.
    func updateServerEventsWanted() {
        activityMonitor.setWanted(notifications.needsServerEvents || spotlight.isEnabled)
    }

    private func serverEvent(_ event: ListeningEvents.Event) {
        spotlight.handle(event)
        switch event {
        case .task(let task, let finished):
            libraryTasks.observe(task, finished: finished)
            if finished, task.action == "watcher-scan" { watcherScanFinished(task) }
            if finished, task.action == "encode-m4b", let itemID = task.data?.libraryItemId {
                mergeFinished(task, itemID: itemID)
            }
        case .episodeDownload(let download, let phase):
            listening.episodeDownloads.apply(download, phase)
            if case .finished = phase { notifications.episodeDownloaded(download) }
        case .downloadQueueCleared(let itemID):
            listening.episodeDownloads.clear(itemID: itemID)
        case .progress, .user, .itemsChanged, .reconnected, .connected, .taskProgress, .trackStarted:
            break
        }
    }

    /// Skan obserwatora plików (nowe pliki w folderze biblioteki, np. po wgraniu) — osobne zadanie
    /// serwera, którego `LibraryTasks` nie śledzi. Powiadomienie tylko przy zmianach (zasada w pakiecie).
    private func watcherScanFinished(_ task: AudiobookshelfClient.ServerTask) {
        guard let libraryID = task.data?.libraryId, let library = account.libraries.first(where: { $0.id == libraryID }),
              task.isFailed != true else { return }
        let activity = LibraryTasks.Activity(kind: .scan(force: false), phase: .finished(task.data?.scanResults, canceled: false), since: .now)
        notifications.scanFinished(library: library, activity: activity)
    }

    private func mergeFinished(_ task: AudiobookshelfClient.ServerTask, itemID: String) {
        let canceled = task.errorKey == "MessageTaskCanceledByUser" || task.error == "Task canceled by user"
        guard !canceled else { return }
        let failure = task.isFailed == true ? ItemTasks.failureText(task) : nil
        Task {
            let item = try? await account.withAdminToken { try await $0.item(id: itemID, token: $1) }
            notifications.mergeFinished(itemID: itemID, libraryID: item?.libraryId, title: item?.media.metadata.title, failure: failure)
        }
    }

    // MARK: Kliknięcie

    func follow(_ route: NotificationRoute, action: NotificationAction?) {
        logger.info("Powiadomienie kliknięte: \(route.userInfoValue, privacy: .public) \(action?.rawValue ?? "otwórz", privacy: .public)")
        switch route {
        case .item(let itemID, let libraryID):
            if action == .play {
                Task {
                    // Kliknięcie mogło uruchomić aplikację: najpierw serwer i konto słuchacza.
                    guard (try? await IntentBridge.ready(.listener)) != nil else { return }
                    await listening.play(itemID: itemID)
                }
            } else {
                menuBar.openLibrary(.openItem(itemID: itemID, libraryID: libraryID))
            }
        case .episode(let itemID, let libraryID, let episodeID, let guid, let title):
            guard action == .play else {
                menuBar.openLibrary(.openItem(itemID: itemID, libraryID: libraryID))
                return
            }
            Task {
                guard (try? await IntentBridge.ready(.listener)) != nil else { return }
                if let id = await resolveEpisode(itemID: itemID, episodeID: episodeID, guid: guid, title: title) {
                    await listening.play(itemID: itemID, episodeID: id)
                } else {
                    menuBar.openLibrary(.openItem(itemID: itemID, libraryID: libraryID))
                }
            }
        case .librarySettings(let libraryID):
            menuBar.open(.settings(.library(id: libraryID)))
        case .library(let libraryID):
            menuBar.openLibrary(.showLibrary(libraryID))
        case .update:
            if let pending = updates.pending {
                if action == .install { updates.install(pending) } else { updates.showAvailable(pending) }
            }
            menuBar.open(.update)
        }
    }

    /// Zdarzenie pobierania nie niesie identyfikatora odcinka — szukamy go w pozycji po `guid` albo tytule.
    private func resolveEpisode(itemID: String, episodeID: String?, guid: String?, title: String?) async -> String? {
        if let episodeID { return episodeID }
        guard let item = try? await listening.api({ try await $0.item(id: itemID, token: $1) }) else { return nil }
        let episodes = (item.media.episodes?.elements ?? []).map { EpisodeLookup.Episode(id: $0.id, guid: $0.guid, title: $0.title) }
        return EpisodeLookup.find(in: episodes, guid: guid, title: title)
    }
}
