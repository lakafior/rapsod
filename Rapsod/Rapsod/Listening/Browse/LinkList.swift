import SwiftUI

/// Wartości prowadzące do list (autor, lektor, gatunek…) — jak linki w web UI.
struct LinkList: View {
    let values: [(label: String, action: () -> Void)]

    var body: some View {
        // Zwykłe zawijanie: każdy element to przycisk-link.
        FlowLayout(spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Button(value.label + (index < values.count - 1 ? "," : "")) { value.action() }
                    .buttonStyle(.link)
                    .multilineTextAlignment(.leading)
            }
        }
    }
}
