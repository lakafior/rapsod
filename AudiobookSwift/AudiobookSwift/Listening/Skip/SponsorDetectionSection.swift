// Pochodzenie: kod własny projektu (etap 13b).

import AudiobookshelfKit
import SwiftUI

/// Ustawienia → Ogólne → „Fragmenty sponsorowane w podcastach” (etap 13b): domyślne działanie dla
/// kategorii, usługa modelu (adres, model, klucz w pęku kluczy), zgoda na wysyłanie transkrypcji
/// i „Wykrywaj fragmenty sponsorowane”. Samodzielna sekcja — wpięta jednym wierszem w stronę „Ogólne”.
struct SponsorDetectionSection: View {
    let dataRoot: URL?

    private var store: SponsorDetectionStore { .shared }
    @State private var categories = SkipSettingsStore().categoryDefaults
    @State private var keyDraft = ""
    @State private var editingKey = false
    @State private var checking = false
    @State private var checkResult: Result<String, Error>?

    var body: some View {
        Group {
            behaviourSection
            serviceSection
        }
        .onAppear {
            if let dataRoot { store.open(dataRoot: dataRoot) }
            categories = SkipSettingsStore().categoryDefaults
        }
        .onChange(of: categories) { SkipSettingsStore().setCategoryDefaults(categories) }
    }

    // MARK: Działanie

    private var behaviourSection: some View {
        Section {
            Toggle("Wykrywaj fragmenty sponsorowane", isOn: Binding(
                get: { store.settings.enabled },
                set: { value in store.update { $0.enabled = value } }
            ))
            .disabled(!store.settings.isConfigured || !store.settings.hasConsent)
            .accessibilityIdentifier("sponsor.enabled")
            if !store.settings.isConfigured || !store.settings.hasConsent {
                Text("Najpierw wpisz usługę modelu poniżej i zaznacz zgodę na wysyłanie transkrypcji.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Reklamy i sponsorzy", selection: $categories.sponsor) { actions }
                .accessibilityIdentifier("sponsor.action.sponsor")
            Picker("Autopromocja", selection: $categories.selfPromo) { actions }
                .accessibilityIdentifier("sponsor.action.selfPromo")
            if store.settings.enabled || store.queueCount > 0 {
                LabeledContent("Kolejka analizy") {
                    HStack {
                        Text(queueText).foregroundStyle(store.queuePause == nil ? Color.secondary : .orange)
                        if store.queuePause != nil {
                            Button("Wznów") { store.resumeQueue?() }
                        }
                    }
                }
                if let pause = store.queuePause {
                    Text(pause).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Fragmenty sponsorowane w podcastach")
        } footer: {
            Text("Działanie dotyczy wszystkich znaczników: z opisu odcinka, rozdziałów, reklam wstawianych przez wydawcę i z modelu. Pojedynczy podcast może mieć własne ustawienie (przycisk ⏭ na stronie podcastu). Po włączeniu wykrywania każdy odcinek pobrany na serwer jest transkrybowany na tym Macu i oceniany przez model; segment, którego model jest pewny, pomija się sam, z „Cofnij”, a niepewny albo krótszy niż 15 s jest tylko znacznikiem z przyciskiem „Pomiń”. Starsze odcinki — przyciskiem „Wykryj segmenty sponsorowane” w menu odcinka.")
                .foregroundStyle(.secondary)
        }
    }

    private var queueText: String {
        if store.queuePause != nil { return "wstrzymana" }
        if store.queueCount == 0 { return "pusta" }
        let activity = store.queueActivity.map { " — \($0)" } ?? ""
        return "\(store.queueCount) \(store.queueCount == 1 ? "odcinek" : (2...4).contains(store.queueCount % 10) && !(12...14).contains(store.queueCount % 100) ? "odcinki" : "odcinków")\(activity)"
    }

    @ViewBuilder private var actions: some View {
        ForEach(SkipAction.allCases, id: \.self) { Text($0.title).tag($0) }
    }

    // MARK: Usługa

    private var serviceSection: some View {
        Section {
            TextField("Adres API", text: Binding(
                get: { store.settings.baseURL },
                set: { value in store.update { $0.baseURL = value } }
            ), prompt: Text("https://api.mistral.ai/v1"))
            .accessibilityIdentifier("sponsor.baseURL")
            if !store.settings.baseURL.isEmpty, store.settings.parsedBaseURL == nil {
                Text("To nie wygląda na adres usługi (http albo https).").font(.caption).foregroundStyle(.red)
            }
            TextField("Model", text: Binding(
                get: { store.settings.model },
                set: { value in store.update { $0.model = value } }
            ), prompt: Text("mały model, np. Mistral Small albo Gemini Flash"))
            .accessibilityIdentifier("sponsor.model")
            keyRow
            LabeledContent("Połączenie") {
                HStack {
                    if checking { ProgressView().controlSize(.small) }
                    Button("Sprawdź połączenie") { check() }
                        .disabled(checking || !store.settings.isConfigured)
                        .accessibilityIdentifier("sponsor.check")
                }
            }
            if let checkResult {
                switch checkResult {
                case .success(let text): Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failure(let error): Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            consentRow
        } header: {
            Text("Usługa modelu językowego")
        } footer: {
            Text("Usługa zgodna z API OpenAI (`…/chat/completions`), na Twoim kluczu: np. Mistral (`https://api.mistral.ai/v1`, model `mistral-small-latest`), Google Gemini (`https://generativelanguage.googleapis.com/v1beta/openai`, `gemini-flash-lite-latest`) albo OpenAI. Godzina odcinka to kilkanaście tysięcy tokenów — przy małym modelu ułamek centa. „Sprawdź połączenie” wysyła jedno krótkie zapytanie bez danych odcinków. Klucz jest w pęku kluczy tego Maca, nie w plikach aplikacji.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var keyRow: some View {
        if store.hasKey && !editingKey {
            LabeledContent("Klucz API") {
                HStack {
                    Text("zapisany w pęku kluczy").foregroundStyle(.secondary)
                    Button("Zmień…") { keyDraft = ""; editingKey = true }
                    Button("Usuń", role: .destructive) { store.deleteKey(); checkResult = nil }
                        .accessibilityIdentifier("sponsor.deleteKey")
                }
            }
        } else {
            LabeledContent("Klucz API") {
                HStack {
                    SecureField("Klucz API", text: $keyDraft, prompt: Text("wklej klucz (pusty — usługa bez klucza)"))
                        .labelsHidden()
                        .onSubmit(saveKey)
                        .accessibilityIdentifier("sponsor.key")
                    Button("Zapisz", action: saveKey).disabled(keyDraft.isEmpty)
                    if editingKey { Button("Anuluj") { keyDraft = ""; editingKey = false } }
                }
            }
        }
        if let error = store.keyError {
            Text("Pęk kluczy: \(error)").font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var consentRow: some View {
        let host = store.settings.parsedBaseURL?.host() ?? "wskazanej usługi"
        Toggle(isOn: Binding(
            get: { store.settings.hasConsent },
            set: { value in
                store.update {
                    $0.consentHost = value ? $0.parsedBaseURL?.host()?.lowercased() : nil
                    $0.consentDate = value ? .now : nil
                    if !value { $0.enabled = false }
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Zgadzam się na wysyłanie transkrypcji odcinków do \(host)")
                Text("Wysyłany jest tekst rozpoznany z nagrania odcinka — fragmentami po ok. 10 minut, z numerem i czasem każdego wiersza — oraz długość odcinka. Nie są wysyłane: plik audio, tytuł i opis odcinka, nazwa i adres podcastu, dane kont. Z samej treści usługa może jednak rozpoznać, czego słuchasz. Czy przechowuje dane albo uczy na nich modele, zależy od jej regulaminu (darmowe progi niektórych dostawców tak robią). Zmiana adresu na inną usługę wymaga nowej zgody.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!store.settings.isConfigured)
        .accessibilityIdentifier("sponsor.consent")
    }

    private func saveKey() {
        store.saveKey(keyDraft)
        keyDraft = ""
        editingKey = false
        checkResult = nil
    }

    private func check() {
        checking = true
        checkResult = nil
        Task {
            checkResult = await store.checkConnection()
            checking = false
        }
    }
}
