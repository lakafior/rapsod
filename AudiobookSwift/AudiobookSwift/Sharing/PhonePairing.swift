import AudiobookshelfKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Observation
import OSLog
import SystemConfiguration

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Pairing")

/// Podłączanie telefonu z aplikacją AudiobookSwift na iOS kodem QR (etap 10b; od etapu 2 nowego
/// układu ustawień — dla każdego konta, decyzja z części 9 `docs/ustawienia-nowy-uklad.md`).
///
/// Telefon dostaje **osobny klucz API wybranego konta**. Dla konta tego Maca to to samo konto,
/// którego używa Mac, więc postęp słuchania jest jeden; inna osoba ma na telefonie swój postęp.
/// Konto root i żadne hasło nie trafiają do kodu, root nie dostaje telefonów. Klucz tworzy root
/// (`POST /api/api-keys` wymaga administratora; dla konta innego niż root wolno), bez terminu
/// ważności i od razu aktywny. Klucz działa też w gnieździe zdarzeń (`SocketAuthority`).
///
/// Lista podłączonych urządzeń to klucze z nazwą zaczynającą się od `keyPrefix`, pogrupowane po
/// `userId` — źródłem prawdy jest serwer, Mac nie przechowuje żadnych kluczy. Nazwa jest zaszyta
/// w samym kluczu (JWT), więc po podłączeniu nie da się jej zmienić; „Odłącz” usuwa klucz z serwera.
@MainActor
@Observable
final class PhonePairing {
    struct Device: Identifiable, Equatable {
        let id: String
        let userID: String
        let name: String
        let createdAt: Date?
        /// Upstream (v2.38.0) ma kolumnę `lastUsedAt`, ale jej nie uzupełnia.
        let lastUsedAt: Date?
        let isActive: Bool
        let isExpired: Bool
    }

    /// Gotowy kod do pokazania. Trzymany tylko w pamięci widoku, który go pokazuje.
    struct Code: Equatable {
        let url: URL
        let deviceName: String
        let keyID: String
    }

    enum PairingError: LocalizedError {
        case rootAccount
        case noAddresses

        var errorDescription: String? {
            switch self {
            case .rootAccount: "Konto root nigdy nie trafia do telefonu."
            case .noAddresses: "Telefon nie ma jak połączyć się z tym Makiem — włącz sieć domową albo dostęp spoza domu (Ustawienia → Dostęp zdalny)."
            }
        }
    }

    /// Przedrostek nazwy klucza API, po którym aplikacja rozpoznaje telefony. **Nie zmieniać:**
    /// już podłączone telefony zniknęłyby z listy (część 7 planu).
    static let keyPrefix = "Telefon: "

    /// Telefony wszystkich kont (od najnowszego).
    private(set) var devices: [Device] = []
    /// Liczba pozostałych kluczy API (nie telefonów) każdego konta — do profilu osoby.
    private(set) var otherKeyCounts: [String: Int] = [:]
    private(set) var isLoading = false
    private(set) var loadError: String?

    @ObservationIgnored private let account: ServerAccount
    @ObservationIgnored private let sharing: SharingController
    @ObservationIgnored private let supervisor: ServerSupervisor

    init(account: ServerAccount, sharing: SharingController, supervisor: ServerSupervisor) {
        self.account = account
        self.sharing = sharing
        self.supervisor = supervisor
    }

    func devices(for userID: String) -> [Device] {
        devices.filter { $0.userID == userID }
    }

    /// Adresy, które trafią do kodu: sieć lokalna (gdy serwer faktycznie w niej słucha), potem spoza domu.
    var addresses: [PairingPayload.Address] {
        var result: [PairingPayload.Address] = []
        if sharing.isEnabled, supervisor.state == .running, supervisor.environment?.listensOnLAN == true {
            result += sharing.localURLs.map { .init(url: $0, kind: .local) }
        }
        if let external = sharing.externalURL {
            result.append(.init(url: external, kind: .remote))
        }
        return result
    }

    /// Czy arkusz może zaproponować włączenie sieci domowej (wymaga konta tego Maca, jak przełącznik
    /// na stronie „Dostęp zdalny”, bo niezainicjalizowany serwer w sieci byłby niebezpieczny).
    var canEnableHomeNetwork: Bool {
        guard !sharing.isEnabled, !sharing.isBusy, account.state == .ready, case .ready = account.userState else { return false }
        return true
    }

    /// Dlaczego nie da się teraz podłączyć telefonu do tego konta (`nil` = można, ewentualnie po
    /// włączeniu sieci domowej w arkuszu).
    func unavailableReason(for user: AudiobookshelfClient.ManagedUser) -> String? {
        if user.isRoot { return PairingError.rootAccount.errorDescription }
        if account.state != .ready { return "Podłączanie telefonu wymaga działającego serwera." }
        if addresses.isEmpty, !canEnableHomeNetwork, !sharing.isBusy {
            return "Telefon łączy się z Makiem przez sieć: włącz sieć domową albo dostęp spoza domu w Ustawieniach → Dostęp zdalny."
        }
        return nil
    }

    /// Nazwa serwera w kodzie i w aplikacji na telefonie: nazwa tego Maca.
    static var serverName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    // MARK: - Lista

    /// Wczytuje klucze telefonów wszystkich kont jednym zapytaniem.
    func refresh() async {
        guard account.state == .ready else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let keys = try await account.withAdminToken { try await $0.apiKeys(token: $1) }
            otherKeyCounts = Dictionary(grouping: keys.filter { !$0.name.hasPrefix(Self.keyPrefix) }, by: { $0.userId ?? "" })
                .mapValues(\.count)
            devices = keys
                .filter { $0.name.hasPrefix(Self.keyPrefix) && $0.userId != nil }
                .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
                .map {
                    Device(
                        id: $0.id,
                        userID: $0.userId ?? "",
                        name: String($0.name.dropFirst(Self.keyPrefix.count)),
                        createdAt: $0.createdAt,
                        lastUsedAt: $0.lastUsedAt,
                        isActive: $0.isActive,
                        isExpired: $0.isExpired
                    )
                }
            loadError = nil
        } catch {
            logger.error("Lista telefonów: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
    }

    // MARK: - Podłączanie

    /// Tworzy klucz dla telefonu wybranego konta i składa kod. Uprawnienia (rola) zmienia
    /// wywołujący przed tym wywołaniem — tu nic poza kluczem się nie zmienia.
    func pair(deviceName: String, user: AudiobookshelfClient.ManagedUser) async throws -> Code {
        guard !user.isRoot else { throw PairingError.rootAccount }
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceName = name.isEmpty ? "Telefon" : name
        let addresses = addresses
        guard !addresses.isEmpty else { throw PairingError.noAddresses }

        let created = try await account.withAdminToken {
            try await $0.createApiKey(name: Self.keyPrefix + deviceName, userID: user.id, expiresIn: nil, isActive: true, token: $1)
        }
        // Bez treści klucza: tylko nazwa i identyfikator.
        logger.notice("Utworzono klucz dla telefonu „\(deviceName, privacy: .public)” (\(created.key.id, privacy: .public))")

        let payload = PairingPayload(
            server: .init(id: sharing.ensureServerID(), name: Self.serverName),
            addresses: addresses,
            account: .init(id: user.id, username: user.username),
            device: .init(keyID: created.key.id, name: deviceName),
            key: created.secret
        )
        let code = Code(url: try payload.url(), deviceName: deviceName, keyID: created.key.id)
        // Jedyny telefon zna obecne adresy; przy innych telefonach baner o adresach zostaje.
        let wasFirst = devices.isEmpty
        await refresh()
        if wasFirst { sharing.markRemoteAddressesKnownToPhones() }
        return code
    }

    /// Kod „Kod z adresami” (etap 10c): aktualne adresy serwera bez klucza, dla już podłączonych
    /// telefonów wszystkich kont (np. po włączeniu tunelu). `nil`, gdy nie ma adresów albo żaden
    /// telefon nie był podłączany.
    func addressesCode() -> URL? {
        guard let serverID = sharing.settings.serverID, !addresses.isEmpty else { return nil }
        let payload = AddressesPayload(server: .init(id: serverID, name: Self.serverName), addresses: addresses)
        guard let url = try? payload.url() else { return nil }
        sharing.markRemoteAddressesKnownToPhones()
        return url
    }

    /// Odłącza telefon: usuwa jego klucz z serwera. Telefon dostaje 401 przy następnym zapytaniu.
    func revoke(keyID: String) async throws {
        try await account.withAdminToken { try await $0.deleteApiKey(id: keyID, token: $1) }
        logger.notice("Odłączono telefon (klucz \(keyID, privacy: .public))")
        await refresh()
    }

    /// Telefon może zlecać pobrania odcinków: administrator z „Edycją pozycji”. Sam typ
    /// administratora (nadany przed etapem 10e) nie wystarcza.
    static func canOrderDownloads(_ user: AudiobookshelfClient.ManagedUser) -> Bool {
        user.type == "admin" && user.permissions.update
    }
}

/// Obraz kodu QR (CoreImage, bez rozmywania pikseli przy powiększaniu).
enum PairingQRCode {
    static func image(for url: URL, pixels: CGFloat = 512) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = (pixels / output.extent.width).rounded(.down)
        let scaled = output.samplingNearest().transformed(by: CGAffineTransform(scaleX: max(scale, 1), y: max(scale, 1)))
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(scaled, from: scaled.extent)
    }
}
