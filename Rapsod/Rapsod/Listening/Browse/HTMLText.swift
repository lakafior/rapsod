import AudiobookshelfKit
import SwiftUI

// `HTMLText` (opis z HTML jako tekst) jest w pakiecie AudiobookshelfKit.

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
