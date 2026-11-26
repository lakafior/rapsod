// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AudiobookshelfKit

/// Automatyczne pobieranie odcinków na serwer: czy, jak często (wyrażenie cron serwera, 5 pól),
/// ile nowych odcinków na raz i ile zachować.
struct AutoDownloadSettings: Equatable {
    enum Frequency: Hashable {
        case hourly, every6Hours, daily, weekly
        /// Harmonogram, którego telefon nie umie pokazać (ustawiony na Macu) — zostaje bez zmian.
        case other(String)
    }

    var enabled = false
    var frequency = Frequency.hourly
    /// Godzina dla „codziennie” i „co tydzień”.
    var hour = 6
    /// 0 = niedziela, jak w cronie.
    var weekday = 1
    /// 0 = bez limitu.
    var maxNew = 3
    /// 0 = wszystkie.
    var maxKeep = 0

    /// Ustawienia, z którymi serwer zakłada nowy podcast.
    static let serverDefaults = AutoDownloadSettings()

    init() {}

    init(_ media: Client.ItemDetail.Media) {
        enabled = media.autoDownloadEpisodes ?? false
        maxNew = media.maxNewEpisodesToDownload ?? 3
        maxKeep = media.maxEpisodesToKeep ?? 0
        let cron = (media.autoDownloadSchedule ?? "0 * * * *").split(whereSeparator: \.isWhitespace).map(String.init)
        frequency = .other(cron.joined(separator: " "))
        guard cron.count == 5, cron[0] == "0", cron[2] == "*", cron[3] == "*" else { return }
        let hourValue = Int(cron[1]).flatMap { (0...23).contains($0) ? $0 : nil }
        let dayValue = Int(cron[4]).flatMap { (0...6).contains($0) ? $0 : nil }
        if cron[1] == "*", cron[4] == "*" {
            frequency = .hourly
        } else if cron[1] == "*/6", cron[4] == "*" {
            frequency = .every6Hours
        } else if let hourValue, cron[4] == "*" {
            frequency = .daily
            hour = hourValue
        } else if let hourValue, let dayValue {
            frequency = .weekly
            hour = hourValue
            weekday = dayValue
        }
    }

    var cron: String {
        switch frequency {
        case .hourly: "0 * * * *"
        case .every6Hours: "0 */6 * * *"
        case .daily: "0 \(hour) * * *"
        case .weekly: "0 \(hour) * * \(weekday)"
        case .other(let expression): expression
        }
    }

    /// Tylko to, co się zmieniło względem `base`.
    func update(from base: AutoDownloadSettings) -> Client.PodcastUpdate {
        var update = Client.PodcastUpdate()
        if enabled != base.enabled { update.autoDownloadEpisodes = enabled }
        if cron != base.cron { update.autoDownloadSchedule = cron }
        if maxNew != base.maxNew { update.maxNewEpisodesToDownload = maxNew }
        if maxKeep != base.maxKeep { update.maxEpisodesToKeep = maxKeep }
        return update
    }

    static let weekdays = ["niedziela", "poniedziałek", "wtorek", "środa", "czwartek", "piątek", "sobota"]
}

/// Sekcje formularza z ustawieniami automatycznego pobierania.
struct AutoDownloadSections: View {
    @Binding var settings: AutoDownloadSettings
    /// Tekst pod przełącznikiem (inny dla nowego i istniejącego podcastu).
    var note: String?

    private var customCron: String? {
        if case .other(let expression) = settings.frequency { return expression }
        return nil
    }

    var body: some View {
        Section {
            Toggle("Automatycznie pobieraj nowe odcinki", isOn: $settings.enabled)
                .accessibilityIdentifier("podcastSettings.autoDownload")
            if settings.enabled {
                Picker("Sprawdzaj kanał", selection: $settings.frequency) {
                    Text("Co godzinę").tag(AutoDownloadSettings.Frequency.hourly)
                    Text("Co 6 godzin").tag(AutoDownloadSettings.Frequency.every6Hours)
                    Text("Codziennie").tag(AutoDownloadSettings.Frequency.daily)
                    Text("Co tydzień").tag(AutoDownloadSettings.Frequency.weekly)
                    if let customCron { Text("Własny (\(customCron))").tag(AutoDownloadSettings.Frequency.other(customCron)) }
                }
                if settings.frequency == .weekly {
                    Picker("Dzień", selection: $settings.weekday) {
                        ForEach(0..<7, id: \.self) { Text(AutoDownloadSettings.weekdays[$0]).tag($0) }
                    }
                }
                if settings.frequency == .daily || settings.frequency == .weekly {
                    Picker("Godzina", selection: $settings.hour) {
                        ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                    }
                }
            }
        } header: {
            Text("Pobieranie na serwer")
        } footer: {
            if let note { Text(note) }
        }
        Section {
            Stepper(value: $settings.maxNew, in: 0...50) {
                LabeledContent("Nowych na raz", value: settings.maxNew == 0 ? "bez limitu" : "\(settings.maxNew)")
            }
            .accessibilityIdentifier("podcastSettings.maxNew")
            Stepper(value: $settings.maxKeep, in: 0...200) {
                LabeledContent("Zachowuj", value: settings.maxKeep == 0 ? "wszystkie" : PolishCount.episodes(settings.maxKeep))
            }
            .accessibilityIdentifier("podcastSettings.maxKeep")
        } footer: {
            Text("„Nowych na raz”: ile najnowszych odcinków serwer pobierze przy jednym sprawdzeniu kanału. „Zachowuj”: po pobraniu nowych serwer usuwa najstarsze odcinki ponad ten limit (pliki też).")
        }
    }
}

/// Arkusz „Ustawienia podcastu” na stronie istniejącego podcastu.
struct PodcastSettingsSheet: View {
    let item: Client.ItemDetail
    let session: ServerSession
    @Environment(\.dismiss) private var dismiss
    @State private var base: AutoDownloadSettings
    @State private var settings: AutoDownloadSettings
    @State private var busy = false
    @State private var error: String?

    init(item: Client.ItemDetail, session: ServerSession) {
        self.item = item
        self.session = session
        let current = AutoDownloadSettings(item.media)
        _base = State(initialValue: current)
        _settings = State(initialValue: current)
    }

    private var libraryName: String? {
        session.library.combined?.libraryName(item.libraryId)
    }

    var body: some View {
        NavigationStack {
            Form {
                AutoDownloadSections(settings: $settings, note: "Serwer pobiera nowe odcinki z kanału według harmonogramu.")
                if let libraryName, (session.library.combined?.podcastLibraries.count ?? 0) > 1 {
                    Section {
                        LabeledContent("Biblioteka", value: libraryName)
                    } footer: {
                        Text("Serwer nie umie przenosić pozycji między bibliotekami. Żeby podcast był w innej, dodaj go tam od nowa i usuń stąd.")
                    }
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Ustawienia podcastu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Zapisz", action: save)
                            .disabled(settings == base)
                            .accessibilityIdentifier("podcastSettings.save")
                    }
                }
            }
            .interactiveDismissDisabled(busy || settings != base)
        }
    }

    private func save() {
        let update = settings.update(from: base)
        guard !update.isEmpty else { return dismiss() }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                _ = try await session.auth.perform { try await $0.updatePodcast(itemID: item.id, update, token: $1) }
                session.library.podcasts.itemChanged(item.id)
                dismiss()
            } catch {
                self.error = PodcastSettingsSheet.message(for: error)
            }
        }
    }

    static func message(for error: any Error) -> String {
        if case AudiobookshelfClient.APIError.http(403, _) = error {
            return "Zmiana ustawień wymaga roli „Administrator” z „Edycją pozycji” dla konta tego telefonu. Na Macu: ustawienia Rapsod → Użytkownicy → profil tej osoby → rola „Administrator”."
        }
        return "Nie udało się zapisać ustawień: \(error.localizedDescription)"
    }
}
