// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu — połączenie `ChapterScrubber.time` / `SpeedMenu.label`
// z aplikacji na Maca (etap 9a) i `TimeText.clock` / `PlayerControls.rateLabel` z aplikacji iOS
// (etap 10c), które robiły to samo (etap 12).

import Foundation

/// Napisy odtwarzacza wspólne dla Maca i iOS.
public enum PlaybackFormat {
    /// Czas jak na zegarze: „1:02:03” albo „12:05”. Domyślnie ułamki sekund odcinane (iOS: czas
    /// od początku i do końca nie przeskakuje o sekundę naprzód); Mac od etapu 9a zaokrągla
    /// (`.toNearestOrEven`) i przy tym zostaje, dopóki nie zapadnie decyzja o jednym wariancie.
    public static func clock(_ seconds: Double, rounding: FloatingPointRoundingRule = .down) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded(rounding))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Prędkość: „1×”, „1,25×” (separator dziesiętny z ustawień systemu).
    public static func rate(_ rate: Float) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    /// Długość słownie dla VoiceOver: „58 sekund”, „1 minuta i 5 sekund”.
    public static func spokenDuration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
        return Duration.seconds(total).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)
            .locale(Locale(identifier: "pl_PL")))
    }
}
