import RapsodIntegration
import SwiftUI

/// Powiadomienia tego Maca na stronie „Powiadomienia” (etap 14e) — nad opcjami serwera, bo działają
/// bez konta root i bez Apprise. Główny przełącznik prosi system o zgodę dopiero przy pierwszym
/// włączeniu; po odmowie strona prowadzi do Ustawień systemowych.
struct MacNotificationsSection: View {
    let notifications: SystemNotifications
    @Environment(\.appearsActive) private var appearsActive

    private var isEnabled: Bool { notifications.preferences.isEnabled }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { isEnabled }, set: { on in Task { await notifications.setEnabled(on) } })) {
                Text("Pokazuj powiadomienia")
                Text("Banery i Centrum powiadomień tego Maca. Przy pierwszym włączeniu macOS zapyta o zgodę.")
            }
            .disabled(notifications.isRequesting)
            authorizationRow
            ForEach(NotificationKind.allCases) { kind in
                Toggle(isOn: Binding(get: { notifications.preferences.isOn(kind) }, set: { notifications.set(kind, $0) })) {
                    Text(kind.settingsTitle)
                    Text(kind.settingsDetail)
                }
                .disabled(!isEnabled)
            }
        } header: {
            Text("Powiadomienia na tym Macu")
        } footer: {
            Text("Pokazuje je system macOS tylko na tym komputerze. Kliknięcie powiadomienia otwiera właściwe miejsce w Rapsodzie; nie ma ich, gdy to okno jest właśnie na wierzchu. Powiadomienia serwera (niżej) wysyła audiobookshelf przez Apprise do innych usług.")
                .foregroundStyle(.secondary)
        }
        // Zgoda mogła się zmienić w Ustawieniach systemowych, gdy okno było w tle.
        .task(id: appearsActive) {
            if appearsActive { await notifications.refreshAuthorization() }
        }
    }

    @ViewBuilder private var authorizationRow: some View {
        switch notifications.authorization {
        case .denied:
            LabeledContent {
                Button("Otwórz Ustawienia systemowe…") { SystemNotifications.openSystemSettings() }
            } label: {
                Label("Powiadomienia Rapsodu są wyłączone w Ustawieniach systemowych.", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
        case .provisional where isEnabled:
            LabeledContent {
                Button("Otwórz Ustawienia systemowe…") { SystemNotifications.openSystemSettings() }
            } label: {
                Text("macOS dostarcza je po cichu — tylko do Centrum powiadomień, bez banerów.")
                    .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }
}

extension NotificationKind {
    var settingsTitle: String {
        switch self {
        case .libraryScan: "Koniec skanu biblioteki"
        case .newEpisodes: "Nowe odcinki podcastów"
        case .uploads: "Wgrywanie i scalanie do M4B"
        case .appUpdate: "Dostępna aktualizacja Rapsodu"
        case .sponsorSegments: "Wykryte segmenty sponsorowane"
        }
    }

    var settingsDetail: String {
        switch self {
        case .libraryScan: "Z liczbą dodanych, zmienionych i brakujących pozycji. Skan bez zmian — tylko zlecony z Rapsodu."
        case .newEpisodes: "Gdy serwer pobierze nowe odcinki; kilka naraz w jednym powiadomieniu."
        case .uploads: "Koniec wgrywania książek i scalania do jednego pliku M4B, także błąd."
        case .appUpdate: "Zamiast samoczynnie otwieranego okna aktualizacji."
        case .sponsorSegments: "Po przeglądzie nowego odcinka w tle."
        }
    }
}
