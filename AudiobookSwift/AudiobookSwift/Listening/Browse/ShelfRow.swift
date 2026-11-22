import SwiftUI

/// Pozioma półka kart z tytułem (strona startowa, autor, wyniki wyszukiwania).
struct ShelfRow<Content: View>: View {
    let title: String
    var action: (label: String, perform: () -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                if let action { Button(action.label, action: action.perform).buttonStyle(.link) }
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 18) { content }
                    .padding(.bottom, 6)
            }
            .scrollIndicators(.automatic)
        }
    }
}
