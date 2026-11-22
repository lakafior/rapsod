// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Network
import OSLog
import AudiobookshelfKit

private let logger = Logger(subsystem: "net.smigi.abswift.ios", category: "Addresses")

/// Aktualizacja adresów sparowanego serwera bez ponownego parowania (etap 10c): z kodu
/// „Odśwież adresy” wyświetlonego na Macu albo z ogłoszenia Bonjour w sieci lokalnej.
/// Reguły scalania są w pakiecie (`AddressUpdate`); tu sprawdzenie adresu kluczem
/// i wyszukiwanie w sieci.
enum AddressRefresh {
    struct Outcome {
        let addresses: [PairingPayload.Address]
        let added: [URL]
        let removed: [URL]
    }

    /// Nowe adresy z `published`, sprawdzone kluczem; zwraca pełną listę do zapisania.
    @MainActor
    static func merge(server: PairedServer, lastWorking: URL?, published: [PairingPayload.Address], key: String) async -> Outcome {
        let plan = AddressUpdate.plan(current: server.addresses, lastWorking: lastWorking, published: published)
        for rejected in plan.rejected {
            logger.notice("Odrzucony adres \(rejected.url.absoluteString, privacy: .public): \(String(describing: rejected.reason), privacy: .public)")
        }
        let result = await AddressUpdate.apply(plan) { address in
            await verify(address, key: key, pairedUserID: server.userID)
        }
        let before = Set(server.addresses.map(\.url))
        let after = Set(result.map(\.url))
        return Outcome(addresses: result, added: result.map(\.url).filter { !before.contains($0) }, removed: server.addresses.map(\.url).filter { !after.contains($0) })
    }

    /// Ten sam serwer: klucz działa, a `/api/me` zwraca konto z parowania.
    @MainActor
    static func verify(_ address: PairingPayload.Address, key: String, pairedUserID: String) async -> AddressUpdate.Verification {
        guard Connector.isAllowedByATS(address.url) else { return .unreachable }
        let timeout = address.kind == .local ? AddressSelection.localTimeout : AddressSelection.remoteTimeout
        let client = AudiobookshelfClient(baseURL: address.url, session: Connector.probeSession(timeout: timeout))
        do {
            let user: AudiobookshelfClient.User = try await client.me(token: key, timeout: timeout)
            let result = AddressUpdate.verification(user: user, pairedUserID: pairedUserID, reachable: true)
            logger.notice("Sprawdzenie \(address.url.absoluteString, privacy: .public): \(String(describing: result), privacy: .public)")
            return result
        } catch AudiobookshelfClient.APIError.unauthorized {
            return .differentServer
        } catch AudiobookshelfClient.APIError.http(status: 403, _) {
            return .differentServer
        } catch {
            return .unreachable
        }
    }

    /// Szuka w sieci lokalnej ogłoszenia sparowanego serwera (`_abswift._tcp`) przez `timeout`
    /// sekund. Zwraca adresy z rekordów TXT z tym samym identyfikatorem serwera.
    @MainActor
    static func discover(serverID: String?, timeout: Duration = .seconds(3)) async -> [PairingPayload.Address] {
        guard let serverID, !serverID.isEmpty else { return [] }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LocalDiscovery.serviceType, domain: nil), using: .tcp)
        let found = FoundAddresses()
        browser.browseResultsChangedHandler = { results, _ in
            let addresses = results.compactMap { result -> PairingPayload.Address? in
                guard case .bonjour(let txt) = result.metadata else { return nil }
                return LocalDiscovery.address(fromTXT: txt.dictionary, pairedServerID: serverID)
            }
            found.set(addresses)
        }
        browser.start(queue: .main)
        try? await Task.sleep(for: timeout)
        browser.cancel()
        let addresses = found.get()
        if !addresses.isEmpty {
            logger.notice("Bonjour: \(addresses.map(\.url.absoluteString), privacy: .public)")
        }
        return addresses
    }
}

/// Wyniki przeglądarki Bonjour (wołana na kolejce głównej, czytane po jej zatrzymaniu).
private final class FoundAddresses: @unchecked Sendable {
    private let lock = NSLock()
    private var addresses: [PairingPayload.Address] = []

    func set(_ new: [PairingPayload.Address]) { lock.withLock { addresses = new } }
    func get() -> [PairingPayload.Address] { lock.withLock { addresses } }
}
