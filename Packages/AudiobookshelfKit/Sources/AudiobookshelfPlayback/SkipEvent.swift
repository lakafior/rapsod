// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 13a).

import AudiobookshelfKit
import Foundation

/// Pominięty fragment — do komunikatu „Pominięto reklamę (0:58) · Cofnij”.
public struct SkipEvent: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public let entry: SkipPlan.Entry
    /// Dokąd wraca „Cofnij” (początek segmentu, a przy „Pomiń” — miejsce, z którego pominięto).
    public let undoTime: Double
    public let target: Double
    public let skippedIDs: [String]
    /// Automatycznie (`true`) albo przyciskiem „Pomiń”.
    public let automatic: Bool

    public var skippedSeconds: Double { max(0, target - undoTime) }

    /// „Pominięto reklamę (0:58)”.
    public var message: String {
        let what = entry.kind == .selfPromo ? "autopromocję" : "reklamę"
        return "Pominięto \(what) (\(PlaybackFormat.clock(skippedSeconds)))"
    }

    /// Dla VoiceOver: czas słownie.
    public var accessibilityMessage: String {
        let what = entry.kind == .selfPromo ? "autopromocję" : "reklamę"
        return "Pominięto \(what), \(PlaybackFormat.spokenDuration(skippedSeconds))"
    }
}
