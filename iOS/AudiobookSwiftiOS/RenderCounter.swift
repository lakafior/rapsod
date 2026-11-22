// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 11b).

import OSLog

/// Licznik przerysowań widoków — tylko w wersji Debug, do pomiaru (np. czy strona pozycji
/// przerysowuje się przy synchronizacji postępu). Odczyt:
/// `xcrun simctl spawn <urządzenie> log stream --level debug --predicate 'category == "Render"'`.
enum RenderCounter {
    #if DEBUG
    private static let logger = Logger(subsystem: "net.smigi.abswift.ios", category: "Render")
    @MainActor private static var counts: [String: Int] = [:]

    @MainActor static func tick(_ name: String) {
        counts[name, default: 0] += 1
        logger.debug("\(name, privacy: .public) #\(counts[name]!, privacy: .public)")
    }
    #else
    @inline(__always) static func tick(_ name: String) {}
    #endif
}
