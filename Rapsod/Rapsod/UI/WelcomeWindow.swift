import SwiftUI

/// Ekran pierwszego uruchomienia: otwiera się sam, gdy serwer nie ma żadnej biblioteki.
struct WelcomeWindow: View {
    static let windowID = "welcome"

    let supervisor: ServerSupervisor
    let account: ServerAccount

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Witaj w Rapsodzie")
                .font(.title)
            Text("Wskaż folder z audiobookami — aplikacja utworzy z niego bibliotekę na serwerze audiobookshelf i ją zeskanuje. Kolejne foldery dodasz z menu na pasku menu.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                LibrarySection(supervisor: supervisor, account: account)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(minHeight: 160)
        }
        .padding(24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
