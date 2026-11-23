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

/// Dostęp zdalny (dawne „Udostępnianie” bez telefonu): sieć domowa, dostęp spoza domu i tunel.
/// Telefony i dane logowania są od etapu 2 w profilach osób (strona „Użytkownicy”).
struct SharingSettingsPage: View {
    let models: AppModels
    @Environment(SettingsNavigation.self) private var navigation
    @State private var addressesCode: AddressesCode?

    var body: some View {
        SettingsForm {
            Section("Sieć domowa i dostęp spoza domu") {
                ConnectPhoneSection(sharing: models.sharing, supervisor: models.supervisor, account: models.account)
            }
            Section {
                if models.pairing.devices.isEmpty {
                    LabeledContent("Podłączone telefony", value: "brak")
                } else {
                    LabeledContent("Adresy na telefonach") {
                        Button("Kod z adresami…") { addressesCode = models.pairing.addressesCode().map(AddressesCode.init) }
                            .disabled(models.pairing.addresses.isEmpty)
                    }
                }
                LabeledContent("Podłączanie telefonów") {
                    Button("Użytkownicy…") { navigation.page = .users }
                }
            } header: {
                Text("Aplikacja AudiobookSwift na telefonie")
            } footer: {
                Text("Telefon podłączasz kodem QR w profilu osoby (Ustawienia → Użytkownicy). Po włączeniu dostępu spoza domu albo zmianie adresów zeskanuj w telefonie „Kod z adresami” — to ten sam kod co w profilach; zaktualizuje adresy bez ponownego podłączania. Zmieniony adres w sieci domowej telefon znajduje też sam (Bonjour).")
            }
        }
        .sheet(item: $addressesCode) { AddressesCodeSheet(url: $0.url) }
        .task(id: models.account.state) {
            guard models.account.state == .ready else { return }
            await models.pairing.refresh()
        }
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
