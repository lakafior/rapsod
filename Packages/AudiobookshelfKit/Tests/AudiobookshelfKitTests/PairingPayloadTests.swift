// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
import AudiobookshelfKit

/// Format kodu parowania `rapsod://pair?d=…` (etap 10b).
@Suite struct PairingPayloadTests {
    private let sample = PairingPayload(
        server: .init(id: "srv-1", name: "Mac mini Marka"),
        addresses: [
            .init(url: URL(string: "https://ksiazki.example.com")!, kind: .remote),
            .init(url: URL(string: "http://mac-mini.local:13378")!, kind: .local),
            .init(url: URL(string: "http://192.168.1.20:13378")!, kind: .local),
        ],
        account: .init(id: "user-1", username: "marek"),
        device: .init(keyID: "key-1", name: "iPhone / ąę"),
        key: "eyJhbGciOiJIUzI1NiJ9.eyJ0eXBlIjoiYXBpIn0.podpis+/="
    )

    /// Adres z ręcznie napisanym JSON-em (tak jak zrobiłaby to inna wersja aplikacji).
    private func link(json: String, padded: Bool = false) -> URL {
        var text = Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        if !padded { text = text.replacingOccurrences(of: "=", with: "") }
        return URL(string: "rapsod://pair?d=\(text)")!
    }

    @Test func roundTrip() throws {
        let url = try sample.url()
        #expect(url.scheme == "rapsod")
        #expect(url.host() == "pair")
        // base64url bez dopełnienia: nic do escapowania w adresie i w kodzie QR.
        let value = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
        #expect(!value.contains("=") && !value.contains("+") && !value.contains("/"))
        #expect(try PairingPayload(url: url) == sample)
        #expect(try PairingPayload(string: "  \(url.absoluteString)\n") == sample)
    }

    @Test func addressesAreOrderedLocalFirst() {
        let kinds = sample.orderedAddresses.map(\.kind)
        #expect(kinds == [.local, .local, .remote])
        // W obrębie rodzaju zostaje kolejność z kodu.
        #expect(sample.orderedAddresses.first?.url.host() == "mac-mini.local")
    }

    @Test func descriptionHidesKey() {
        #expect(!sample.description.contains(sample.key))
        #expect(!String(reflecting: sample).contains(sample.key))
    }

    @Test func acceptsPaddedAndIgnoresUnknownFields() throws {
        let json = """
        {"v":1,"future":{"x":1},"server":{"id":"s","name":"Mac","extra":true},
         "addresses":[{"url":"http://mac.local:13378","kind":"local","priority":3},
                      {"url":"https://relay.example.com","kind":"relay"}],
         "account":{"id":"u","username":"ola"},"device":{"keyID":"k","name":"iPad"},"key":"K"}
        """
        for padded in [false, true] {
            let payload = try PairingPayload(url: link(json: json, padded: padded))
            #expect(payload.key == "K")
            #expect(payload.addresses.map(\.kind) == [.local, .other("relay")])
        }
    }

    @Test func rejectsNewerVersion() {
        let json = #"{"v":2,"completely":"different"}"#
        #expect(throws: PairingPayload.DecodingError.unsupportedVersion(2)) {
            try PairingPayload(url: link(json: json))
        }
    }

    @Test func rejectsForeignAndBrokenLinks() {
        #expect(throws: PairingPayload.DecodingError.notPairingLink) {
            try PairingPayload(url: URL(string: "https://example.com/pair?d=abc")!)
        }
        #expect(throws: PairingPayload.DecodingError.notPairingLink) {
            try PairingPayload(url: URL(string: "rapsod://other?d=abc")!)
        }
        #expect(throws: PairingPayload.DecodingError.malformed) {
            try PairingPayload(url: URL(string: "rapsod://pair")!)
        }
        #expect(throws: PairingPayload.DecodingError.malformed) {
            try PairingPayload(url: URL(string: "rapsod://pair?d=%21%21%21")!)
        }
        #expect(throws: PairingPayload.DecodingError.malformed) {
            try PairingPayload(url: link(json: "nie json"))
        }
        #expect(throws: PairingPayload.DecodingError.malformed) {
            try PairingPayload(url: link(json: #"{"v":0}"#))
        }
        // Wersja się zgadza, ale brakuje wymaganych pól.
        #expect(throws: PairingPayload.DecodingError.malformed) {
            try PairingPayload(url: link(json: #"{"v":1,"key":"K"}"#))
        }
    }

    @Test func rejectsMissingKeyOrHTTPAddress() {
        let noKey = """
        {"v":1,"server":{"id":"s","name":"Mac"},"addresses":[{"url":"http://mac.local","kind":"local"}],
         "account":{"id":"u","username":"ola"},"device":{"keyID":"k","name":"iPad"},"key":""}
        """
        #expect(throws: PairingPayload.DecodingError.incomplete) { try PairingPayload(url: link(json: noKey)) }

        // Adres innego schematu (np. `file:`) jest odrzucany, a gdy nie zostaje żaden — cały kod.
        let noHTTP = """
        {"v":1,"server":{"id":"s","name":"Mac"},"addresses":[{"url":"file:///etc/passwd","kind":"local"}],
         "account":{"id":"u","username":"ola"},"device":{"keyID":"k","name":"iPad"},"key":"K"}
        """
        #expect(throws: PairingPayload.DecodingError.incomplete) { try PairingPayload(url: link(json: noHTTP)) }

        let mixed = """
        {"v":1,"server":{"id":"s","name":"Mac"},
         "addresses":[{"url":"ftp://mac.local","kind":"local"},{"url":"http://10.0.0.2:13378","kind":"local"}],
         "account":{"id":"u","username":"ola"},"device":{"keyID":"k","name":"iPad"},"key":"K"}
        """
        #expect((try? PairingPayload(url: link(json: mixed)))?.addresses.map(\.url.absoluteString) == ["http://10.0.0.2:13378"])
    }

    @Test func fitsComfortablyInQRCode() throws {
        // Klucz API audiobookshelf to JWT ok. 200 znaków; QR (poziom M) mieści ~2300 bajtów.
        var payload = sample
        payload.key = String(repeating: "k", count: 220)
        #expect(try payload.url().absoluteString.utf8.count < 1000)
    }
}
