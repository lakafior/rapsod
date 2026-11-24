// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Zawartość kodu parowania telefonu z aplikacją na Macu (etap 10b).
///
/// Adres ma postać `rapsod://pair?d=<base64url JSON>`; JSON wygląda tak:
///
/// ```json
/// {"v":1,
///  "server":{"id":"…","name":"Mac mini"},
///  "addresses":[{"url":"http://mac-mini.local:13378","kind":"local"},
///               {"url":"https://ksiazki.example.com","kind":"remote"}],
///  "account":{"id":"…","username":"marek"},
///  "device":{"keyID":"…","name":"iPhone"},
///  "key":"<klucz API>"}
/// ```
///
/// Rozszerzanie formatu:
/// - `v` to wersja *niezgodna wstecz*. Nowe pole, które starszy telefon może pominąć,
///   nie podnosi wersji — dekoder ignoruje nieznane pola i nieznane rodzaje adresów.
///   Telefon odrzuca kod z wyższą wersją komunikatem „zaktualizuj aplikację”.
/// - Nowe rodzaje adresów (np. `relay`) dochodzą jako kolejne wartości `kind`; starszy
///   telefon trzyma je jako `.other` i próbuje na końcu.
///
/// Kod niesie klucz API bez terminu ważności — to sekret. Typ nie wypisuje go w opisie
/// (`description`), więc przypadkowe `print`/`Logger` go nie ujawni.
public struct PairingPayload: Codable, Sendable, Equatable {
    public static let scheme = "rapsod"
    public static let host = "pair"
    /// Najwyższa wersja formatu, którą ten kod rozumie.
    public static let currentVersion = 1

    public struct Server: Codable, Sendable, Equatable {
        /// Stały identyfikator instalacji serwera nadany przez aplikację na Macu
        /// (audiobookshelf nie ma własnego). Telefon rozpoznaje po nim ponowne parowanie.
        public var id: String
        /// Nazwa do pokazania (nazwa Maca).
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct Address: Codable, Sendable, Equatable, Hashable {
        public enum Kind: Sendable, Equatable, Hashable, Codable {
            /// Sieć lokalna (zwykłe HTTP do Maca).
            case local
            /// Spoza domu: tunel albo własny adres użytkownika.
            case remote
            /// Rodzaj z nowszej wersji aplikacji na Macu.
            case other(String)

            public var rawValue: String {
                switch self {
                case .local: "local"
                case .remote: "remote"
                case .other(let value): value
                }
            }

            public init(rawValue: String) {
                switch rawValue {
                case "local": self = .local
                case "remote": self = .remote
                default: self = .other(rawValue)
                }
            }

            public init(from decoder: any Decoder) throws {
                self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(rawValue)
            }

            /// Kolejność prób: najpierw sieć lokalna, potem spoza domu, na końcu nieznane.
            var priority: Int {
                switch self {
                case .local: 0
                case .remote: 1
                case .other: 2
                }
            }
        }

        public var url: URL
        public var kind: Kind

        public init(url: URL, kind: Kind) {
            self.url = url
            self.kind = kind
        }
    }

    public struct Account: Codable, Sendable, Equatable {
        /// Identyfikator konta słuchacza na serwerze.
        public var id: String
        public var username: String

        public init(id: String, username: String) {
            self.id = id
            self.username = username
        }
    }

    public struct Device: Codable, Sendable, Equatable {
        /// Identyfikator klucza API na serwerze (do unieważnienia z Maca).
        public var keyID: String
        /// Nazwa nadana telefonowi przy parowaniu.
        public var name: String

        public init(keyID: String, name: String) {
            self.keyID = keyID
            self.name = name
        }
    }

    public var version: Int
    public var server: Server
    public var addresses: [Address]
    public var account: Account
    public var device: Device
    public var key: String

    private enum CodingKeys: String, CodingKey {
        case version = "v", server, addresses, account, device, key
    }

    public init(server: Server, addresses: [Address], account: Account, device: Device, key: String) {
        version = Self.currentVersion
        self.server = server
        self.addresses = addresses
        self.account = account
        self.device = device
        self.key = key
    }

    /// Adresy w kolejności prób: lokalne, spoza domu, pozostałe (stabilnie w obrębie rodzaju).
    public var orderedAddresses: [Address] {
        addresses.enumerated()
            .sorted { ($0.element.kind.priority, $0.offset) < ($1.element.kind.priority, $1.offset) }
            .map(\.element)
    }

    // MARK: - Adres

    public enum DecodingError: Error, Equatable, LocalizedError {
        /// To nie jest adres `rapsod://pair`.
        case notPairingLink
        /// Uszkodzona zawartość (base64, JSON albo brak wymaganych pól).
        case malformed
        /// Kod z nowszej wersji aplikacji na Macu.
        case unsupportedVersion(Int)
        /// Brak klucza albo adresu http(s).
        case incomplete

        public var errorDescription: String? {
            switch self {
            case .notPairingLink: "To nie jest kod parowania Rapsod."
            case .malformed: "Kod parowania jest uszkodzony. Wygeneruj nowy na Macu."
            case .unsupportedVersion: "Kod pochodzi z nowszej wersji aplikacji na Macu. Zaktualizuj aplikację na telefonie."
            case .incomplete: "Kod parowania nie zawiera klucza albo adresu serwera."
            }
        }
    }

    /// Adres do zakodowania w kodzie QR.
    public func url() throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [URLQueryItem(name: "d", value: Self.base64URLEncoded(data))]
        guard let url = components.url else { throw DecodingError.malformed }
        return url
    }

    /// Odczytuje kod z adresu `rapsod://pair?d=…` i sprawdza, czy da się z nim połączyć.
    public init(url: URL) throws {
        guard url.scheme?.lowercased() == Self.scheme, url.host()?.lowercased() == Self.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DecodingError.notPairingLink
        }
        guard let value = components.queryItems?.first(where: { $0.name == "d" })?.value,
              let data = Self.base64URLDecoded(value) else {
            throw DecodingError.malformed
        }
        // Najpierw sama wersja: nowszy format może mieć inny kształt reszty.
        struct Versioned: Decodable { let v: Int }
        guard let versioned = try? JSONDecoder().decode(Versioned.self, from: data), versioned.v >= 1 else {
            throw DecodingError.malformed
        }
        guard versioned.v <= Self.currentVersion else {
            throw DecodingError.unsupportedVersion(versioned.v)
        }
        guard let payload = try? JSONDecoder().decode(Self.self, from: data) else {
            throw DecodingError.malformed
        }
        let usable = payload.addresses.filter(\.isHTTP)
        guard !payload.key.isEmpty, !usable.isEmpty else { throw DecodingError.incomplete }
        self = payload
        addresses = usable
    }

    /// Kod zeskanowany jako tekst (QR może nieść adres z odstępami na końcach).
    public init(string: String) throws {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DecodingError.notPairingLink
        }
        try self.init(url: url)
    }

    static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Przyjmuje base64url z dopełnieniem `=` i bez niego (oraz zwykłe base64).
    static func base64URLDecoded(_ text: String) -> Data? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 = base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

extension PairingPayload: CustomStringConvertible, CustomDebugStringConvertible {
    /// Bez klucza: opis może trafić do logów.
    public var description: String {
        "PairingPayload(v\(version), server: \(server.name), addresses: \(addresses.map(\.url.absoluteString)), account: \(account.username), device: \(device.name), key: <ukryty>)"
    }

    public var debugDescription: String { description }
}

extension PairingPayload.Address {
    /// Tylko pełne adresy http(s) z nazwą hosta nadają się do połączenia.
    public var isHTTP: Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return false }
        return url.host() != nil
    }
}
