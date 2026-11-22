import SwiftUI

/// Klucz `.task(id:)` stron wczytywanych z serwera: zmiana tego, co pokazują, albo licznika zmian
/// biblioteki (`LibraryBrowser.revision`) wczytuje je od nowa i przerywa wczytanie poprzednie
/// (nieaktualne nie nadpisze nowszego).
struct ReloadKey: Hashable {
    let id: String
    let revision: Int
}

/// Komunikat błędu albo kółko ładowania dla stron wczytywanych z serwera.
struct LoadingState: View {
    let error: String?
    let retry: () async -> Void

    var body: some View {
        if let error {
            ContentUnavailableView {
                Label("Nie udało się wczytać", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Spróbuj ponownie") { Task { await retry() } }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
