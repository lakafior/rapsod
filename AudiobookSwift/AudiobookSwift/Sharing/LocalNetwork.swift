import Darwin
import Foundation
import SystemConfiguration

/// Nazwy i adresy tego Maca w sieci lokalnej.
enum LocalNetwork {
    /// Nazwa komputera z Ustawień systemowych (np. „Mac mini — Marek”).
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
    }

    /// Nazwa mDNS z końcówką `.local` albo `nil`, gdy system jej nie ma.
    static var localHostName: String? {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
    }

    /// Adresy IPv4 aktywnych interfejsów, bez pętli zwrotnej, łączy punkt–punkt (VPN)
    /// i adresów link-local (169.254/16). IPv6 pomijamy: adresy tymczasowe zmieniają się
    /// co chwilę, a nazwa `.local` i tak rozwiązuje się także po IPv6.
    static func ipv4Addresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }

        var addresses: [String] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
                  let address = interface.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !text.hasPrefix("169.254."), !addresses.contains(text) {
                addresses.append(text)
            }
        }
        return addresses.sorted()
    }
}
