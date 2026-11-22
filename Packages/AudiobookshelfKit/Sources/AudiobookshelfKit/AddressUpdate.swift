// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Scalanie listy adresów, którą sparowany serwer opublikował po parowaniu (nowy tunel, zmieniony
/// adres w sieci lokalnej), z adresami zapisanymi na telefonie.
///
/// Reguły bezpieczeństwa:
/// - lista z zewnątrz to tylko propozycja — nowy adres trafia do zapisanych dopiero po sprawdzeniu
///   (`verify`), że odpowiada pod nim ten sam serwer, a klucz telefonu działa;
/// - zwykłe HTTP tylko dla adresów w sieci lokalnej (`.local`, nazwa bez kropki, prywatne IPv4,
///   lokalne IPv6), poza nią wyłącznie HTTPS; inne schematy odpadają;
/// - adres, który ostatnio działał, nigdy nie znika na podstawie samej listy;
/// - liczba adresów jest ograniczona.
///
/// Sposób dostarczenia listy na telefon jest osobną decyzją (serwer audiobookshelf nie ma
/// pola, które konto root może zapisać, a konto słuchacza odczytać) — tu tylko reguły.
public enum AddressUpdate {
    public static let maxAddresses = 8

    public enum Rejection: Equatable, Sendable {
        /// Schemat inny niż http/https.
        case scheme
        /// HTTP poza siecią lokalną.
        case insecureRemote
        /// Za dużo adresów na liście.
        case limit
    }

    public struct Plan: Equatable, Sendable {
        /// Zostają bez sprawdzania (były zapisane wcześniej i są na liście, albo ostatnio działały).
        public var keep: [PairingPayload.Address]
        /// Nowe — do sprawdzenia, zanim telefon ich użyje.
        public var toVerify: [PairingPayload.Address]
        /// Odrzucone z powodem.
        public var rejected: [Rejected]

        public struct Rejected: Equatable, Sendable {
            public let url: URL
            public let reason: Rejection
        }
    }

    /// Porównanie z listą serwera. `lastWorking` — adres, przez który telefon ostatnio rozmawiał
    /// z serwerem (zostaje zawsze, także gdy listy na nim nie ma).
    public static func plan(current: [PairingPayload.Address], lastWorking: URL?, published: [PairingPayload.Address]) -> Plan {
        var plan = Plan(keep: [], toVerify: [], rejected: [])
        var seen: Set<String> = []
        let currentByKey = Dictionary(current.map { (key($0.url), $0) }, uniquingKeysWith: { first, _ in first })

        for address in published {
            let k = key(address.url)
            guard seen.insert(k).inserted else { continue }
            guard let normalized = normalize(address) else {
                plan.rejected.append(.init(url: address.url, reason: rejection(for: address.url)))
                continue
            }
            if seen.count > maxAddresses {
                plan.rejected.append(.init(url: address.url, reason: .limit))
                continue
            }
            if let existing = currentByKey[k] {
                plan.keep.append(existing)
            } else {
                plan.toVerify.append(normalized)
            }
        }
        // Ostatnio działający adres zostaje, nawet gdy lista go nie zawiera.
        if let lastWorking, let existing = currentByKey[key(lastWorking)], !plan.keep.contains(existing) {
            plan.keep.insert(existing, at: 0)
        }
        // Lista nie może zostawić telefonu bez adresu.
        if plan.keep.isEmpty, plan.toVerify.isEmpty {
            plan.keep = current
        }
        return plan
    }

    /// Wynik sprawdzenia nowego adresu.
    public enum Verification: Sendable {
        /// Pod adresem odpowiada serwer, klucz działa, konto to samo co przy parowaniu.
        case sameServer
        /// Odpowiada inny serwer albo inne konto — adres odpada.
        case differentServer
        /// Teraz nieosiągalny (np. adres lokalny poza domem) — spróbujemy przy następnej liście.
        case unreachable
    }

    /// Nowa lista adresów: zachowane plus nowe, które przeszły sprawdzenie. Nieosiągalne
    /// i należące do innego serwera nie trafiają do zapisu.
    public static func apply(
        _ plan: Plan,
        isolation: isolated (any Actor)? = #isolation,
        verify: (PairingPayload.Address) async -> Verification
    ) async -> [PairingPayload.Address] {
        var result = plan.keep
        for address in plan.toVerify where result.count < maxAddresses {
            if case .sameServer = await verify(address) {
                result.append(address)
            }
        }
        return result
    }

    /// Ten sam serwer i to samo konto: klucz API jest podpisany sekretem serwera, który go wydał,
    /// więc inny serwer go odrzuci; zgodność konta wyklucza kopię z innym właścicielem.
    public static func verification(user: AudiobookshelfClient.User?, pairedUserID: String, reachable: Bool) -> Verification {
        guard reachable else { return .unreachable }
        guard let user, !pairedUserID.isEmpty, user.id == pairedUserID else { return .differentServer }
        return .sameServer
    }

    // MARK: Zasady adresów

    /// Adres z dozwolonym schematem; HTTP zawsze jako `.local`, a lokalność wynika z hosta,
    /// nie z rodzaju podanego na liście.
    static func normalize(_ address: PairingPayload.Address) -> PairingPayload.Address? {
        switch address.url.scheme?.lowercased() {
        case "https":
            return address
        case "http":
            guard isLocalHost(address.url) else { return nil }
            return .init(url: address.url, kind: .local)
        default:
            return nil
        }
    }

    private static func rejection(for url: URL) -> Rejection {
        url.scheme?.lowercased() == "http" ? .insecureRemote : .scheme
    }

    /// Host w sieci lokalnej: `.local`, nazwa bez kropki, prywatne IPv4 (10/8, 172.16/12,
    /// 192.168/16, 169.254/16) albo lokalne IPv6 (fe80::/10, fc00::/7). Publiczny adres IP
    /// i zwykła domena nie są lokalne, choć ATS przepuszcza HTTP do każdego adresu IP.
    public static func isLocalHost(_ url: URL) -> Bool {
        guard var host = url.host()?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".local") || host == "localhost" { return true }
        if host.contains(":") {
            return host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb")
                || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
        let parts = host.split(separator: ".")
        let octets = parts.compactMap { UInt8($0) }
        if octets.count == 4, parts.count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, let second): return (16...31).contains(second)
            default: return false
            }
        }
        return !host.contains(".")
    }

    /// Ten sam adres niezależnie od wielkości liter i końcowego ukośnika.
    private static func key(_ url: URL) -> String {
        var text = url.absoluteString.lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
