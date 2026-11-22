// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import OSLog
import AudiobookshelfKit

private let logger = Logger(subsystem: "net.smigi.abswift.ios", category: "Pairing")

/// Połączenie z sparowanym serwerem: klient pakietu z kluczem API i pamięć okładek.
@MainActor
final class ServerSession: Identifiable {
    let id = UUID()
    let server: PairedServer
    let baseURL: URL
    let auth: ListeningAuth
    let covers = CoverCache()

    init(server: PairedServer, baseURL: URL, key: String) {
        self.server = server
        self.baseURL = baseURL
        auth = ListeningAuth(client: AudiobookshelfClient(baseURL: baseURL), secret: .apiKey(key))
    }

    func cover(itemID: String, path: String?, size: CGFloat, scale: CGFloat) async -> PlatformImage? {
        await covers.image(itemID: itemID, path: path, pixels: Int(size * scale)) { [auth] width in
            try? await auth.perform { try await $0.cover(itemID: itemID, width: width, token: $1) }
        }
    }
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

    var pairedServerName: String? {
        if case .paired(let session) = phase { return session.server.serverName }
        return PairedServer.load()?.serverName
    }

    // MARK: - Start

    func start() async {
        guard case .loading = phase else { return }
        guard let server = PairedServer.load(), case .apiKey(let key)? = try? PairedServer.secretStore.load() else {
            phase = .unpaired
            return
        }
        // Ekran serwera od razu z ostatnim adresem; połączenie sprawdzamy w tle.
        let url = server.lastWorkingURL ?? server.addressesToTry.first ?? server.addresses[0].url
        phase = .paired(ServerSession(server: server, baseURL: url, key: key))
        await reconnect()
    }

    /// Ponowny wybór adresu (np. po wyjściu z domu albo powrocie do sieci domowej).
    func reconnect() async {
        guard case .paired(let session) = phase, case .apiKey(let key)? = try? PairedServer.secretStore.load() else { return }
        do {
            let connection = try await Connector.connect(urls: session.server.addressesToTry, key: key)
            var server = session.server
            server.lastWorkingURL = connection.url
            server.save()
            if connection.url != session.baseURL {
                phase = .paired(ServerSession(server: server, baseURL: connection.url, key: key))
            }
        } catch {
            logger.error("Ponowne połączenie: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
            if case Connector.ConnectError.keyRejected = error {
                // Klucz unieważniony: ponawianie nic nie da, zostaje rozłączenie i nowe parowanie.
                canRetry = false
                offersDisconnect = true
            } else {
                canRetry = true
                lastAttempt = { [weak self] in await self?.reconnect() }
            }
        }
    }

    // MARK: - Parowanie

    func handle(url: URL) {
        do {
            accept(try PairingPayload(url: url))
        } catch {
            self.error = error.localizedDescription
            canRetry = false
        }
    }

    func handle(scanned text: String) {
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

    /// Droga zapasowa: adres serwera i klucz API wpisane ręcznie.
    func pairManually(address: String, key: String) async {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), PairingPayload.Address(url: url, kind: .local).isHTTP, !key.isEmpty else {
            error = "Podaj pełny adres serwera (np. http://mac-mini.local:13378) i klucz API."
            canRetry = false
            return
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
        await connect(server: server, key: key) { [weak self] in await self?.pairManually(address: address, key: key) }
    }

    private func connect(server: PairedServer, key: String, retry: @escaping @MainActor () async -> Void) async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            let connection = try await Connector.connect(urls: server.addressesToTry, key: key)
            var server = server
            server.lastWorkingURL = connection.url
            server.userID = connection.user.id
            server.username = connection.user.username
            // Najpierw klucz, potem opis serwera: bez klucza zapis opisu nic by nie dał.
            try PairedServer.secretStore.save(.apiKey(key))
            server.save()
            phase = .paired(ServerSession(server: server, baseURL: connection.url, key: key))
            canRetry = false
            offersDisconnect = false
            lastAttempt = nil
        } catch {
            logger.error("Parowanie nieudane: \(error.localizedDescription, privacy: .public)")
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

    func retry() {
        guard let lastAttempt else { return }
        Task { await lastAttempt() }
    }

    // MARK: - Rozłączanie

    /// Usuwa klucz i opis serwera z telefonu. Klucz na serwerze unieważnia się na Macu.
    func disconnect() {
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
