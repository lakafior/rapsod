// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Network
import Observation
import OSLog
import UIKit
import AudiobookshelfKit
import AudiobookshelfPlayback

private let logger = Logger(subsystem: "net.smigi.abswift.ios", category: "Pairing")

/// Połączenie z sparowanym serwerem: klient pakietu z kluczem API i pamięć okładek.
@MainActor
final class ServerSession: Identifiable {
    let id = UUID()
    let server: PairedServer
    let baseURL: URL
    let auth: ListeningAuth
    let covers = CoverCache()
    /// Biblioteki połączone w jedną, postęp i zdarzenia serwera (etap 10d).
    let library: LibraryStore

    init(server: PairedServer, baseURL: URL, key: String, podcasts: PodcastContext) {
        self.server = server
        self.baseURL = baseURL
        auth = ListeningAuth(client: AudiobookshelfClient(baseURL: baseURL), secret: .apiKey(key))
        library = LibraryStore(auth: auth, playback: podcasts.playback, localEpisodes: podcasts.localEpisodes, feeds: podcasts.feeds)
    }

    func cover(itemID: String, path: String?, size: CGFloat, scale: CGFloat) async -> PlatformImage? {
        await covers.image(itemID: itemID, path: path, pixels: Int(size * scale)) { [auth] width in
            try? await auth.perform { try await $0.cover(itemID: itemID, width: width, token: $1) }
        }
    }
}

/// To, co żyje dłużej niż jedno połączenie, a potrzebne jest podcastom sesji: odtwarzacz,
/// lokalny postęp odcinków (jeden plik na serwer — dwie kopie magazynu nadpisywałyby się nawzajem)
/// i pamięć kanałów RSS.
@MainActor
struct PodcastContext {
    let playback: PlaybackCoordinator
    let localEpisodes: LocalEpisodeStore
    let feeds: PodcastFeedLoader
}

/// Stan aplikacji: niesparowana, łączenie, sparowana.
@MainActor
@Observable
final class AppModel {
    enum Phase {
        case loading
        case unpaired
        case paired(ServerSession)
    }

    private(set) var phase: Phase = .loading
    private(set) var isConnecting = false
    var error: String?
    /// Nowy kod, gdy telefon jest już sparowany — czeka na potwierdzenie.
    var pendingReplacement: PairingPayload?
    /// Ostatnia nieudana próba da się powtórzyć (np. po zgodzie na dostęp do sieci lokalnej).
    private(set) var canRetry = false
    /// Sparowany serwer odrzucił klucz — alert proponuje rozłączenie.
    private(set) var offersDisconnect = false
    @ObservationIgnored private var lastAttempt: (@MainActor () async -> Void)?
    /// Automatyczna próba połączenia (zmiana sieci, błąd w trakcie słuchania) się nie udała —
    /// pasek „Brak połączenia” zamiast alertu.
    private(set) var isOffline = false
    /// Wyniki ostatniej próby połączenia, adres po adresie („Diagnostyka połączenia”).
    private(set) var connectionAttempts: [Connector.AttemptResult] = []
    private(set) var connectionAttemptDate: Date?
    /// Wynik odświeżenia adresów z kodu „Odśwież adresy” (komunikat bez błędu).
    var notice: String?

    /// Odtwarzacz żyje ponad połączeniem: przejście sieć lokalna ↔ tunel podmienia `ServerSession`,
    /// a słuchanie trwa dalej.
    let playback: PlaybackCoordinator
    @ObservationIgnored private let audio: AudioSessionController
    /// Lokalny postęp odcinków, według serwera.
    @ObservationIgnored private var localEpisodeStores: [String: LocalEpisodeStore] = [:]
    @ObservationIgnored private let feeds = PodcastFeedLoader(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appending(path: "PodcastFeeds")
    )
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var pathChange: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var lastAutomaticReconnect: Date?
    /// Telefon jest w sieci Wi-Fi albo na kablu. Bez tego (sama sieć komórkowa) adresy lokalne
    /// są pomijane i telefon łączy się od razu przez adres spoza domu.
    @ObservationIgnored private var hasLocalNetwork = true

    var currentSession: ServerSession? {
        if case .paired(let session) = phase { return session }
        return nil
    }

    init() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let device = AudiobookshelfClient.DeviceInfo(
            deviceId: Self.deviceID(),
            clientName: "AudiobookSwift",
            clientVersion: version,
            manufacturer: "Apple",
            model: UIDevice.current.model
        )
        playback = PlaybackCoordinator(device: device) { nil }
        audio = AudioSessionController(player: playback.player)
        playback.authProvider = { [weak self] in self?.currentSession?.auth }
        playback.coverLoader = { [weak self] itemID, _ in
            await self?.currentSession?.cover(itemID: itemID, path: nil, size: 600, scale: 1)
        }
        playback.beginBackgroundWork = { AudioSessionController.beginBackgroundWork($0) }
        playback.onConnectionError = { [weak self] in self?.connectionTroubled() }
        playback.onServerReached = { [weak self] in
            if self?.isOffline == true { self?.isOffline = false }
        }
        startPathMonitor()
    }

    /// Stały identyfikator tego telefonu dla serwera: nowa sesja tego samego urządzenia zamyka
    /// poprzednią, więc musi się różnić od Maca i nie zmieniać przy każdym uruchomieniu.
    private static func deviceID() -> String {
        let key = "playbackDeviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = "abswift-ios-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    var pairedServerName: String? {
        if case .paired(let session) = phase { return session.server.serverName }
        return PairedServer.load()?.serverName
    }

    // MARK: - Start

    func start() async {
        restoreIfNeeded()
        await reconnect()
    }

    /// Odtwarza zapisane parowanie (synchronicznie). Wołane też przed obsługą adresu
    /// `abswift://`, bo system może uruchomić aplikację od zera właśnie tym adresem —
    /// wtedy `onOpenURL` przychodzi przed `start()`, a pytanie o zastąpienie parowania
    /// musi już wiedzieć, że telefon jest sparowany.
    private func restoreIfNeeded() {
        guard case .loading = phase else { return }
        guard let server = PairedServer.load(), !server.addresses.isEmpty,
              case .apiKey(let key)? = try? PairedServer.secretStore.load() else {
            phase = .unpaired
            return
        }
        // Ekran serwera od razu z pierwszym adresem (lokalnym); połączenie sprawdzamy w tle.
        let url = server.attempts.first?.url ?? server.addresses[0].url
        phase = .paired(makeSession(server: server, baseURL: url, key: key))
    }

    /// Ponowny wybór adresu: zawsze od sieci lokalnej. `silent` — próba automatyczna (zmiana sieci,
    /// powrót do aplikacji, błąd w trakcie słuchania): bez alertu, najwyżej pasek „Brak połączenia”.
    func reconnect(silent: Bool = false) async {
        if let reconnectTask {
            await reconnectTask.value
            return
        }
        let task = Task { await performReconnect(silent: silent) }
        reconnectTask = task
        await task.value
        reconnectTask = nil
    }

    private func performReconnect(silent: Bool, discovering: Bool = true) async {
        guard case .paired(let session) = phase, case .apiKey(let key)? = try? PairedServer.secretStore.load() else { return }
        do {
            let connection = try await Connector.connect(attempts: usableAttempts(for: session.server), key: key)
            recordAttempts()
            // W trakcie prób użytkownik mógł się rozłączyć albo sparować telefon od nowa.
            guard isCurrent(session) else { return }
            var server = session.server
            server.lastWorkingURL = connection.url
            server.save()
            isOffline = false
            let changed = connection.url != session.baseURL
            if changed {
                logger.notice("Nowy adres serwera: \(connection.url.absoluteString, privacy: .public)")
                phase = .paired(makeSession(server: server, baseURL: connection.url, key: key))
            }
            await playback.connectionChanged(baseURLChanged: changed)
            // Połączenie poza siecią lokalną: może Mac jest obok, tylko pod nowym adresem.
            let isLocal = server.addresses.first { $0.url == connection.url }?.kind == .local
            if discovering, !isLocal, await discoverLocalAddress(key: key) {
                await performReconnect(silent: true, discovering: false)
            }
        } catch {
            recordAttempts()
            guard isCurrent(session) else { return }
            logger.error("Ponowne połączenie: \(error.localizedDescription, privacy: .public)")
            if case Connector.ConnectError.keyRejected = error {
                // Klucz unieważniony: ponawianie nic nie da, zostaje rozłączenie i nowe parowanie.
                self.error = error.localizedDescription
                canRetry = false
                offersDisconnect = true
                return
            }
            if discovering, await discoverLocalAddress(key: key) {
                await performReconnect(silent: silent, discovering: false)
                return
            }
            isOffline = true
            if !silent {
                self.error = error.localizedDescription
                canRetry = true
                lastAttempt = { [weak self] in await self?.reconnect() }
            }
        }
    }

    private func usableAttempts(for server: PairedServer) -> [AddressSelection.Attempt] {
        AddressSelection.usable(server.attempts, hasLocalNetwork: hasLocalNetwork)
    }

    private func recordAttempts() {
        connectionAttempts = Connector.lastAttempts
        connectionAttemptDate = Connector.lastAttemptDate
    }

    // MARK: - Adresy serwera bez ponownego parowania

    /// Bonjour: Mac ogłasza adres z identyfikatorem serwera. Nowy adres trafia do zapisanych
    /// dopiero po sprawdzeniu kluczem; zwraca `true`, gdy coś dodano.
    private func discoverLocalAddress(key: String) async -> Bool {
        guard case .paired(let session) = phase else { return false }
        let found = await AddressRefresh.discover(serverID: session.server.serverID)
        let new = found.filter { candidate in !session.server.addresses.contains { $0.url == candidate.url } }
        guard !new.isEmpty, isCurrent(session) else { return false }
        // Lista = obecne + znalezione: z Bonjour niczego nie usuwamy.
        let outcome = await AddressRefresh.merge(server: session.server, lastWorking: session.server.lastWorkingURL, published: session.server.addresses + new, key: key)
        guard !outcome.added.isEmpty, isCurrent(session) else { return false }
        save(addresses: outcome.addresses, in: session, key: key)
        logger.notice("Bonjour: dodano \(outcome.added.map(\.absoluteString), privacy: .public)")
        return true
    }

    private func handleAddresses(url: URL) {
        do {
            let payload = try AddressesPayload(url: url)
            Task { await applyAddresses(payload) }
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Kod „Odśwież adresy” z Maca: przyjmowany tylko dla sparowanego serwera, każdy nowy
    /// adres sprawdzany kluczem, ostatnio działający adres zostaje.
    func applyAddresses(_ payload: AddressesPayload) async {
        guard case .paired(let session) = phase, case .apiKey(let key)? = try? PairedServer.secretStore.load() else {
            notice = "Ten kod tylko aktualizuje adresy sparowanego serwera. Najpierw sparuj telefon kodem parowania."
            return
        }
        guard let serverID = session.server.serverID, serverID == payload.server.id else {
            notice = "Kod pochodzi z innego serwera („\(payload.server.name)”). Żeby przełączyć telefon, sparuj go z tamtym Makiem."
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        let outcome = await AddressRefresh.merge(server: session.server, lastWorking: session.server.lastWorkingURL ?? session.baseURL, published: payload.addresses, key: key)
        guard isCurrent(session) else { return }
        save(addresses: outcome.addresses, in: session, key: key)
        var lines: [String] = []
        if !outcome.added.isEmpty { lines.append("Dodane: " + outcome.added.map(\.absoluteString).joined(separator: ", ")) }
        if !outcome.removed.isEmpty { lines.append("Usunięte: " + outcome.removed.map(\.absoluteString).joined(separator: ", ")) }
        let skipped = payload.addresses.count - outcome.addresses.filter { address in payload.addresses.contains { $0.url == address.url } }.count
        if skipped > 0 { lines.append("Pominięte (nieosiągalne teraz albo niedozwolone): \(skipped)") }
        notice = lines.isEmpty ? "Adresy serwera są aktualne." : lines.joined(separator: "\n")
        await performReconnect(silent: true, discovering: false)
    }

    private func save(addresses: [PairingPayload.Address], in session: ServerSession, key: String) {
        var server = session.server
        server.addresses = addresses
        server.save()
        phase = .paired(makeSession(server: server, baseURL: session.baseURL, key: key))
    }

    /// Zapytanie (np. synchronizacja postępu) nie doszło do serwera: może zmieniła się sieć.
    /// Nie częściej niż co 10 s, żeby przy braku sieci nie próbować bez końca.
    func connectionTroubled() {
        if let lastAutomaticReconnect, Date.now.timeIntervalSince(lastAutomaticReconnect) < 10 { return }
        lastAutomaticReconnect = .now
        Task { await reconnect(silent: true) }
    }

    /// Zmiana sieci (Wi-Fi ↔ komórkowa, inna sieć Wi-Fi): adres sprawdzany od nowa,
    /// najpierw lokalny. Krótkie odczekanie, bo system zgłasza kilka zmian pod rząd.
    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let local = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                self?.hasLocalNetwork = local
                self?.pathChanged(satisfied: satisfied)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "net.smigi.abswift.ios.path"))
    }

    private func pathChanged(satisfied: Bool) {
        pathChange?.cancel()
        guard satisfied, currentSession != nil else {
            if !satisfied { isOffline = currentSession != nil }
            return
        }
        pathChange = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            lastAutomaticReconnect = .now
            await reconnect(silent: true)
        }
    }

    /// Nowe połączenie z serwerem; odtwarzacz zapisuje lokalny postęp odcinków do magazynu tego serwera.
    private func makeSession(server: PairedServer, baseURL: URL, key: String) -> ServerSession {
        let scope = server.serverID ?? server.addresses.first?.url.absoluteString ?? "serwer"
        let store: LocalEpisodeStore
        if let existing = localEpisodeStores[scope] {
            store = existing
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appending(path: "LocalEpisodeProgress")
            store = LocalEpisodeStore(fileURL: directory?.appending(path: Self.fileName(scope)))
            localEpisodeStores[scope] = store
        }
        playback.localEpisodes = store
        return ServerSession(server: server, baseURL: baseURL, key: key, podcasts: PodcastContext(playback: playback, localEpisodes: store, feeds: feeds))
    }

    /// Stała nazwa pliku z identyfikatora serwera (FNV-1a) — bez adresu w nazwie.
    private static func fileName(_ scope: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in scope.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16) + ".json"
    }

    private func isCurrent(_ session: ServerSession) -> Bool {
        if case .paired(let current) = phase { return current.id == session.id }
        return false
    }

    // MARK: - Parowanie

    func handle(url: URL) {
        restoreIfNeeded()
        if AddressesPayload.matches(url) {
            handleAddresses(url: url)
            return
        }
        do {
            accept(try PairingPayload(url: url))
        } catch {
            self.error = error.localizedDescription
            canRetry = false
        }
    }

    func handle(scanned text: String) {
        restoreIfNeeded()
        if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), AddressesPayload.matches(url) {
            handleAddresses(url: url)
            return
        }
        do {
            accept(try PairingPayload(string: text))
        } catch {
            self.error = error.localizedDescription
            canRetry = false
        }
    }

    private func accept(_ payload: PairingPayload) {
        if case .paired = phase {
            pendingReplacement = payload
            return
        }
        Task { await pair(payload) }
    }

    func confirmReplacement(_ payload: PairingPayload) {
        pendingReplacement = nil
        Task { await pair(payload) }
    }

    func pair(_ payload: PairingPayload) async {
        logger.notice("Parowanie: \(payload.description, privacy: .public)")
        let server = PairedServer(
            serverID: payload.server.id,
            serverName: payload.server.name,
            addresses: payload.orderedAddresses,
            userID: payload.account.id,
            username: payload.account.username,
            deviceName: payload.device.name,
            keyID: payload.device.keyID
        )
        await connect(server: server, key: payload.key) { [weak self] in await self?.pair(payload) }
    }

    /// Droga zapasowa: adres serwera i klucz API wpisane ręcznie. Zwraca komunikat błędu
    /// (pokazywany w formularzu, który zostaje otwarty) albo `nil` po udanym połączeniu.
    func pairManually(address: String, key: String) async -> String? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), PairingPayload.Address(url: url, kind: .local).isHTTP, !key.isEmpty else {
            return "Podaj pełny adres serwera (np. http://mac-mini.local:13378) i klucz API."
        }
        let host = url.host() ?? text
        let kind: PairingPayload.Address.Kind = Connector.isAllowedByATS(url) && url.scheme == "http" ? .local : .remote
        let server = PairedServer(
            serverID: nil,
            serverName: host,
            addresses: [.init(url: url, kind: kind)],
            userID: "",
            username: "",
            deviceName: nil,
            keyID: nil
        )
        do {
            try await connect(server: server, key: key)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Parowanie z kodu: błąd trafia do alertu, z możliwością ponowienia.
    private func connect(server: PairedServer, key: String, retry: @escaping @MainActor () async -> Void) async {
        do {
            try await connect(server: server, key: key)
            canRetry = false
            lastAttempt = nil
        } catch {
            self.error = error.localizedDescription
            if case Connector.ConnectError.keyRejected = error {
                canRetry = false
            } else {
                // Pierwsze zapytanie w sieci lokalnej bywa odrzucone, zanim użytkownik odpowie
                // na systemowe pytanie o dostęp do sieci lokalnej — stąd „Spróbuj ponownie”.
                canRetry = true
                lastAttempt = retry
            }
        }
    }

    private func connect(server: PairedServer, key: String) async throws {
        isConnecting = true
        defer { isConnecting = false }
        do {
            let connection = try await Connector.connect(attempts: usableAttempts(for: server), key: key)
            var server = server
            server.lastWorkingURL = connection.url
            server.userID = connection.user.id
            server.username = connection.user.username
            // Najpierw klucz, potem opis serwera: bez klucza zapis opisu nic by nie dał.
            try PairedServer.secretStore.save(.apiKey(key))
            server.save()
            if playback.player.book != nil { await playback.stop() }
            phase = .paired(makeSession(server: server, baseURL: connection.url, key: key))
            offersDisconnect = false
            isOffline = false
        } catch {
            logger.error("Parowanie nieudane: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func retry() {
        guard let lastAttempt else { return }
        Task { await lastAttempt() }
    }

    // MARK: - Rozłączanie

    /// Usuwa klucz i opis serwera z telefonu. Klucz na serwerze unieważnia się na Macu.
    func disconnect() {
        guard playback.player.book != nil else {
            forgetServer()
            return
        }
        // Pozycja na serwer, zanim zniknie klucz (bez sieci nie ma po co czekać).
        Task {
            if isOffline { playback.player.stop() } else { await playback.stop() }
            forgetServer()
        }
    }

    private func forgetServer() {
        do {
            try PairedServer.secretStore.delete()
        } catch {
            logger.error("Usuwanie klucza: \(error.localizedDescription, privacy: .public)")
        }
        PairedServer.forget()
        offersDisconnect = false
        phase = .unpaired
    }
}
