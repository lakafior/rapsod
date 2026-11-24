import Foundation

/// Token tunelu zarządzanego zdalnie (z panelu Cloudflare): base64 z JSON-em
/// `{"a": konto, "t": identyfikator tunelu, "s": sekret}`.
///
/// Panel pokazuje go w gotowym poleceniu (`cloudflared service install eyJ…`),
/// więc przyjmujemy też wklejone całe polecenie i wyciągamy z niego token.
struct CloudflareTunnelToken: Sendable, Equatable {
    let value: String
    /// Identyfikator tunelu — nie jest tajny, pokazujemy go dla orientacji.
    let tunnelID: String

    init?(pasted text: String) {
        let candidates = text
            .split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
            .map(String.init)
            .filter { $0.hasPrefix("eyJ") }
        for candidate in candidates {
            if let tunnelID = Self.tunnelID(of: candidate) {
                value = candidate
                self.tunnelID = tunnelID
                return
            }
        }
        return nil
    }

    private static func tunnelID(of token: String) -> String? {
        var base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["a"] is String, object["s"] is String,
              let tunnelID = object["t"] as? String, UUID(uuidString: tunnelID) != nil else { return nil }
        return tunnelID.lowercased()
    }

    /// Zamienia w tekście wszystko, co wygląda na token, na `[token]` — na wypadek,
    /// gdyby cloudflared kiedyś wypisał go do logu.
    static func redact(_ line: String) -> String {
        line.replacing(/eyJ[A-Za-z0-9+\/=_-]{40,}/, with: "[token]")
    }
}
