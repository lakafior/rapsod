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
    /// Adres, który ostatnio odpowiedział — próbowany jako pierwszy.
    var lastWorkingURL: URL?
    var userID: String
    var username: String
    var deviceName: String?
    var keyID: String?

    /// Kolejność prób: ostatnio działający, potem sieć lokalna, potem spoza domu.
    var addressesToTry: [URL] {
        let ordered = addresses.enumerated()
            .sorted { (priority($0.element.kind), $0.offset) < (priority($1.element.kind), $1.offset) }
            .map(\.element.url)
        guard let lastWorkingURL, ordered.contains(lastWorkingURL) else { return ordered }
        return [lastWorkingURL] + ordered.filter { $0 != lastWorkingURL }
    }

    private func priority(_ kind: PairingPayload.Address.Kind) -> Int {
        switch kind {
        case .local: 0
        case .remote: 1
        case .other: 2
        }
    }

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

    /// Sesja z krótkim limitem: niedostępny adres lokalny poza domem nie może blokować minuty.
    static let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Zwykłe HTTP przepuszcza tylko sieć lokalna (ATS: `NSAllowsLocalNetworking`).
    static func isAllowedByATS(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        guard let host = url.host()?.lowercased() else { return false }
        if host.hasSuffix(".local") || !host.contains(".") || host == "localhost" { return true }
        // Adresy IP (IPv4 i IPv6) — ATS ich nie dotyczy.
        return host.allSatisfy { $0.isNumber || $0 == "." } || host.contains(":")
    }

    static func connect(urls: [URL], key: String) async throws -> Connection {
        var details: [String] = []
        for url in urls {
            guard isAllowedByATS(url) else {
                details.append("\(url.absoluteString): pominięty — poza siecią lokalną wymagany jest adres https.")
                continue
            }
            let client = AudiobookshelfClient(baseURL: url, session: probeSession)
            do {
                let user: AudiobookshelfClient.User = try await client.me(token: key)
                return Connection(url: url, user: user)
            } catch AudiobookshelfClient.APIError.unauthorized {
                throw ConnectError.keyRejected
            } catch AudiobookshelfClient.APIError.http(status: 403, _) {
                throw ConnectError.keyRejected
            } catch {
                details.append("\(url.absoluteString): \(error.localizedDescription)")
            }
        }
        throw ConnectError.unreachable(details: details)
    }
}
