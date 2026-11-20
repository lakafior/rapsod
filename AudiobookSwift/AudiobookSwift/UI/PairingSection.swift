import SwiftUI

/// Wiersze sekcji „Parowanie z iPhone’em” w oknie statusu.
struct PairingSection: View {
    let pairing: PairingController
    let account: ServerAccount

    @State private var externalURL = ""
    @State private var confirmsRevoke = false

    private var canEnable: Bool {
        guard account.state == .ready, case .ready = account.userState else { return false }
        return true
    }

    var body: some View {
        Toggle("Udostępniaj serwer w sieci lokalnej i paruj przez iCloud", isOn: Binding(
            get: { pairing.isEnabled },
            set: { enabled in Task { await pairing.setEnabled(enabled) } }
        ))
        .disabled(pairing.isBusy || (!pairing.isEnabled && !canEnable))

        Text(explanation)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        LabeledContent("Konto iCloud") {
            Label(pairing.cloudState.title, systemImage: pairing.cloudState.symbolName)
                .foregroundStyle(pairing.cloudState.tint)
        }
        if let hint = pairing.cloudState.hint {
            HStack {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Otwórz Ustawienia") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        if pairing.isEnabled {
            LabeledContent("Rekord w iCloud") {
                Text(pairing.recordState.title)
                    .foregroundStyle(pairing.recordState.tint)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            LabeledContent("Bonjour") {
                Text(pairing.bonjourStatus.title)
                    .foregroundStyle(pairing.bonjourStatus.tint)
            }
            LabeledContent("Widoczny pod adresami") {
                VStack(alignment: .trailing, spacing: 2) {
                    if let record = pairing.record {
                        ForEach(record.candidateURLs, id: \.self) { url in
                            Text(url.absoluteString).textSelection(.enabled)
                        }
                    } else {
                        Text("—")
                    }
                }
                .font(.callout.monospaced())
            }
            LabeledContent("Token klienta iOS") {
                HStack {
                    if let username = pairing.record?.username {
                        Text("klucz API konta „\(username)”")
                    }
                    Button("Unieważnij…") { confirmsRevoke = true }
                        .disabled(pairing.isBusy || pairing.record == nil)
                }
            }
            .confirmationDialog("Unieważnić token klienta iOS?", isPresented: $confirmsRevoke) {
                Button("Unieważnij i wydaj nowy", role: .destructive) {
                    Task { await pairing.revokeToken() }
                }
            } message: {
                Text("Dotychczasowy token natychmiast przestanie działać. Nowy trafi do iCloud, a aplikacja na iPhonie pobierze go sama.")
            }
        }

        LabeledContent("Adres zewnętrzny") {
            HStack {
                TextField("Adres zewnętrzny", text: $externalURL, prompt: Text("opcjonalnie, np. https://ksiazki.example.com/audiobookshelf"))
                    .labelsHidden()
                    .onSubmit { pairing.setExternalURL(externalURL) }
                Button("Zapisz") { pairing.setExternalURL(externalURL) }
                    .disabled(externalURL.trimmingCharacters(in: .whitespaces) == pairing.settings.externalURL)
            }
        }
        .onAppear { externalURL = pairing.settings.externalURL }
        Text("Aplikacja nie zestawia dostępu spoza domu. Jeśli masz własny tunel lub VPN, wpisz tu jego adres — klient iOS spróbuje go, gdy nie znajdzie serwera w sieci lokalnej.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if let error = pairing.lastError {
            Text(error)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var explanation: String {
        if pairing.isEnabled {
            "Serwer słucha w sieci lokalnej po zwykłym HTTP: token i treść są widoczne dla innych urządzeń w tej samej sieci. Wyłączenie przywraca nasłuch tylko na tym Macu, usuwa rekord z iCloud i unieważnia token."
        } else if canEnable {
            "Po włączeniu iPhone zalogowany na to samo konto iCloud sam znajdzie serwer. Serwer zacznie słuchać w sieci lokalnej po zwykłym HTTP (wymaga restartu serwera); teraz jest dostępny tylko z tego Maca."
        } else {
            "Parowanie wymaga działającego serwera i konta użytkownika."
        }
    }
}

private extension PairingController.CloudState {
    var title: String {
        switch self {
        case .checking: "Sprawdzanie…"
        case .available: "Zalogowano"
        case .noAccount: "Nie zalogowano"
        case .restricted: "Dostęp ograniczony"
        case .temporarilyUnavailable: "Chwilowo niedostępne"
        case .failed: "Błąd"
        }
    }

    var symbolName: String {
        switch self {
        case .available: "checkmark.icloud"
        case .checking: "icloud"
        case .noAccount, .restricted, .temporarilyUnavailable, .failed: "exclamationmark.icloud"
        }
    }

    var tint: Color {
        switch self {
        case .available: .green
        case .checking: .secondary
        case .noAccount, .restricted, .temporarilyUnavailable, .failed: .orange
        }
    }

    /// Co użytkownik ma zrobić, gdy iCloud nie jest gotowy.
    var hint: String? {
        switch self {
        case .checking, .available:
            nil
        case .noAccount:
            "Zaloguj się do iCloud w Ustawieniach systemowych i włącz iCloud Drive — bez tego iPhone nie dostanie adresu ani tokenu. Udostępnianie w sieci lokalnej działa niezależnie."
        case .restricted:
            "iCloud jest zablokowany na tym koncie (np. przez profil zarządzania albo Czas przed ekranem)."
        case .temporarilyUnavailable:
            "Konto iCloud wymaga uwagi — sprawdź Ustawienia systemowe (np. ponowne podanie hasła)."
        case .failed(let message):
            message
        }
    }
}

private extension PairingController.RecordState {
    var title: String {
        switch self {
        case .notSaved: "Nie zapisano"
        case .saving: "Zapisywanie…"
        case .saved(let date): "Zapisano \(date.formatted(date: .abbreviated, time: .standard))"
        case .failed(let message): "Błąd: \(message)"
        }
    }

    var tint: Color {
        switch self {
        case .saved: .green
        case .failed: .red
        case .notSaved, .saving: .secondary
        }
    }
}

private extension BonjourAdvertiser.Status {
    var title: String {
        switch self {
        case .stopped: "Nie ogłaszany"
        case .registering: "Rejestrowanie…"
        case .advertised(let name): "Ogłaszany jako „\(name)” (\(PairingSchema.bonjourType))"
        case .failed(let message): message
        }
    }

    var tint: Color {
        switch self {
        case .advertised: .green
        case .failed: .red
        case .stopped, .registering: .secondary
        }
    }
}
