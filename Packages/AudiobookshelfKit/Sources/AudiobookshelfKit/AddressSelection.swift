// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Wybór adresu serwera na telefonie (etap 10c). Zawsze najpierw sieć lokalna z krótkim limitem
/// czasu, potem adresy spoza domu (tunel) — bez pamiętania, który adres działał ostatnio.
/// Inaczej po jednym połączeniu przez tunel telefon używałby tunelu także w domu.
public enum AddressSelection {
    public struct Attempt: Sendable, Equatable {
        public let url: URL
        /// Limit czasu jednej próby.
        public let timeout: TimeInterval
    }

    /// Adres lokalny odpowiada w domu od razu; gdy go nie ma, nie warto czekać dłużej.
    public static let localTimeout: TimeInterval = 2.5
    /// Tunel przechodzi przez internet i bywa wolniejszy przy pierwszym zapytaniu.
    public static let remoteTimeout: TimeInterval = 8

    /// Kolejność prób: lokalne, potem spoza domu, na końcu nieznane rodzaje; w obrębie rodzaju
    /// kolejność z kodu parowania. Powtórzone adresy tylko raz.
    public static func attempts(for addresses: [PairingPayload.Address]) -> [Attempt] {
        var seen: Set<URL> = []
        return addresses.enumerated()
            .sorted { ($0.element.kind.priority, $0.offset) < ($1.element.kind.priority, $1.offset) }
            .compactMap { entry in
                guard seen.insert(entry.element.url).inserted else { return nil }
                return Attempt(url: entry.element.url, timeout: entry.element.kind == .local ? localTimeout : remoteTimeout)
            }
    }

    public enum Outcome<Value: Sendable>: Sendable {
        /// Ten adres odpowiedział.
        case reached(Value)
        /// Serwer odpowiedział, ale dalsze adresy nic nie zmienią (np. odrzucony klucz).
        case stop(any Error)
        /// Adres nie odpowiada — próbujemy następnego.
        case unreachable(String)
    }

    public struct Unreachable: Error, Sendable {
        /// Po jednym opisie na adres.
        public let details: [String]
    }

    /// Pierwszy adres, dla którego `probe` zwróci `.reached`. Próby idą po kolei, żeby adres
    /// lokalny zawsze wygrywał z tunelem, gdy oba działają.
    public static func firstReachable<Value: Sendable>(
        _ attempts: [Attempt],
        probe: (Attempt) async -> Outcome<Value>
    ) async throws -> (url: URL, value: Value) {
        var details: [String] = []
        for attempt in attempts {
            switch await probe(attempt) {
            case .reached(let value):
                return (attempt.url, value)
            case .stop(let error):
                throw error
            case .unreachable(let detail):
                details.append("\(attempt.url.absoluteString): \(detail)")
            }
        }
        throw Unreachable(details: details)
    }

    /// Czy błąd znaczy „nie ma połączenia z tym adresem” (warto spróbować innego adresu),
    /// a nie „serwer odpowiedział błędem”.
    public static func isConnectionError(_ error: any Error) -> Bool {
        // Tunel odpowiada sam, gdy Mac za nim nie działa (Cloudflare: 502, 521–523, 530).
        if case AudiobookshelfClient.APIError.http(let status, _) = error {
            return [502, 503, 504, 521, 522, 523, 530].contains(status)
        }
        guard let error = error as? URLError else { return false }
        return switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
             .notConnectedToInternet, .secureConnectionFailed, .cannotLoadFromNetwork, .internationalRoamingOff,
             .dataNotAllowed, .resourceUnavailable, .badServerResponse:
            true
        default:
            false
        }
    }
}
