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
        /// Adres w sieci lokalnej (wygrywa z tunelem, gdy oba działają).
        public let isLocal: Bool
    }

    /// Ile po starcie prób czekamy jeszcze na adres lokalny, gdy tunel już odpowiedział.
    /// W domu Mac odpowiada w ułamku sekundy; dłuższe czekanie tylko opóźnia start poza domem.
    public static let localGrace: Duration = .milliseconds(1200)

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
                let isLocal = entry.element.kind == .local
                return Attempt(url: entry.element.url, timeout: isLocal ? localTimeout : remoteTimeout, isLocal: isLocal)
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
        isolation: isolated (any Actor)? = #isolation,
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

    /// Bez Wi-Fi i kabla (sama sieć komórkowa) adresy lokalne są nieosiągalne — zostają tylko
    /// adresy spoza domu, o ile jakiś jest. Dzięki temu poza domem nie ma czekania na limit czasu.
    public static func usable(_ attempts: [Attempt], hasLocalNetwork: Bool) -> [Attempt] {
        guard !hasLocalNetwork else { return attempts }
        let remote = attempts.filter { !$0.isLocal }
        return remote.isEmpty ? attempts : remote
    }

    /// Wszystkie adresy sprawdzane jednocześnie; adres lokalny wygrywa, jeśli odpowie przed
    /// tunelem albo w ciągu `grace` od startu. W domu wybór jest natychmiastowy, w obcej sieci
    /// Wi-Fi kosztuje najwyżej `grace`, a nie sumę limitów czasu adresów lokalnych.
    ///
    /// Odmowa (`.stop`, np. odrzucony klucz) kończy wybór dopiero, gdy żaden adres nie odpowie:
    /// w obcej sieci pod adresem z domowej puli może stać inne urządzenie, które odmawia.
    public static func preferringLocal<Value: Sendable>(
        _ attempts: [Attempt],
        grace: Duration = localGrace,
        probe: @escaping @Sendable (Attempt) async -> Outcome<Value>
    ) async throws -> (url: URL, value: Value) {
        try await withThrowingTaskGroup(of: (index: Int, outcome: Outcome<Value>)?.self) { group in
            for (index, attempt) in attempts.enumerated() {
                group.addTask { (index, await probe(attempt)) }
            }
            // `nil` = minął czas przewagi adresów lokalnych.
            group.addTask {
                try? await Task.sleep(for: grace)
                return nil
            }
            var pendingLocal = Set(attempts.indices.filter { attempts[$0].isLocal })
            var remote: (url: URL, value: Value)?
            var graceOver = false
            var refusal: (any Error)?
            var details: [Int: String] = [:]
            for try await result in group {
                if let result {
                    let attempt = attempts[result.index]
                    pendingLocal.remove(result.index)
                    switch result.outcome {
                    case .reached(let value):
                        if attempt.isLocal {
                            group.cancelAll()
                            return (attempt.url, value)
                        }
                        if remote == nil { remote = (attempt.url, value) }
                    case .stop(let error):
                        if refusal == nil { refusal = error }
                    case .unreachable(let detail):
                        details[result.index] = "\(attempt.url.absoluteString): \(detail)"
                    }
                } else {
                    graceOver = true
                }
                if let remote, graceOver || pendingLocal.isEmpty {
                    group.cancelAll()
                    return remote
                }
            }
            if let remote { return remote }
            if let refusal { throw refusal }
            throw Unreachable(details: details.sorted { $0.key < $1.key }.map(\.value))
        }
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
