// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Numer wersji aplikacji („1.2.0”, ze znacznika wydania także „v1.2.0”) porównywany
/// liczbowo po składnikach: 1.10 > 1.9, a 1.2 == 1.2.0.
///
/// Dopiski po „-” (wydanie próbne, np. „1.3.0-beta1”) i po „+” (metadane builda) nie biorą
/// udziału w porównaniu; wersję z dopiskiem po „-” oznacza `isPrerelease`.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// Składniki liczbowe w zapisanej kolejności (bez zer dopisywanych do porównania).
    public let components: [Int]
    /// Wersja bez przedrostka „v” i bez dopisków, np. „1.2.0”.
    public let string: String
    public let isPrerelease: Bool

    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        var prerelease = false
        if let plus = rest.firstIndex(of: "+") { rest = rest[..<plus] }
        if let dash = rest.firstIndex(of: "-") {
            prerelease = true
            rest = rest[..<dash]
        }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        components = numbers
        string = String(rest)
        isPrerelease = prerelease
    }

    public var description: String { string }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}
