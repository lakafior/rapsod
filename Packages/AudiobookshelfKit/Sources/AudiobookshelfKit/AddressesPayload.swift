// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Kod „Odśwież adresy” (etap 10c): aktualne adresy sparowanego serwera bez klucza.
///
/// `abswift://addresses?d=<base64url JSON>`, JSON:
/// `{"v":1,"server":{"id":"…","name":"Mac mini"},"addresses":[{"url":"…","kind":"local"}]}`.
/// Nie jest sekretem — telefon przyjmuje go tylko dla serwera, z którym jest już sparowany
/// (ten sam `server.id`), a każdy nowy adres i tak sprawdza kluczem (`AddressUpdate`).
public struct AddressesPayload: Codable, Sendable, Equatable {
    public static let host = "addresses"
    public static let currentVersion = 1

    public var version: Int
    public var server: PairingPayload.Server
    public var addresses: [PairingPayload.Address]

    private enum CodingKeys: String, CodingKey {
        case version = "v", server, addresses
    }

    public init(server: PairingPayload.Server, addresses: [PairingPayload.Address]) {
        version = Self.currentVersion
        self.server = server
        self.addresses = addresses
    }

    public func url() throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var components = URLComponents()
        components.scheme = PairingPayload.scheme
        components.host = Self.host
        components.queryItems = [URLQueryItem(name: "d", value: PairingPayload.base64URLEncoded(try encoder.encode(self)))]
        guard let url = components.url else { throw PairingPayload.DecodingError.malformed }
        return url
    }

    /// Czy to adres kodu adresów (a nie kodu parowania).
    public static func matches(_ url: URL) -> Bool {
        url.scheme?.lowercased() == PairingPayload.scheme && url.host()?.lowercased() == host
    }

    public init(url: URL) throws {
        guard Self.matches(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PairingPayload.DecodingError.notPairingLink
        }
        guard let value = components.queryItems?.first(where: { $0.name == "d" })?.value,
              let data = PairingPayload.base64URLDecoded(value) else {
            throw PairingPayload.DecodingError.malformed
        }
        struct Versioned: Decodable { let v: Int }
        guard let versioned = try? JSONDecoder().decode(Versioned.self, from: data), versioned.v >= 1 else {
            throw PairingPayload.DecodingError.malformed
        }
        guard versioned.v <= Self.currentVersion else { throw PairingPayload.DecodingError.unsupportedVersion(versioned.v) }
        guard let payload = try? JSONDecoder().decode(Self.self, from: data), !payload.server.id.isEmpty else {
            throw PairingPayload.DecodingError.malformed
        }
        self = payload
        addresses = payload.addresses.filter(\.isHTTP)
    }
}

/// Ogłoszenie serwera w sieci lokalnej przez Bonjour (etap 10c). Mac ogłasza usługę
/// `_abswift._tcp` z identyfikatorem serwera i adresem w rekordzie TXT; telefon szuka jej,
/// gdy żaden zapisany adres lokalny nie odpowiada (np. Mac dostał nowy adres w sieci).
/// Ogłoszenie nie jest uwierzytelnione — to tylko propozycja adresu, sprawdzana kluczem.
public enum LocalDiscovery {
    public static let serviceType = "_abswift._tcp"
    /// Klucze rekordu TXT.
    public static let serverIDKey = "id"
    public static let urlKey = "url"
    public static let versionKey = "v"

    /// Rekord TXT ogłoszenia.
    public static func txtRecord(serverID: String, url: URL) -> [String: String] {
        [versionKey: "1", serverIDKey: serverID, urlKey: url.absoluteString]
    }

    /// Adres z rekordu TXT, jeśli należy do sparowanego serwera i jest lokalnym HTTP(S).
    public static func address(fromTXT txt: [String: String], pairedServerID: String?) -> PairingPayload.Address? {
        guard let pairedServerID, !pairedServerID.isEmpty, txt[serverIDKey] == pairedServerID,
              let text = txt[urlKey], let url = URL(string: text) else { return nil }
        let address = PairingPayload.Address(url: url, kind: .local)
        guard address.isHTTP, AddressUpdate.isLocalHost(url) else { return nil }
        return address
    }
}
