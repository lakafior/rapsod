// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import AudiobookshelfKit

/// Sparowany serwer zapisany w `UserDefaults` — bez sekretu (klucz leży w pęku kluczy).
struct PairedServer: Codable, Equatable {
    /// Identyfikator z kodu parowania; przy wpisaniu ręcznym `nil`.
    var serverID: String?
    var serverName: String
    var addresses: [PairingPayload.Address]
    /// Adres, który ostatnio odpowiedział — tylko do pokazania; nie zmienia kolejności prób
    /// (etap 10c: po połączeniu przez tunel telefon wracał do tunelu także w domu).
    var lastWorkingURL: URL?
    var userID: String
    var username: String
    var deviceName: String?
    var keyID: String?

    /// Kolejność prób: zawsze najpierw sieć lokalna (krótki limit czasu), potem spoza domu.
    var attempts: [AddressSelection.Attempt] { AddressSelection.attempts(for: addresses) }

    private static let defaultsKey = "pairedServer"

    static func load() -> PairedServer? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(PairedServer.self, from: data)
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Jedno miejsce na klucz w pęku kluczy (na razie jeden sparowany serwer).
    static var secretStore: KeychainStore<AccountSecret> {
        KeychainStore(service: "net.smigi.abswift.ios.account", account: "paired-server")
    }
}

/// Szukanie działającego adresu: każdy adres po kolei, z krótkim limitem czasu.
enum Connector {
    struct Connection {
        let url: URL
        let user: AudiobookshelfClient.User
    }

    enum ConnectError: LocalizedError {
        /// Serwer odpowiedział, ale odrzucił klucz (unieważniony na Macu albo konto wyłączone).
        case keyRejected
        /// Żaden adres nie odpowiedział. `details` — po jednej linii na adres.
        case unreachable(details: [String])

        var errorDescription: String? {
            switch self {
            case .keyRejected:
                "Serwer odrzucił klucz tego telefonu — mógł zostać unieważniony na Macu. Sparuj telefon ponownie."
            case .unreachable(let details):
                "Serwer nie odpowiada. Sprawdź, czy Mac jest włączony, aplikacja AudiobookSwift działa, a telefon jest w tej samej sieci (albo czy działa dostęp spoza domu).\n\n" + details.joined(separator: "\n")
            }
        }
    }

    /// Sesje z limitem czasu jednej próby: niedostępny adres lokalny poza domem nie może
    /// blokować tunelu. Po jednej na limit, tworzone raz.
    @MainActor private static var probeSessions: [TimeInterval: URLSession] = [:]

    @MainActor static func probeSession(timeout: TimeInterval) -> URLSession {
        if let session = probeSessions[timeout] { return session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        probeSessions[timeout] = session
        return session
    }

    /// Zwykłe HTTP przepuszcza tylko sieć lokalna (ATS: `NSAllowsLocalNetworking`).
    static func isAllowedByATS(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        guard let host = url.host()?.lowercased() else { return false }
        if host.hasSuffix(".local") || !host.contains(".") || host == "localhost" { return true }
        // Adresy IP (IPv4 i IPv6) — ATS ich nie dotyczy.
        return host.allSatisfy { $0.isNumber || $0 == "." } || host.contains(":")
    }

    @MainActor static func connect(attempts: [AddressSelection.Attempt], key: String) async throws -> Connection {
        do {
            let found = try await AddressSelection.firstReachable(attempts) { attempt -> AddressSelection.Outcome<AudiobookshelfClient.User> in
                guard isAllowedByATS(attempt.url) else {
                    return .unreachable("pominięty — poza siecią lokalną wymagany jest adres https.")
                }
                let client = AudiobookshelfClient(baseURL: attempt.url, session: probeSession(timeout: attempt.timeout))
                do {
                    let user: AudiobookshelfClient.User = try await client.me(token: key)
                    return .reached(user)
                } catch AudiobookshelfClient.APIError.unauthorized {
                    return .stop(ConnectError.keyRejected)
                } catch AudiobookshelfClient.APIError.http(status: 403, _) {
                    return .stop(ConnectError.keyRejected)
                } catch {
                    return .unreachable(error.localizedDescription)
                }
            }
            return Connection(url: found.url, user: found.value)
        } catch let error as AddressSelection.Unreachable {
            throw ConnectError.unreachable(details: error.details)
        }
    }
}
