import AudiobookshelfKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Observation
import OSLog
import SystemConfiguration

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Pairing")

/// Parowanie telefonu z aplikacją AudiobookSwift na iOS kodem QR (etap 10b).
///
/// Telefon dostaje **osobny klucz API konta słuchacza** — tego samego konta, którego używa Mac,
/// żeby postęp słuchania był jeden. Konto root i żadne hasło nie trafiają do kodu. Klucz tworzy
/// root (`POST /api/api-keys` wymaga administratora; dla konta innego niż root wolno), bez terminu
/// ważności i od razu aktywny. Klucz działa też w gnieździe zdarzeń (`SocketAuthority`).
///
/// Lista sparowanych urządzeń to klucze konta słuchacza z nazwą zaczynającą się od
/// `keyPrefix` — źródłem prawdy jest serwer, Mac nie przechowuje żadnych kluczy. Nazwa jest
/// zaszyta w samym kluczu (JWT), więc po parowaniu nie da się jej zmienić; unieważnienie
/// usuwa klucz z serwera.
@MainActor
@Observable
final class PhonePairing {
    struct Device: Identifiable, Equatable {
        let id: String
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
        case listenerMissing
        case noAddresses

        var errorDescription: String? {
            switch self {
            case .listenerMissing: "Nie znaleziono na serwerze konta do słuchania."
            case .noAddresses: "Telefon nie ma jak połączyć się z tym Makiem — włącz udostępnianie w sieci lokalnej albo dostęp spoza domu."
            }
        }
    }

    /// Przedrostek nazwy klucza API, po którym aplikacja rozpoznaje sparowane telefony.
    static let keyPrefix = "Telefon: "

    private(set) var devices: [Device] = []
    /// Konto słuchacza ma typ `admin` (może zlecać pobieranie odcinków i zarządzać serwerem).
    private(set) var listenerIsAdmin = false
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

    /// Konto słuchacza gotowe — bez niego nie ma czego parować.
    var listenerUsername: String? {
        guard account.state == .ready, case .ready(let username) = account.userState else { return nil }
        return username
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

    /// Dlaczego nie da się teraz sparować telefonu (`nil` = można).
    var unavailableReason: String? {
        if listenerUsername == nil {
            return "Parowanie wymaga działającego serwera i konta do słuchania."
        }
        if addresses.isEmpty {
            return "Telefon łączy się z Makiem przez sieć: najpierw włącz „Udostępniaj serwer w sieci lokalnej” powyżej (albo dostęp spoza domu)."
        }
        return nil
    }

    /// Nazwa serwera w kodzie i w aplikacji na telefonie: nazwa tego Maca.
    static var serverName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    // MARK: - Lista

    func refresh() async {
        guard listenerUsername != nil else {
            devices = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let listener = try await listener()
            let keys = try await account.withAdminToken { try await $0.apiKeys(token: $1) }
            devices = keys
                .filter { $0.userId == listener.id && $0.name.hasPrefix(Self.keyPrefix) }
                .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
                .map {
                    Device(
                        id: $0.id,
                        name: String($0.name.dropFirst(Self.keyPrefix.count)),
                        createdAt: $0.createdAt,
                        lastUsedAt: $0.lastUsedAt,
                        isActive: $0.isActive,
                        isExpired: $0.isExpired
                    )
                }
            listenerIsAdmin = listener.type == "admin"
            loadError = nil
        } catch {
            logger.error("Lista sparowanych telefonów: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
    }

    // MARK: - Parowanie

    /// Tworzy klucz dla telefonu i składa kod. Z `grantAdmin` konto słuchacza dostaje najpierw
    /// typ `admin` (pytanie w arkuszu parowania; domyślnie nie).
    func pair(deviceName: String, grantAdmin: Bool) async throws -> Code {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceName = name.isEmpty ? "Telefon" : name
        let addresses = addresses
        guard !addresses.isEmpty else { throw PairingError.noAddresses }

        var listener = try await listener()
        if grantAdmin, listener.type != "admin" {
            listener = try await setType("admin", of: listener)
        }
        let created = try await account.withAdminToken {
            try await $0.createApiKey(name: Self.keyPrefix + deviceName, userID: listener.id, expiresIn: nil, isActive: true, token: $1)
        }
        // Bez treści klucza: tylko nazwa i identyfikator.
        logger.notice("Utworzono klucz dla telefonu „\(deviceName, privacy: .public)” (\(created.key.id, privacy: .public))")

        let payload = PairingPayload(
            server: .init(id: sharing.ensureServerID(), name: Self.serverName),
            addresses: addresses,
            account: .init(id: listener.id, username: listener.username),
            device: .init(keyID: created.key.id, name: deviceName),
            key: created.secret
        )
        let code = Code(url: try payload.url(), deviceName: deviceName, keyID: created.key.id)
        await refresh()
        return code
    }

    /// Kod „Odśwież adresy” (etap 10c): aktualne adresy serwera bez klucza, dla już sparowanych
    /// telefonów (np. po włączeniu tunelu). `nil`, gdy nie ma adresów albo żaden telefon nie był parowany.
    func addressesCode() -> URL? {
        guard let serverID = sharing.settings.serverID, !addresses.isEmpty else { return nil }
        let payload = AddressesPayload(server: .init(id: serverID, name: Self.serverName), addresses: addresses)
        return try? payload.url()
    }

    /// Unieważnia klucz telefonu (usuwa go z serwera). Telefon dostaje 401 przy następnym zapytaniu.
    func revoke(keyID: String) async throws {
        try await account.withAdminToken { try await $0.deleteApiKey(id: keyID, token: $1) }
        logger.notice("Unieważniono klucz telefonu \(keyID, privacy: .public)")
        await refresh()
    }

    /// Nadaje albo odbiera kontu słuchacza uprawnienia administratora.
    func setListenerAdmin(_ admin: Bool) async throws {
        let listener = try await listener()
        let type = admin ? "admin" : "user"
        if listener.type != type {
            _ = try await setType(type, of: listener)
        }
        await refresh()
    }

    // MARK: - Pomocnicze

    private func listener() async throws -> AudiobookshelfClient.ManagedUser {
        guard let username = listenerUsername else { throw PairingError.listenerMissing }
        let users = try await account.withAdminToken { try await $0.users(token: $1) }
        guard let user = users.first(where: { $0.username == username }) else { throw PairingError.listenerMissing }
        return user
    }

    /// Zmienia tylko typ konta: `UserChanges` zawsze wysyła uprawnienia, więc odsyłamy obecne.
    private func setType(_ type: String, of user: AudiobookshelfClient.ManagedUser) async throws -> AudiobookshelfClient.ManagedUser {
        let changes = AudiobookshelfClient.UserChanges(
            type: type,
            permissions: user.permissions,
            librariesAccessible: user.librariesAccessible,
            itemTagsSelected: user.itemTagsSelected
        )
        let updated = try await account.withAdminToken { try await $0.updateUser(id: user.id, changes, token: $1) }
        logger.notice("Konto słuchacza ma teraz typ \(type, privacy: .public)")
        listenerIsAdmin = updated.type == "admin"
        account.listenerPermissionsChanged()
        return updated
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
