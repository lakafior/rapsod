import SwiftUI

/// Opis z HTML (opisy książek i odcinków) jako tekst, bez WebKit: akapity i nowe linie
/// zostają, znaczniki znikają, encje są dekodowane. `NSAttributedString(html:)` uruchamiałby WebKit.
enum HTMLText {
    /// Wyniki dla ostatnich opisów: `plain` jest wołane z `body` wierszy list, a to kilkanaście
    /// wyrażeń regularnych na opis. `NSCache` jest bezpieczny między wątkami.
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 600
        return cache
    }()

    static func plain(_ html: String?) -> String? {
        guard let html, !html.isEmpty else { return nil }
        if let cached = cache.object(forKey: html as NSString) { return cached.length == 0 ? nil : cached as String }
        let result = convert(html)
        cache.setObject((result ?? "") as NSString, forKey: html as NSString)
        return result
    }

    private static func convert(_ html: String) -> String? {
        var text = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let breaks: [(String, String)] = [
            ("(?i)<br\\s*/?>", "\n"), ("(?i)</p\\s*>", "\n\n"), ("(?i)</(div|h[1-6]|ul|ol)\\s*>", "\n"), ("(?i)<li[^>]*>", "• "), ("(?i)</li\\s*>", "\n"),
        ]
        for (pattern, replacement) in breaks {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&hellip;": "…", "&ndash;": "–", "&mdash;": "—"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        text = decodeNumeric(text)
        text = text.replacingOccurrences(of: "[ \\t]+\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func decodeNumeric(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: "&#\\d+;", options: .regularExpression) {
            result += rest[..<range.lowerBound]
            let digits = rest[range].dropFirst(2).dropLast()
            if let code = UInt32(digits), let scalar = Unicode.Scalar(code) { result.unicodeScalars.append(scalar) }
            rest = rest[range.upperBound...]
        }
        return result + rest
    }
}

/// Długi tekst zwinięty do kilku linii z „Więcej”/„Mniej”.
struct ExpandableText: View {
    let text: String
    var lines = 6
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .lineLimit(expanded ? nil : lines)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if text.count > lines * 90 || text.filter({ $0 == "\n" }).count >= lines {
                Button(expanded ? "Mniej" : "Więcej") { expanded.toggle() }
                    .buttonStyle(.link)
            }
        }
    }
}
