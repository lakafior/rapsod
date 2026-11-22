import SwiftUI

enum Formats {
    /// „1 plik”, „3 pliki”, „5 plików” (odmiana liczebnika).
    static func files(_ count: Int) -> String {
        let tens = count % 100, ones = count % 10
        if count == 1 { return "1 plik" }
        if (2...4).contains(ones), !(12...14).contains(tens) { return "\(count) pliki" }
        return "\(count) plików"
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) godz. \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total) s"
    }

    /// Jak web UI (`$bytesPretty`): jednostki dziesiętne, do dwóch miejsc po przecinku.
    static func size(_ bytes: Double?) -> String {
        guard let bytes, bytes > 0 else { return "—" }
        let polish = Locale(identifier: "pl_PL")
        func number(_ value: Double, _ digits: Int) -> String {
            value.formatted(.number.precision(.fractionLength(0...digits)).locale(polish))
        }
        switch bytes {
        case ..<1_000: return "\(Int(bytes)) B"
        case ..<1_000_000: return number(bytes / 1_000, 2) + " KB"
        case ..<1_000_000_000: return number(bytes / 1_000_000, 2) + " MB"
        default: return number(bytes / 1_000_000_000, 2) + " GB"
        }
    }

    static func date(ms: Double?) -> String? {
        ms.map { day(Date(timeIntervalSince1970: $0 / 1000)) }
    }

    /// Data po polsku niezależnie od języka systemu (interfejs aplikacji jest tylko po polsku).
    static func day(_ date: Date, long: Bool = false) -> String {
        date.formatted(.dateTime.day().month(long ? .wide : .abbreviated).year().locale(Locale(identifier: "pl_PL")))
    }
}
