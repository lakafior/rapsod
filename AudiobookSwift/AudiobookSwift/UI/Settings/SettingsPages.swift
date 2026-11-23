import SwiftUI

/// Biblioteki: lista, dodawanie i usuwanie, postęp skanu.
struct LibrariesSettingsPage: View {
    let models: AppModels

    var body: some View {
        SettingsForm {
            Section {
                LibrarySection(supervisor: models.supervisor, account: models.account, tasks: models.libraryTasks)
            } header: {
                Text("Biblioteki na serwerze")
            } footer: {
                Text("„Skanuj” dodaje nowe pliki i zauważa zmienione lub usunięte; „Wymuś pełny skan” czyta od nowa wszystkie pozycje. „Dopasuj wszystkie” uzupełnia metadane książek z domyślnego źródła biblioteki. Usunięcie biblioteki usuwa ją z serwera; pliki w folderze zostają na dysku.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { models.libraryTasks.appear() }
        // Biblioteki mogły przybyć albo zniknąć poza aplikacją (web UI, inny administrator).
        .task(id: models.account.state) {
            guard models.account.state == .ready else { return }
            models.libraryTasks.resume()
            guard !models.account.isScanning else { return }
            try? await models.account.refreshLibraries()
        }
        .onDisappear { models.libraryTasks.disappear() }
    }
}

/// Źródła metadanych: opcjonalne polskie źródła (aio-abs-providers) dla audiobookshelf.
struct MetadataSettingsPage: View {
    let models: AppModels

    var body: some View {
        SettingsForm {
            Section("Źródła metadanych") {
                MetadataSourcesSection(sources: models.metadataSources)
            }
            CustomProvidersSection(account: models.account, refreshKey: models.metadataSources.registration.title)
        }
    }
}
