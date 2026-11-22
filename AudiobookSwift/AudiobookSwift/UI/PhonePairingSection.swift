import AppKit
import SwiftUI

/// Sekcja „Aplikacja AudiobookSwift na telefonie” (podstrona „Udostępnianie”): parowanie kodem QR,
/// lista sparowanych telefonów z unieważnianiem i uprawnienia administratora konta słuchacza.
struct PhonePairingSection: View {
    let pairing: PhonePairing

    @State private var showsPairing = false
    @State private var addressesCode: AddressesCode?
    @State private var revoking: PhonePairing.Device?
    @State private var confirmsAdmin = false
    @State private var actionError: String?

    var body: some View {
        Text("Telefon z aplikacją AudiobookSwift paruje się kodem QR: dostaje osobny klucz konta do słuchania (bez hasła i bez konta root), więc postęp słuchania jest wspólny z tym Makiem. Klucz nie wygasa — unieważnisz go tutaj.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if let reason = pairing.unavailableReason {
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        LabeledContent("Nowy telefon") {
            Button("Sparuj telefon…") { showsPairing = true }
                .disabled(pairing.unavailableReason != nil)
        }
        .task(id: pairing.listenerUsername) { await pairing.refresh() }
        .sheet(isPresented: $showsPairing) {
            PairPhoneSheet(pairing: pairing)
        }
        .sheet(item: $addressesCode) { code in
            AddressesCodeSheet(url: code.url)
        }
        .confirmationDialog(
            "Unieważnić klucz telefonu „\(revoking?.name ?? "")”?",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            presenting: revoking
        ) { device in
            Button("Unieważnij", role: .destructive) { revoke(device) }
        } message: { _ in
            Text("Telefon straci dostęp do serwera przy następnym połączeniu. Żeby znów go użyć, sparuj go ponownie.")
        }
        .confirmationDialog("Nadać kontu „\(pairing.listenerUsername ?? "")” uprawnienia administratora?", isPresented: $confirmsAdmin) {
            Button("Nadaj uprawnienia") { setAdmin(true) }
        } message: {
            Text(AdminExplanation.text(username: pairing.listenerUsername ?? ""))
        }

        if pairing.listenerUsername != nil {
            if pairing.devices.isEmpty {
                LabeledContent("Sparowane telefony", value: pairing.isLoading ? "Wczytywanie…" : "brak")
            }
            ForEach(pairing.devices) { device in
                DeviceRow(device: device) { revoking = device }
            }

            if !pairing.devices.isEmpty {
                LabeledContent("Adresy na telefonach") {
                    Button("Kod z adresami…") { addressesCode = pairing.addressesCode().map(AddressesCode.init) }
                        .disabled(pairing.addresses.isEmpty)
                }
                Text("Po włączeniu dostępu spoza domu albo zmianie adresów zeskanuj ten kod w aplikacji na telefonie — zaktualizuje adresy bez ponownego parowania. Kod nie zawiera klucza; telefon sprawdza każdy nowy adres swoim kluczem. Zmieniony adres w sieci lokalnej telefon znajduje też sam (Bonjour).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("Uprawnienia administratora") {
                HStack {
                    Text(pairing.listenerIsAdmin ? "Tak" : "Nie")
                    if pairing.listenerIsAdmin {
                        Button("Odbierz") { setAdmin(false) }
                    } else {
                        Button("Nadaj…") { confirmsAdmin = true }
                    }
                }
            }
            Text(AdminExplanation.text(username: pairing.listenerUsername ?? ""))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let error = actionError ?? pairing.loadError {
            Text(error)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func revoke(_ device: PhonePairing.Device) {
        Task {
            do {
                try await pairing.revoke(keyID: device.id)
                actionError = nil
            } catch {
                actionError = "Nie udało się unieważnić klucza: \(error.localizedDescription)"
            }
        }
    }

    private func setAdmin(_ admin: Bool) {
        Task {
            do {
                try await pairing.setListenerAdmin(admin)
                actionError = nil
            } catch {
                actionError = "Nie udało się zmienić uprawnień: \(error.localizedDescription)"
            }
        }
    }
}

private struct DeviceRow: View {
    let device: PhonePairing.Device
    let revoke: () -> Void

    var body: some View {
        LabeledContent {
            Button("Unieważnij…", action: revoke)
        } label: {
            Text(device.name)
            Text(details)
        }
    }

    private var details: String {
        var parts: [String] = []
        if let created = device.createdAt {
            parts.append("sparowany \(created.formatted(date: .abbreviated, time: .shortened))")
        }
        // Serwer v2.38.0 nie zapisuje ostatniego użycia klucza — pokazujemy je tylko, jeśli kiedyś zacznie.
        if let used = device.lastUsedAt {
            parts.append("ostatnio \(used.formatted(.relative(presentation: .named)))")
        }
        if device.isExpired {
            parts.append("wygasł")
        } else if !device.isActive {
            parts.append("wyłączony")
        }
        return parts.joined(separator: " · ")
    }
}

/// Wspólny opis pytania o uprawnienia administratora (arkusz parowania i ustawienia).
enum AdminExplanation {
    static func text(username: String) -> String {
        "Uprawnienia administratora (razem z „Edycją pozycji”, której serwer też wymaga) są potrzebne tylko do zlecania z telefonu pobierania odcinków podcastów na serwer. Oznaczają jednak, że konto „\(username)” może zarządzać całym serwerem (użytkownicy, biblioteki, ustawienia) z każdego klienta — z każdego sparowanego telefonu i z każdej aplikacji, w której wpisano jego hasło. Konto root nigdy nie trafia do telefonu. Uprawnienia odbierzesz tutaj w każdej chwili."
    }
}

/// Arkusz parowania: nazwa telefonu i pytanie o uprawnienia, potem ukryty kod QR.
///
/// Klucz istnieje tylko w pamięci tego widoku: kod trzeba odsłonić kliknięciem, zakrywa się
/// sam po `visibleFor` i przy przejściu do innej aplikacji, a znika z pamięci po upływie
/// `lifetime` i przy zamknięciu arkusza (także razem z oknem ustawień).
private struct PairPhoneSheet: View {
    let pairing: PhonePairing

    @Environment(\.dismiss) private var dismiss
    @State private var deviceName = "iPhone"
    @State private var grantAdmin = false
    @State private var isCreating = false
    @State private var error: String?
    @State private var code: PhonePairing.Code?
    @State private var image: CGImage?
    @State private var isRevealed = false
    @State private var hideTask: Task<Void, Never>?
    @State private var expired = false
    @State private var createdKeyID: String?

    private static let visibleFor: Duration = .seconds(60)
    private static let lifetime: Duration = .seconds(5 * 60)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sparuj telefon").font(.title2.bold())
            if let code, let image {
                codeView(code: code, image: image)
            } else if expired {
                Text("Kod zniknął z ekranu. Jeśli telefon zdążył go zeskanować, wszystko jest gotowe; jeśli nie — unieważnij ten klucz na liście i sparuj telefon jeszcze raz.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Gotowe") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                form
            }
        }
        .padding(24)
        .frame(width: 460)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            hide()
        }
        .onDisappear { forget() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Nazwa telefonu", text: $deviceName, prompt: Text("np. iPhone Marka"))
                Toggle("Nadać kontu „\(pairing.listenerUsername ?? "")” uprawnienia administratora?", isOn: $grantAdmin)
                    .disabled(pairing.listenerIsAdmin)
                Text(pairing.listenerIsAdmin
                     ? "Konto ma już uprawnienia administratora; odbierzesz je w ustawieniach."
                     : AdminExplanation.text(username: pairing.listenerUsername ?? ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)

            Text("Adresy w kodzie: \(pairing.addresses.map(\.url.absoluteString).joined(separator: ", "))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !pairing.addresses.contains(where: { $0.kind == .remote }) {
                Text("Bez dostępu spoza domu telefon połączy się tylko w tej samej sieci co Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Anuluj") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Utwórz kod") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating)
            }
        }
    }

    private func codeView(code: PhonePairing.Code, image: CGImage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Zeskanuj kod aparatem iPhone’a albo w aplikacji AudiobookSwift („\(code.deviceName)”). Kod zawiera klucz dostępu — nie pokazuj go innym.")
                .fixedSize(horizontal: false, vertical: true)
            ZStack {
                Image(decorative: image, scale: 2)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 256, height: 256)
                    .blur(radius: isRevealed ? 0 : 24)
                    .opacity(isRevealed ? 1 : 0.15)
                    .accessibilityHidden(!isRevealed)
                if !isRevealed {
                    Button("Kliknij, aby pokazać kod") { reveal() }
                        .controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .onTapGesture { if !isRevealed { reveal() } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Kod parowania")

            Text(isRevealed ? "Kod zakryje się sam po minucie." : "Kod jest zakryty. Odsłoń go, gdy telefon będzie gotowy do skanowania.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button("Anuluj i unieważnij klucz", role: .destructive) { cancelAndRevoke() }
                Spacer()
                Button("Gotowe") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func create() {
        isCreating = true
        error = nil
        Task {
            defer { isCreating = false }
            do {
                let code = try await pairing.pair(deviceName: deviceName, grantAdmin: grantAdmin)
                guard let image = PairingQRCode.image(for: code.url) else {
                    self.error = "Nie udało się utworzyć obrazu kodu."
                    return
                }
                self.code = code
                self.image = image
                createdKeyID = code.keyID
                scheduleExpiry()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func reveal() {
        isRevealed = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    private func hide() {
        isRevealed = false
        hideTask?.cancel()
    }

    private func scheduleExpiry() {
        Task {
            try? await Task.sleep(for: Self.lifetime)
            guard code != nil else { return }
            forget()
            expired = true
        }
    }

    /// Usuwa kod (a z nim klucz) z pamięci widoku.
    private func forget() {
        hide()
        code = nil
        image = nil
    }

    private func cancelAndRevoke() {
        let keyID = createdKeyID
        forget()
        Task {
            if let keyID { try? await pairing.revoke(keyID: keyID) }
            dismiss()
        }
    }
}

/// Kod z samymi adresami serwera (bez klucza), dla już sparowanych telefonów.
private struct AddressesCodeSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Adresy serwera").font(.headline)
            Text("Zeskanuj kod aparatem iPhone’a albo w aplikacji AudiobookSwift („Zeskanuj kod z Maca”).")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let image = PairingQRCode.image(for: url) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                    .accessibilityLabel(Text("Kod z adresami serwera"))
            }
            Button("Gotowe") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 360)
    }
}

private struct AddressesCode: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
