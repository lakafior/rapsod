import AppKit
import AudiobookshelfKit
import Observation
import OSLog
import RapsodIntegration
import UserNotifications

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Rapsod", category: "Notifications")

/// Powiadomienia systemowe tego Maca (etap 14e): wybór użytkownika, zgoda systemu, wysyłanie
/// i obsługa kliknięć. Treści i zasady („kiedy warto”) są w pakiecie (`RapsodIntegration`), tu tylko
/// zdarzenia aplikacji i `UserNotifications`.
///
/// Powiadomienia serwera (Apprise, e-mail) to osobna rzecz — wysyła je serwer i dotyczą wszystkich
/// urządzeń; te tutaj pokazuje tylko ten Mac.
@MainActor
@Observable
final class SystemNotifications {
    /// Stan zgody systemu, uproszczony do tego, co pokazuje strona ustawień.
    enum Authorization: Equatable {
        case unknown
        case notDetermined
        case denied
        case authorized
        /// Zgoda „po cichu” (tylko w Centrum powiadomień, bez banerów).
        case provisional
    }

    /// Dostęp z miejsc, które nie mają ścieżki do `AppDelegate` (arkusz wgrywania w oknie).
    private(set) static weak var current: SystemNotifications?

    private(set) var preferences: NotificationPreferences
    private(set) var authorization: Authorization = .unknown
    /// Prośba o zgodę w toku (przełącznik czeka).
    private(set) var isRequesting = false

    @ObservationIgnored private let center: any NotificationCenterClient
    @ObservationIgnored private let delegate: NotificationDelegate
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var batcher = EpisodeBatcher()
    @ObservationIgnored private var batchFlush: Task<Void, Never>?
    @ObservationIgnored private var sponsorGate = SponsorNotificationGate()
    /// Kliknięcie w powiadomienie albo przycisk — wykonuje `AppDelegate` (okna, odtwarzanie).
    @ObservationIgnored var onRoute: ((NotificationRoute, NotificationAction?) -> Void)?
    /// Zmieniło się, czy potrzebne jest stałe połączenie zdarzeń serwera.
    @ObservationIgnored var onNeedsServerEventsChanged: ((Bool) -> Void)?
    /// Okna związane z rodzajem — gdy któreś jest kluczowe w aktywnej aplikacji, powiadomienia nie ma.
    @ObservationIgnored var relevantWindows: [NotificationKind: Set<String>] = [:]

    init(center: any NotificationCenterClient = SystemNotificationCenter(), defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
        preferences = NotificationPreferences(read: { defaults.object(forKey: $0) })
        delegate = NotificationDelegate()
        delegate.onResponse = { [weak self] route, action in self?.respond(route: route, action: action) }
        delegate.presentation = { [weak self] category in self?.presentation(category: category) ?? [.banner, .list] }
        Self.current = self
    }

    /// Wywołać na początku `applicationDidFinishLaunching` — odpowiedź na kliknięcie powiadomienia,
    /// które uruchomiło aplikację, przychodzi zaraz potem.
    func activate() {
        center.setDelegate(delegate)
        center.setCategories(Self.categories)
        Task { await refreshAuthorization() }
    }

    /// Czy stałe połączenie zdarzeń serwera jest potrzebne (skan, odcinki, scalanie).
    var needsServerEvents: Bool {
        preferences.needsServerEvents && isAllowed
    }

    private var isAllowed: Bool {
        authorization == .authorized || authorization == .provisional
    }

    // MARK: Wybór i zgoda

    func refreshAuthorization() async {
        let previous = needsServerEvents
        authorization = await center.authorization()
        if previous != needsServerEvents { onNeedsServerEventsChanged?(needsServerEvents) }
    }

    /// Główny przełącznik. Przy pierwszym włączeniu system pyta o zgodę; po odmowie przełącznik
    /// zostaje wyłączony, a strona pokazuje odnośnik do Ustawień systemowych.
    func setEnabled(_ on: Bool) async {
        guard on else {
            update { $0.isEnabled = false }
            return
        }
        await refreshAuthorization()
        if authorization == .notDetermined {
            isRequesting = true
            defer { isRequesting = false }
            do {
                _ = try await center.requestAuthorization()
            } catch {
                logger.error("Prośba o zgodę na powiadomienia: \(error.localizedDescription, privacy: .public)")
            }
            await refreshAuthorization()
        }
        update { $0.isEnabled = isAllowed }
    }

    func set(_ kind: NotificationKind, _ on: Bool) {
        update { $0.set(kind, on) }
    }

    private func update(_ change: (inout NotificationPreferences) -> Void) {
        let previous = needsServerEvents
        change(&preferences)
        for (key, value) in preferences.stored { defaults.set(value, forKey: key) }
        if previous != needsServerEvents { onNeedsServerEventsChanged?(needsServerEvents) }
    }

    /// Ustawienia systemowe › Powiadomienia › Rapsod.
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "net.smigi.rapsod"
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
            ?? URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Wysyłanie

    /// Wysyła powiadomienie, jeśli użytkownik chce tego rodzaju, system pozwala, a okno, którego
    /// dotyczy, nie jest na wierzchu.
    func post(_ content: NotificationContent) {
        guard preferences.wants(content.kind), isAllowed else { return }
        guard shouldShow(content.kind) else {
            logger.info("Powiadomienie \(content.identifier, privacy: .public) pominięte — okno na wierzchu")
            return
        }
        Task { [center] in
            do {
                try await center.add(Self.request(content))
                logger.info("Powiadomienie \(content.identifier, privacy: .public): \(content.title, privacy: .public)")
            } catch {
                logger.error("Powiadomienie \(content.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated private static func request(_ content: NotificationContent) -> UNNotificationRequest {
        let body = UNMutableNotificationContent()
        body.title = content.title
        if let subtitle = content.subtitle { body.subtitle = subtitle }
        body.body = content.body
        body.threadIdentifier = content.threadIdentifier
        body.categoryIdentifier = content.kind.categoryIdentifier
        if let route = content.route { body.userInfo = [NotificationRoute.userInfoKey: route.userInfoValue] }
        // Zadania w tle bez dźwięku (HIG: dźwięk tylko, gdy wymaga uwagi); aktualizacja — z dźwiękiem.
        if content.kind == .appUpdate { body.sound = .default }
        return UNNotificationRequest(identifier: content.identifier, content: body, trigger: nil)
    }

    private func shouldShow(_ kind: NotificationKind) -> Bool {
        NotificationPresentation.shouldShow(kind: kind, appIsActive: NSApp.isActive,
                                            keyWindowID: NSApp.keyWindow?.identifier?.rawValue, relevantWindows: relevantWindows)
    }

    /// Powiadomienie przyszło, gdy aplikacja jest aktywna — bez tego system by go nie pokazał.
    private func presentation(category: String) -> UNNotificationPresentationOptions {
        guard let kind = NotificationKind(categoryIdentifier: category), !shouldShow(kind) else { return [.banner, .list] }
        return []
    }

    // MARK: Zdarzenia aplikacji

    func scanFinished(library: AudiobookshelfClient.Library, activity: LibraryTasks.Activity) {
        guard case .scan = activity.kind else { return }
        let outcome: ScanOutcome
        switch activity.phase {
        case .finished(let results, let canceled):
            outcome = .finished(results.map { ScanCounts(added: $0.added, updated: $0.updated, missing: $0.missing ?? $0.removed) },
                                canceled: canceled)
        case .failed(let message):
            outcome = .failed(message)
        case .requested, .running:
            return
        }
        guard let content = NotificationTexts.scan(libraryID: library.id, libraryName: library.name, outcome: outcome,
                                                   requestedHere: activity.requestedHere) else { return }
        post(content)
    }

    func episodeDownloaded(_ download: AudiobookshelfClient.EpisodeDownload) {
        guard preferences.wants(.newEpisodes), download.failed != true else { return }
        let episode = DownloadedEpisode(downloadID: download.id, itemID: download.libraryItemId, libraryID: download.libraryId,
                                        podcastTitle: download.podcastTitle, title: download.episodeDisplayTitle ?? "Odcinek",
                                        guid: download.guid)
        guard batcher.add(episode, at: .now) else { return }
        scheduleBatchFlush()
    }

    private func scheduleBatchFlush() {
        batchFlush?.cancel()
        guard let deadline = batcher.nextDeadline else { return }
        batchFlush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.1, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            for batch in batcher.drain(now: .now) { post(NotificationTexts.episodes(batch)) }
            scheduleBatchFlush()
        }
    }

    func uploadFinished(library: AudiobookshelfClient.Library, uploadedTitles: [String], failures: Int) {
        guard let content = NotificationTexts.upload(libraryID: library.id, libraryName: library.name,
                                                     uploadedTitles: uploadedTitles, failures: failures) else { return }
        post(content)
    }

    func mergeFinished(itemID: String, libraryID: String?, title: String?, failure: String?) {
        post(NotificationTexts.merge(itemID: itemID, libraryID: libraryID, itemTitle: title, failure: failure))
    }

    /// Nowa wersja. Zwraca `true`, gdy poszło powiadomienie — wtedy okno aktualizacji nie otwiera się samo.
    func updateFound(version: String, title: String?) -> Bool {
        guard preferences.wants(.appUpdate), isAllowed else { return false }
        post(NotificationTexts.update(version: version, title: title))
        return true
    }

    func sponsorSegmentsDetected(itemID: String, libraryID: String?, episodeID: String, podcastTitle: String?,
                                 episodeTitle: String?, count: Int, automatic: Bool) {
        guard preferences.wants(.sponsorSegments),
              sponsorGate.shouldNotify(key: "\(itemID)/\(episodeID)", segments: count, automatic: automatic) else { return }
        post(NotificationTexts.sponsorSegments(itemID: itemID, libraryID: libraryID, episodeID: episodeID,
                                               podcastTitle: podcastTitle, episodeTitle: episodeTitle, count: count))
    }

    // MARK: Kliknięcie

    private func respond(route: String?, action: String) {
        guard let route = NotificationRoute(userInfoValue: route) else {
            // Powiadomienie bez miejsca docelowego: samo kliknięcie aktywuje aplikację (robi to system).
            return
        }
        onRoute?(route, NotificationAction(rawValue: action))
    }

    /// Usuwa z Centrum powiadomień (tryb sprawdzający sprząta po sobie).
    func removeDelivered(_ identifiers: [String]) {
        center.removeDelivered(identifiers)
    }

    // MARK: Kategorie

    static var categories: Set<UNNotificationCategory> {
        Set(NotificationKind.allCases.map { kind in
            let actions = NotificationAction.actions(for: kind).map { action in
                switch action {
                // W tle: odtwarzanie rusza bez wysuwania okna.
                case .play: UNNotificationAction(identifier: action.rawValue, title: "Odtwarzaj", options: [])
                // Na pierwszym planie: okno aktualizacji pokazuje pobieranie i weryfikację.
                case .install: UNNotificationAction(identifier: action.rawValue, title: "Zainstaluj", options: [.foreground])
                }
            }
            return UNNotificationCategory(identifier: kind.categoryIdentifier, actions: actions, intentIdentifiers: [],
                                          hiddenPreviewsBodyPlaceholder: nil, categorySummaryFormat: nil, options: [])
        })
    }
}

// MARK: - Centrum powiadomień

/// `UNUserNotificationCenter` za protokołem: tryb sprawdzający podstawia zapis zamiast systemu,
/// gdy kopia testowa nie ma zgody (prośba o nią wymaga kliknięcia człowieka).
protocol NotificationCenterClient: Sendable {
    func authorization() async -> SystemNotifications.Authorization
    func requestAuthorization() async throws -> Bool
    func add(_ request: sending UNNotificationRequest) async throws
    func setCategories(_ categories: Set<UNNotificationCategory>)
    func setDelegate(_ delegate: NotificationDelegate)
    func removeDelivered(_ identifiers: [String])
}

struct SystemNotificationCenter: NotificationCenterClient {
    private var center: UNUserNotificationCenter { .current() }

    func authorization() async -> SystemNotifications.Authorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .ephemeral: .authorized
        case .provisional: .provisional
        @unknown default: .unknown
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func add(_ request: sending UNNotificationRequest) async throws {
        try await center.add(request)
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }

    func setDelegate(_ delegate: NotificationDelegate) {
        center.delegate = delegate
    }

    func removeDelivered(_ identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Delegat centrum powiadomień. Metody są `nonisolated` i wyciągają z powiadomienia same teksty
/// (Sendable), zanim przejdą na główny aktor — asynchroniczny delegat izolowany na głównym aktorze
/// to znana pułapka Swift 6 (system woła go z własnej kolejki).
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    // Ustawiane raz, przed `center.delegate = …`; potem tylko odczyt.
    @MainActor var onResponse: ((_ route: String?, _ action: String) -> Void)?
    @MainActor var presentation: ((_ category: String) -> UNNotificationPresentationOptions)?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let category = notification.request.content.categoryIdentifier
        return await MainActor.run { presentation?(category) ?? [.banner, .list] }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let route = response.notification.request.content.userInfo[NotificationRoute.userInfoKey] as? String
        let action = response.actionIdentifier
        await MainActor.run { onResponse?(route, action) }
    }
}
