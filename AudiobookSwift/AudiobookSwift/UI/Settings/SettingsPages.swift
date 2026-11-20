import SwiftUI

/// Biblioteki: lista, dodawanie i usuwanie, postęp skanu.
struct LibrariesSettingsPage: View {
    let models: AppModels

    var body: some View {
        SettingsForm {
            Section {
                LibrarySection(supervisor: models.supervisor, account: models.account)
            } header: {
                Text("Biblioteki na serwerze")
            } footer: {
                Text("Usunięcie biblioteki usuwa ją z serwera; pliki w folderze zostają na dysku.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Konta: konto do słuchania (Mac i telefon) i konto root do zarządzania serwerem.
struct AccountsSettingsPage: View {
    let models: AppModels

    private var account: ServerAccount { models.account }

    var body: some View {
        SettingsForm {
            Section("Konto do słuchania") {
                UserAccountSection(account: account)
            }
            Section("Konto do zarządzania serwerem") {
                rootRows
            }
        }
    }

    @ViewBuilder
    private var rootRows: some View {
        switch account.state {
        case .ready:
            LabeledContent("Konto", value: "\(account.username ?? ServerEnvironment.rootUsername) (hasło w pęku kluczy)")
            Text("Tego konta używa „Zarządzanie serwerem…” w menu na pasku menu: użytkownicy, biblioteki i ustawienia audiobookshelf.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .needsPassword(let reason):
            RootPasswordForm(account: account, reason: reason)
        case .connecting:
            ProgressView("Łączenie z serwerem…")
                .controlSize(.small)
        case .disconnected:
            Text("Dostępne, gdy serwer działa.").foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

/// Udostępnianie: sieć lokalna, dane do telefonu, dostęp spoza domu i tunel.
struct SharingSettingsPage: View {
    let models: AppModels

    var body: some View {
        SettingsForm {
            Section("Połącz telefon") {
                ConnectPhoneSection(sharing: models.sharing, supervisor: models.supervisor, account: models.account)
            }
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
        }
    }
}
