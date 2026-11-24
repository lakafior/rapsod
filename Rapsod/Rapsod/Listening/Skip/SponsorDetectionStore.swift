// Pochodzenie: kod własny projektu (etap 13b).

import AudiobookshelfKit
import Foundation
import Observation

/// Ustawienia wykrywania z modelem na tym Macu (etap 13b): plik `sponsor-detection.json` w folderze
/// danych serwera (adres, model, włączenie, zgoda) i klucz API w pęku kluczy (konto = folder danych,
/// jak token tunelu) — więc testowa kopia z `-ABSDataRoot` nie widzi i nie zmienia prawdziwych.
/// Klucz nie trafia do pliku, `UserDefaults` ani logu.
@MainActor
@Observable
final class SponsorDetectionStore {
    static let shared = SponsorDetectionStore()
    nonisolated static let keychainService = "net.smigi.rapsod.sponsor-api"

    private(set) var settings = SponsorDetectionSettings()
    /// Klucz jest zapisany (samej wartości widoki nie dostają).
    private(set) var hasKey = false
    private(set) var dataRoot: URL?
    /// Rośnie przy każdej zmianie — kolejka wznawia się po poprawce ustawień.
    private(set) var revision = 0
    var keyError: String?
    /// Stan kolejki modelu do pokazania w ustawieniach (ustawia `SkipController`).
    var queueCount = 0
    var queueActivity: String?
    var queuePause: String?
    @ObservationIgnored var resumeQueue: (() -> Void)?
    /// Po zmianie ustawień albo klucza kolejka wstrzymana błędem usługi rusza sama (ustawia `SkipController`).
    @ObservationIgnored var settingsChanged: (() -> Void)?

    @ObservationIgnored private var keyStore: CredentialStore<String>?

    private init() {}

    /// Wskazuje folder danych (przy starcie serwera i przy otwarciu ustawień).
    func open(dataRoot: URL) {
        guard self.dataRoot != dataRoot else { return }
        self.dataRoot = dataRoot
        settings = SponsorDetectionSettings.load(from: dataRoot.appending(path: SponsorDetectionSettings.fileName))
        keyStore = CredentialStore<String>(service: Self.keychainService, account: dataRoot.path,
                                           label: "Rapsod — klucz API do wykrywania fragmentów sponsorowanych")
        do {
            hasKey = try keyStore?.load()?.isEmpty == false
        } catch {
            keyError = error.localizedDescription
        }
        revision += 1
    }

    func update(_ change: (inout SponsorDetectionSettings) -> Void) {
        var next = settings
        change(&next)
        // Wyłączenie wykrywania bez konfiguracji — przełącznik nie zostaje włączony „na pusto”.
        if !next.isConfigured || !next.hasConsent { next.enabled = next.enabled && next.isConfigured && next.hasConsent }
        guard next != settings else { return }
        settings = next
        revision += 1
        if let dataRoot { try? settings.save(to: dataRoot.appending(path: SponsorDetectionSettings.fileName)) }
        settingsChanged?()
    }

    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try keyStore?.delete()
                hasKey = false
            } else {
                try keyStore?.save(trimmed)
                hasKey = true
            }
            keyError = nil
            revision += 1
            settingsChanged?()
        } catch {
            keyError = error.localizedDescription
        }
    }

    func deleteKey() { saveKey("") }

    private func key() -> String? {
        guard hasKey else { return nil }
        return try? keyStore?.load()
    }

    /// Konfiguracja zapytań z transkrypcją — tylko przy włączonym wykrywaniu i zgodzie dla tej usługi.
    func requestConfiguration() -> SponsorAPIConfiguration? {
        settings.requestConfiguration(apiKey: key())
    }

    /// „Sprawdź połączenie”: jedno małe zapytanie bez żadnych danych odcinków.
    func checkConnection() async -> Result<String, Error> {
        guard let configuration = settings.checkConfiguration(apiKey: key()) else {
            return .failure(SpeechTranscription.Failure(message: "Wpisz adres API i nazwę modelu."))
        }
        let client = SponsorAPIClient(configuration: configuration, attempts: 2, baseDelay: 1, maxDelay: 5)
        do {
            let reply = try await client.check()
            return reply.content.isEmpty ? .failure(SponsorAPIError.invalidFormat("pusta odpowiedź")) : .success("Połączenie działa: model \(configuration.model) odpowiada.")
        } catch {
            return .failure(error)
        }
    }
}
