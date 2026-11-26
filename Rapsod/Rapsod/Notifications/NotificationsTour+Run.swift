#if DEBUG
import AppIntents
import AppKit
import AudiobookshelfKit
import RapsodIntegration
import UniformTypeIdentifiers

/// Przebieg trybu `-ABSNotificationsTour YES` (etap 14e). Kopia testowa (`-ABSDataRoot`, `-ABSPort`)
/// dzieli `UserDefaults` z prawdziwą aplikacją, więc tryb zapisuje klucze, które zmienia
/// (`notifications.*`, `libraryWindow.*`, `settings.lastPage`), i przywraca je na koniec.
///
/// Argumenty:
/// - `-ABSNotificationsTourBooks <folder>` — folder z plikami audio: gdy serwer nie ma biblioteki,
///   staje się biblioteką; podfolder z niego trafia do biblioteki przed skanem i jest wgrywany.
/// - `-ABSNotificationsTourFeed <adres>` — kanał RSS (np. z lokalnego `python3 -m http.server`):
///   dodanie podcastu akcją Skrótów i pobranie odcinka na serwer (prawdziwe zdarzenie pobierania).
/// - `-ABSNotificationsTourPodcasts <folder>` — folder biblioteki podcastów, gdy jej nie ma.
///
/// Zrzuty: wiersz `NTOUR shot <nazwa> <numer okna>` i 2 s przerwy (zrzut robi skrypt z zewnątrz).
@MainActor
extension NotificationsTour {
    private static var started = false

    static func run(_ app: AppDelegate) async {
        guard isRequested, !started else { return }
        started = true
        let defaults = UserDefaults.standard
        let prefixes = ["notifications.", "libraryWindow."]
        let exact = [SettingsNavigation.lastPageKey]
        let saved = defaults.dictionaryRepresentation().filter { key, _ in prefixes.contains { key.hasPrefix($0) } || exact.contains(key) }
        defer {
            for key in defaults.dictionaryRepresentation().keys where prefixes.contains(where: { key.hasPrefix($0) }) || exact.contains(key) {
                defaults.removeObject(forKey: key)
            }
            for (key, value) in saved { defaults.set(value, forKey: key) }
            log("defaults restored (\(saved.count) keys)")
        }

        // Kliknięcie powiadomienia, które uruchomiło aplikację: zanim cokolwiek jest gotowe.
        let coldItem = UserDefaults.standard.string(forKey: "ABSNotificationsTourColdItem")
        app.follow(.update(version: "9.9.9"), action: nil)
        if let coldItem { app.follow(.item(itemID: coldItem, libraryID: nil), action: .play) }
        await pause(2)
        log("cold route update → window \(window(UpdateWindow.windowID) != nil)")
        window(UpdateWindow.windowID)?.close()

        guard await prepare(app) else { log("FAIL prepare"); return }
        if let coldItem {
            for _ in 0..<20 where app.listening.player.book == nil { await pause(0.5) }
            log("cold route play → \(app.listening.player.book?.itemID == coldItem ? "OK" : "nothing") \(app.listening.player.book?.title ?? "-")")
            await app.listening.stopPlayback()
        }
        await resume(app)
        await settingsPage(app)
        await scans(app)
        await upload(app)
        await merge(app)
        await podcast(app)
        await simulated(app)
        await intents(app)
        await routes(app)
        await serverStopped(app)

        let recorded = center.recorded
        log("recorded \(recorded.count): \(recorded.joined(separator: ", "))")
        log("forwarded to system: \(center.forwarded.count)")
        app.notifications.removeDelivered(recorded)
        log("OK")
    }

    // MARK: Przygotowanie

    private static func prepare(_ app: AppDelegate) async -> Bool {
        for _ in 0..<240 where app.account.state != .ready { await pause(0.5) }
        guard app.account.state == .ready else { return false }
        if app.account.libraries.isEmpty, let books = folderArgument("ABSNotificationsTourBooks") {
            log("adding library \(books.path)")
            await app.account.addLibrary(folder: books)
        }
        if case .missing = app.account.userState {
            log("creating listener")
            do { try await app.account.setUpUser(username: "sluchacz", password: "") } catch { log("listener: \(error)") }
        }
        for _ in 0..<240 where !(app.listening.availability == .ready && !app.listening.libraries.isEmpty) { await pause(0.5) }
        log("ready libraries=\(app.account.libraries.map(\.name)) listener=\(app.listening.availability == .ready)")
        return app.listening.availability == .ready
    }

    // MARK: Kontynuowanie bez wczytanej pozycji

    /// Dłuższe nagranie (`-ABSNotificationsTourLong <tytuł>`): 5 s słuchania, zatrzymanie, potem
    /// „Odtwarzaj lub wstrzymaj” i „Kontynuuj” bez niczego w odtwarzaczu.
    private static func resume(_ app: AppDelegate) async {
        guard let title = UserDefaults.standard.string(forKey: "ABSNotificationsTourLong") else { return }
        if (try? await BookQuery().entities(matching: title).first) == nil,
           let library = app.account.libraries.first(where: { $0.mediaType != "podcast" }) {
            app.libraryTasks.scan(library, force: false)
            await waitForScan(app, library.id)
        }
        guard let book = try? await BookQuery().entities(matching: title).first else { log("resume: no long book"); return }
        await app.listening.play(itemID: book.id, at: 30)
        await pause(5)
        await app.listening.stopPlayback()
        await pause(1)
        log("resume: loaded=\(app.listening.player.book != nil)")
        await run("PlayPause (nothing loaded)", PlayPauseIntent())
        await pause(2)
        log("resume: \(app.listening.player.book?.title ?? "-") playing=\(app.listening.player.isPlaying) at \(Int(app.listening.player.currentTime)) s")
        await app.listening.stopPlayback()
        await run("ContinueListening (nothing loaded)", ContinueListeningIntent())
        await pause(2)
        log("resume: \(app.listening.player.book?.title ?? "-") playing=\(app.listening.player.isPlaying) at \(Int(app.listening.player.currentTime)) s")
        await app.listening.stopPlayback()
    }

    // MARK: Strona ustawień

    private static func settingsPage(_ app: AppDelegate) async {
        app.notifications.set(.sponsorSegments, false)
        await app.notifications.setEnabled(false)
        app.settingsNavigation.page = .notifications
        app.menuBar.open(.settings(nil))
        await pause(2.5)
        // Odmowa w systemie: przełącznik zostaje wyłączony, strona prowadzi do Ustawień systemowych.
        center.forced = .denied
        await app.notifications.setEnabled(true)
        await pause(1.5)
        log("denied: enabled=\(app.notifications.preferences.isEnabled) authorization=\(app.notifications.authorization)")
        if let window = window(SettingsWindow.windowID) { await shot("ustawienia-odmowa", window) }
        center.forced = .authorized
        await app.notifications.refreshAuthorization()
        log("monitor running (disabled): \(app.activityMonitor.isRunning)")
        if let window = window(SettingsWindow.windowID) { await shot("ustawienia-wylaczone", window) }
        await app.notifications.setEnabled(true)
        app.notifications.set(.sponsorSegments, true)
        await pause(1.5)
        log("enabled=\(app.notifications.preferences.isEnabled) monitor running: \(app.activityMonitor.isRunning)")
        if let window = window(SettingsWindow.windowID) {
            await shot("ustawienia-wlaczone", window)
            NSApp.appearance = NSAppearance(named: .darkAqua)
            await pause(1)
            await shot("ustawienia-ciemne", window)
            NSApp.appearance = nil
        }
    }

    // MARK: Skan

    private static func scans(_ app: AppDelegate) async {
        guard let library = app.account.libraries.first(where: { $0.mediaType != "podcast" }) else { return }
        // 1. Okno ustawień na wierzchu: powiadomienia ma nie być.
        window(SettingsWindow.windowID)?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        await pause(1)
        log("key window: \(NSApp.keyWindow?.identifier?.rawValue ?? "-") active=\(NSApp.isActive)")
        let before = center.recorded.count
        app.libraryTasks.scan(library, force: false)
        await waitForScan(app, library.id)
        log("scan with settings key: notifications +\(center.recorded.count - before) (expected 0)")

        // 2. Okno zamknięte, nowa książka w folderze biblioteki: powiadomienie z liczbą dodanych.
        window(SettingsWindow.windowID)?.close()
        if let source = folderArgument("ABSNotificationsTourBooks"), let folder = library.folders.first {
            let target = URL(filePath: folder.fullPath).appending(path: "Skan 14e \(stamp)")
            copyFirstAudio(from: source, to: target, title: "Skan 14e")
        }
        await pause(1)
        app.libraryTasks.scan(library, force: false)
        await waitForScan(app, library.id)
        await waitForNotification("scan-\(library.id)", after: before, timeout: 10)
    }

    private static func waitForScan(_ app: AppDelegate, _ libraryID: String) async {
        await pause(1)
        for _ in 0..<120 where app.libraryTasks.isRunning(libraryID) { await pause(0.5) }
        await pause(2)
        log("scan phase: \(String(describing: app.libraryTasks.activities[libraryID]?.phase))")
    }

    // MARK: Wgrywanie

    private static func upload(_ app: AppDelegate) async {
        guard let source = folderArgument("ABSNotificationsTourBooks") else { log("upload: no folder"); return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "Wgrane 14e \(stamp)")
        copyFirstAudio(from: source, to: folder, title: "Wgrane 14e")
        app.menuBar.openLibrary(.upload([folder]))
        var model: UploadModel?
        for _ in 0..<60 {
            model = app.menuBar.browser?.upload
            if let model, !model.entries.isEmpty, !model.isScanning { break }
            await pause(0.5)
        }
        guard let model, !model.entries.isEmpty else { log("upload: no sheet"); return }
        model.entries[0].title = "Wgrane 14e \(stamp)"
        model.entries[0].author = "Tryb sprawdzający"
        if let window = window(LibraryWindow.windowID) { await shot("wgrywanie-arkusz", window) }
        let before = center.recorded.count
        // Okno Biblioteka na wierzchu tłumi powiadomienie o wgraniu — schowanie aplikacji je przywraca.
        model.begin()
        NSApp.hide(nil)
        for _ in 0..<120 where model.isRunning || model.entries.contains(where: { if case .uploading = $0.status { true } else { false } }) {
            await pause(0.5)
        }
        await waitForNotification("upload-", after: before, timeout: 10)
        NSApp.unhide(nil)
        await pause(1)
        if let window = window(LibraryWindow.windowID) { app.menuBar.browser?.showsUpload = false; window.close() }
    }

    // MARK: Scalanie do M4B

    private static func merge(_ app: AppDelegate) async {
        guard let library = app.account.libraries.first(where: { $0.mediaType != "podcast" }),
              let page = try? await app.account.withAdminToken({
                  try await $0.itemsPage(libraryID: library.id, page: 0, limit: 50, sort: "addedAt", descending: true, filter: nil, token: $1)
              }),
              let item = page.results.elements.first(where: { $0.title.hasPrefix("Skan 14e") }) ?? page.results.elements.first
        else { log("merge: no item"); return }
        let before = center.recorded.count
        do {
            try await app.account.withAdminToken { try await $0.encodeM4b(itemID: item.id, options: .init(), token: $1) }
            log("merge requested \(item.title)")
        } catch {
            log("merge request: \(error.localizedDescription)")
            return
        }
        await waitForNotification("merge-\(item.id)", after: before, timeout: 180)
    }

    // MARK: Podcast i pobranie odcinka

    private static func podcast(_ app: AppDelegate) async {
        guard let feed = UserDefaults.standard.string(forKey: "ABSNotificationsTourFeed"), let feedURL = URL(string: feed) else {
            log("podcast: no feed"); return
        }
        if !app.account.libraries.contains(where: { $0.mediaType == "podcast" }), let folder = folderArgument("ABSNotificationsTourPodcasts") {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            await app.account.addLibrary(folder: folder, kind: .podcasts)
            for _ in 0..<40 where !app.listening.libraries.contains(where: { $0.mediaType == "podcast" }) {
                await app.listening.refresh()
                await pause(0.5)
            }
            log("podcast library: \(app.account.libraries.filter { $0.mediaType == "podcast" }.map(\.name))")
        }
        var intent = AddPodcastIntent()
        intent.feedURL = feedURL
        intent.autoDownload = false
        let podcastID: String
        do {
            let result = try await intent.perform()
            podcastID = result.value?.id ?? ""
            log("intent AddPodcast OK id=\(podcastID)")
        } catch {
            log("intent AddPodcast error: \(message(error))")
            guard let existing = try? await IntentBridge.search("14e", podcasts: true).first else { return }
            podcastID = existing.id
        }
        // Drugi raz — czytelny błąd o istniejącym podcaście.
        do { _ = try await intent.perform(); log("intent AddPodcast again: no error?") } catch { log("intent AddPodcast again: \(message(error))") }

        guard !podcastID.isEmpty else { return }
        let before = center.recorded.count
        do {
            let parsed = try await app.account.withAdminToken { try await $0.podcastFeed(url: feed, token: $1) }
            try await app.account.withAdminToken { try await $0.downloadEpisodes(itemID: podcastID, Array(parsed.episodes.prefix(2)), token: $1) }
            log("episodes queued: \(min(2, parsed.episodes.count))")
        } catch {
            log("download episodes: \(error.localizedDescription)")
            return
        }
        await waitForNotification("episodes-\(podcastID)", after: before, timeout: 90)
    }

    // MARK: Zdarzenia bez źródła w kopii testowej

    /// Aktualizacji nie ma w wydaniach (repozytorium prywatne), a segmenty sponsorowane wymagają
    /// prawdziwego odcinka z reklamą — te dwie treści idą prosto przez `SystemNotifications`.
    private static func simulated(_ app: AppDelegate) async {
        let before = center.recorded.count
        let shown = app.notifications.updateFound(version: "9.9.9", title: "Rapsod 9.9.9")
        log("update notification instead of window: \(shown)")
        app.notifications.sponsorSegmentsDetected(itemID: "pod", libraryID: nil, episodeID: "ep", podcastTitle: "Podcast testowy",
                                                  episodeTitle: "Odcinek 1", count: 2, automatic: true)
        // Drugi przebieg (model) tego samego odcinka i ręczne wykrywanie — bez powiadomień.
        app.notifications.sponsorSegmentsDetected(itemID: "pod", libraryID: nil, episodeID: "ep", podcastTitle: "Podcast testowy",
                                                  episodeTitle: "Odcinek 1", count: 3, automatic: true)
        app.notifications.sponsorSegmentsDetected(itemID: "pod", libraryID: nil, episodeID: "ep2", podcastTitle: "Podcast testowy",
                                                  episodeTitle: "Odcinek 2", count: 3, automatic: false)
        await pause(1)
        log("simulated: +\(center.recorded.count - before) (expected 2)")
    }

    // MARK: Akcje Skrótów

    private static func intents(_ app: AppDelegate) async {
        let books = (try? await BookQuery().suggestedEntities()) ?? []
        log("BookQuery suggested: \(books.prefix(5).map(\.title))")
        let query = books.first.map { String($0.title.prefix(4)) } ?? "a"
        let matched = (try? await BookQuery().entities(matching: query)) ?? []
        log("BookQuery matching '\(query)': \(matched.prefix(5).map(\.title))")
        let ids = (try? await BookQuery().entities(for: matched.prefix(2).map(\.id))) ?? []
        log("BookQuery for ids: \(ids.map(\.title))")
        let libraries = (try? await LibraryQuery().suggestedEntities()) ?? []
        log("LibraryQuery: \(libraries.map(\.name))")
        let podcasts = (try? await PodcastQuery().suggestedEntities()) ?? []
        log("PodcastQuery suggested: \(podcasts.map(\.title))")
        let episodes = (try? await EpisodeQuery().entities(matching: podcasts.first.map { String($0.title.prefix(5)) } ?? "x")) ?? []
        log("EpisodeQuery matching: \(episodes.prefix(5).map { "\($0.title) — \($0.podcastTitle ?? "")" })")

        var scan = ScanLibrariesIntent()
        scan.libraries = Array(libraries.prefix(1))
        await run("ScanLibraries", scan)

        if let book = matched.first ?? books.first {
            var play = PlayBookIntent()
            play.book = book
            await run("PlayBook", play)
            await pause(3)
            log("playing: \(app.listening.player.book?.title ?? "-") \(app.listening.player.isPlaying)")
            var forward = SkipForwardIntent()
            forward.seconds = 60
            let start = app.listening.player.currentTime
            await run("SkipForward 60", forward)
            await pause(0.5)
            log("position \(Int(start)) → \(Int(app.listening.player.currentTime))")
            await run("SkipBackward", SkipBackwardIntent())
            await run("PlayPause (pause)", PlayPauseIntent())
            log("isPlaying: \(app.listening.player.isPlaying)")
            await run("ContinueListening", ContinueListeningIntent())
            log("isPlaying: \(app.listening.player.isPlaying)")
            app.listening.player.pause()

            var open = OpenBookIntent()
            open.book = book
            await run("OpenBook", open)
            await pause(3)
            if let window = window(LibraryWindow.windowID) { await shot("skrot-otworz-ksiazke", window) }
        }
        if let episode = episodes.first {
            var play = PlayEpisodeIntent()
            play.episode = episode
            await run("PlayEpisode", play)
            await pause(2)
            log("playing: \(app.listening.player.book?.title ?? "-")")
            app.listening.player.pause()
        }
        if let podcast = podcasts.first {
            var open = OpenPodcastIntent()
            open.podcast = podcast
            await run("OpenPodcast", open)
            await pause(3)
            if let window = window(LibraryWindow.windowID) { await shot("skrot-otworz-podcast", window) }
        }
        if let source = folderArgument("ABSNotificationsTourBooks"), let audio = firstAudio(in: source) {
            var upload = UploadBookIntent()
            upload.files = [IntentFile(fileURL: audio, filename: audio.lastPathComponent, type: UTType(filenameExtension: audio.pathExtension))]
            await run("UploadBook", upload)
            await pause(3)
            log("upload sheet entries: \(app.menuBar.browser?.upload?.entries.map(\.title) ?? [])")
            if let window = window(LibraryWindow.windowID) { await shot("skrot-wgraj", window) }
            app.menuBar.browser?.showsUpload = false
        }
        window(LibraryWindow.windowID)?.close()
        await pause(1)
    }

    private static func run<I: AppIntent>(_ name: String, _ intent: I) async {
        do {
            _ = try await intent.perform()
            log("intent \(name) OK")
        } catch {
            log("intent \(name) error: \(message(error))")
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? IntentError).map { String(localized: $0.localizedStringResource) } ?? error.localizedDescription
    }

    // MARK: Kliknięcia w powiadomienia

    private static func routes(_ app: AppDelegate) async {
        if let library = app.account.libraries.first {
            app.follow(.librarySettings(libraryID: library.id), action: nil)
            await pause(3)
            if let window = window(SettingsWindow.windowID) { await shot("klik-skan", window) }
            window(SettingsWindow.windowID)?.close()
        }
        if let item = try? await BookQuery().suggestedEntities().first {
            app.follow(.item(itemID: item.id, libraryID: item.libraryID), action: nil)
            await pause(3)
            log("route item → path \(String(describing: app.menuBar.browser?.path))")
            app.follow(.item(itemID: item.id, libraryID: item.libraryID), action: .play)
            await pause(3)
            log("route play → \(app.listening.player.book?.title ?? "-") \(app.listening.player.isPlaying)")
            app.listening.player.pause()
        }
        if let podcast = try? await PodcastQuery().suggestedEntities().first,
           let detail = try? await app.listening.api({ try await $0.item(id: podcast.id, token: $1) }),
           let episode = detail.media.episodes?.elements.last {
            // Jak z powiadomienia o pobraniu: bez identyfikatora odcinka, tylko guid i tytuł.
            app.follow(.episode(itemID: podcast.id, libraryID: podcast.libraryID, episodeID: nil, guid: episode.guid, title: episode.title),
                       action: .play)
            await pause(3)
            log("route episode play → \(app.listening.player.book?.title ?? "-") (expected \(episode.title ?? "-"))")
            app.listening.player.pause()
        }
        app.follow(.update(version: "9.9.9"), action: nil)
        await pause(2)
        log("route update → window \(window(UpdateWindow.windowID) != nil)")
        window(UpdateWindow.windowID)?.close()
        window(LibraryWindow.windowID)?.close()
    }

    // MARK: Serwer zatrzymany

    private static func serverStopped(_ app: AppDelegate) async {
        if let title = UserDefaults.standard.string(forKey: "ABSNotificationsTourLong"),
           let book = try? await BookQuery().entities(matching: title).first {
            await app.listening.play(itemID: book.id, at: 60)
            await pause(4)
        }
        await app.listening.stopPlayback()
        await app.supervisor.stop()
        IntentBridge.launchDate = .distantPast
        await run("ContinueListening (server stopped)", ContinueListeningIntent())
        await run("ScanLibraries (server stopped)", ScanLibrariesIntent())
        log("monitor running (server stopped): \(app.activityMonitor.isRunning)")
        app.supervisor.start()
        let begin = Date.now
        await run("ContinueListening (server starting)", ContinueListeningIntent())
        log("waited \(Int(Date.now.timeIntervalSince(begin))) s; monitor running: \(app.activityMonitor.isRunning); playing \(app.listening.player.book?.title ?? "-") at \(Int(app.listening.player.currentTime)) s")
        app.listening.player.pause()
    }

    // MARK: Pomocnicze

    private static let stamp: String = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        return formatter.string(from: .now)
    }()

    private static func waitForNotification(_ prefix: String, after count: Int, timeout: Double) async {
        var waited = 0.0
        while waited < timeout {
            if center.recorded.dropFirst(count).contains(where: { $0.hasPrefix(prefix) }) {
                log("notification \(prefix) after \(Int(waited)) s")
                return
            }
            await pause(0.5)
            waited += 0.5
        }
        log("FAIL no notification \(prefix) in \(Int(timeout)) s")
    }

    private static func folderArgument(_ key: String) -> URL? {
        UserDefaults.standard.string(forKey: key).map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    private static func firstAudio(in folder: URL) -> URL? {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { UploadModel.audio.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }.first
    }

    /// Nowa książka: jeden plik audio z `source` w nowym folderze.
    private static func copyFirstAudio(from source: URL, to folder: URL, title: String) {
        guard let audio = firstAudio(in: source) else { log("no audio in \(source.path)"); return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: audio, to: folder.appending(path: "\(title).\(audio.pathExtension)"))
        } catch {
            log("copy: \(error.localizedDescription)")
        }
    }

    private static func window(_ id: String) -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == id && $0.isVisible }
    }

    private static func shot(_ name: String, _ window: NSWindow) async {
        log("shot \(name) \(window.windowNumber)")
        await pause(2)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
#endif
