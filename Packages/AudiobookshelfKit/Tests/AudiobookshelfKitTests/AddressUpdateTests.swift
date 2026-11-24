// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
import AudiobookshelfKit

@Suite struct AddressUpdateTests {
    private func a(_ text: String, _ kind: PairingPayload.Address.Kind = .local) -> PairingPayload.Address {
        .init(url: URL(string: text)!, kind: kind)
    }

    private let home = URL(string: "http://mac.local:13378")!

    @Test func newTunnelIsVerifiedBeforeUse() {
        let plan = AddressUpdate.plan(
            current: [a("http://mac.local:13378")],
            lastWorking: home,
            published: [a("http://mac.local:13378"), a("https://ksiazki.example.com", .remote)]
        )
        #expect(plan.keep == [a("http://mac.local:13378")])
        #expect(plan.toVerify == [a("https://ksiazki.example.com", .remote)])
        #expect(plan.rejected.isEmpty)
    }

    @Test func httpOnlyInLocalNetwork() {
        let plan = AddressUpdate.plan(current: [a("http://mac.local:13378")], lastWorking: home, published: [
            a("http://example.com:13378", .remote),
            a("http://8.8.8.8:13378", .local),
            a("http://192.168.1.20:13378", .remote),
            a("ftp://mac.local/x"),
            a("https://abs.example.com", .remote),
        ])
        #expect(plan.rejected.map(\.reason) == [.insecureRemote, .insecureRemote, .scheme])
        // Adres prywatny po HTTP przechodzi, ale jako lokalny niezależnie od rodzaju z listy.
        #expect(plan.toVerify == [a("http://192.168.1.20:13378", .local), a("https://abs.example.com", .remote)])
    }

    @Test func localHosts() {
        for text in ["http://mac.local", "http://mini", "http://10.0.0.2", "http://172.20.1.1", "http://192.168.0.5",
                     "http://169.254.3.4", "http://[fe80::1]", "http://[fd12::5]", "http://localhost"] {
            #expect(AddressUpdate.isLocalHost(URL(string: text)!), "\(text)")
        }
        for text in ["http://172.32.0.1", "http://8.8.8.8", "http://example.com", "http://[2001:db8::1]", "http://192.168.1"] {
            #expect(!AddressUpdate.isLocalHost(URL(string: text)!), "\(text)")
        }
    }

    @Test func lastWorkingAddressIsNeverDroppedByTheList() {
        // Lista bez tunelu, a telefon właśnie przez niego rozmawia (poza domem).
        let tunnel = a("https://ksiazki.example.com", .remote)
        let plan = AddressUpdate.plan(current: [a("http://mac.local:13378"), tunnel], lastWorking: tunnel.url, published: [a("http://mac.local:13378")])
        #expect(plan.keep.contains(tunnel))
        #expect(plan.keep.contains(a("http://mac.local:13378")))
        // Adres nieobecny na liście i nieostatnio działający odpada.
        let stale = AddressUpdate.plan(current: [a("http://192.168.1.9:13378"), a("http://mac.local:13378")], lastWorking: home, published: [a("http://mac.local:13378")])
        #expect(stale.keep == [a("http://mac.local:13378")])
    }

    @Test func emptyOrHostileListKeepsCurrentAddresses() {
        let current = [a("http://mac.local:13378")]
        #expect(AddressUpdate.plan(current: current, lastWorking: nil, published: []).keep == current)
        let hostile = AddressUpdate.plan(current: current, lastWorking: nil, published: [a("http://evil.example.com", .local)])
        #expect(hostile.keep == current)
        #expect(hostile.toVerify.isEmpty)
    }

    @Test func duplicatesAndLimit() {
        let many = (1...12).map { a("https://h\($0).example.com", .remote) }
        let plan = AddressUpdate.plan(current: [], lastWorking: nil, published: many + [a("https://H1.example.com/", .remote)])
        #expect(plan.toVerify.count == AddressUpdate.maxAddresses)
        #expect(plan.rejected.filter { $0.reason == .limit }.count == 4)
    }

    @Test func onlyVerifiedNewAddressesAreAdded() async {
        let plan = AddressUpdate.plan(current: [a("http://mac.local:13378")], lastWorking: home, published: [
            a("http://mac.local:13378"),
            a("https://ten-sam.example.com", .remote),
            a("https://inny.example.com", .remote),
            a("http://192.168.1.30:13378"),
        ])
        let result = await AddressUpdate.apply(plan) { address in
            switch address.url.host() {
            case "ten-sam.example.com": .sameServer
            case "inny.example.com": .differentServer
            default: .unreachable
            }
        }
        #expect(result.map(\.url.absoluteString) == ["http://mac.local:13378", "https://ten-sam.example.com"])
    }

    @Test func sameServerMeansSameAccount() throws {
        let user = try JSONDecoder().decode(AudiobookshelfClient.User.self, from: Data(#"{"id":"u1","username":"mar","type":"user"}"#.utf8))
        #expect(AddressUpdate.verification(user: user, pairedUserID: "u1", reachable: true) == .sameServer)
        #expect(AddressUpdate.verification(user: user, pairedUserID: "u2", reachable: true) == .differentServer)
        #expect(AddressUpdate.verification(user: nil, pairedUserID: "u1", reachable: true) == .differentServer)
        #expect(AddressUpdate.verification(user: user, pairedUserID: "", reachable: true) == .differentServer)
        #expect(AddressUpdate.verification(user: nil, pairedUserID: "u1", reachable: false) == .unreachable)
    }
}

@Suite struct AddressesPayloadTests {
    @Test func roundTripWithoutKey() throws {
        let payload = AddressesPayload(
            server: .init(id: "srv-1", name: "Mac mini"),
            addresses: [.init(url: URL(string: "http://mini.local:13378")!, kind: .local),
                        .init(url: URL(string: "https://ksiazki.example.com")!, kind: .remote)]
        )
        let url = try payload.url()
        #expect(url.absoluteString.hasPrefix("rapsod://addresses?d="))
        #expect(AddressesPayload.matches(url))
        #expect(try AddressesPayload(url: url) == payload)
        // Kod adresów to nie kod parowania i odwrotnie.
        #expect(throws: PairingPayload.DecodingError.self) { try PairingPayload(url: url) }
        #expect(!url.absoluteString.contains("key"))
    }

    @Test func rejectsNewerVersionAndMissingServer() throws {
        func link(_ json: String) -> URL {
            URL(string: "rapsod://addresses?d=" + Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: ""))!
        }
        #expect(throws: PairingPayload.DecodingError.unsupportedVersion(2)) {
            try AddressesPayload(url: link(#"{"v":2,"server":{"id":"a","name":"b"},"addresses":[]}"#))
        }
        #expect(throws: PairingPayload.DecodingError.malformed) {
            try AddressesPayload(url: link(#"{"v":1,"server":{"id":"","name":"b"},"addresses":[]}"#))
        }
        let filtered = try AddressesPayload(url: link(#"{"v":1,"server":{"id":"a","name":"b"},"addresses":[{"url":"ftp://x","kind":"local"},{"url":"http://mini.local","kind":"local"}]}"#))
        #expect(filtered.addresses.map(\.url.absoluteString) == ["http://mini.local"])
    }

    @Test func bonjourRecordOnlyForPairedServerAndLocalHost() {
        let txt = LocalDiscovery.txtRecord(serverID: "srv-1", url: URL(string: "http://mini.local:13378")!)
        #expect(LocalDiscovery.address(fromTXT: txt, pairedServerID: "srv-1")?.url.absoluteString == "http://mini.local:13378")
        #expect(LocalDiscovery.address(fromTXT: txt, pairedServerID: "srv-2") == nil)
        #expect(LocalDiscovery.address(fromTXT: txt, pairedServerID: nil) == nil)
        let remote = LocalDiscovery.txtRecord(serverID: "srv-1", url: URL(string: "http://example.com")!)
        #expect(LocalDiscovery.address(fromTXT: remote, pairedServerID: "srv-1") == nil)
    }
}
