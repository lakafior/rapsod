import CloudKit
import Foundation

/// Stałe wspólne dla Maca (zapis) i klienta iOS (odczyt).
enum PairingSchema {
    /// Kontener iCloud wspólny dla obu aplikacji; rekordy leżą w prywatnej bazie użytkownika.
    static let containerID = "iCloud.net.smigi.abswift"
    /// Własna strefa: klient pobiera wszystkie rekordy przez zmiany strefy,
    /// bez zapytań wymagających indeksów ustawianych w konsoli CloudKit.
    static let zoneName = "Pairing"
    static let recordType = "Server"
    static let version = 1

    /// Usługa Bonjour ogłaszana przez Maca. Rekord TXT nie zawiera sekretów.
    static let bonjourType = "_abswift._tcp"
    /// Klucze TXT: identyfikator serwera (= nazwa rekordu CloudKit), ścieżka bazowa, wersja schematu.
    static let txtServerID = "id"
    static let txtBasePath = "path"
    static let txtVersion = "v"

    static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }
}

/// Rekord parowania: wszystko, czego klient potrzebuje, żeby znaleźć serwer i się uwierzytelnić.
///
/// Nazwa rekordu CloudKit to `serverID`. Pola rekordu noszą nazwy właściwości poniżej;
/// `token` jest zapisany w `encryptedValues`, reszta jawnie.
struct PairingRecord: Sendable, Equatable {
    /// Stały identyfikator serwera (UUID tworzony raz na folder danych).
    var serverID: String
    /// Nazwa Maca do pokazania użytkownikowi.
    var name: String
    /// Nazwa mDNS z końcówką `.local`, np. `mini.local`; pusta, gdy nieznana.
    var localHostName: String
    /// Adresy IPv4 Maca w sieci lokalnej w chwili zapisu.
    var addresses: [String]
    var port: Int
    /// `ROUTER_BASE_PATH` serwera, np. `/audiobookshelf`.
    var basePath: String
    /// Wersja audiobookshelf.
    var serverVersion: String
    /// Nazwa konta, do którego należy token.
    var username: String
    /// Pełny adres spoza sieci lokalnej (np. własny tunel), razem ze ścieżką bazową.
    /// Pusty, dopóki użytkownik go nie wpisze; aplikacja Maca niczego tu sama nie ustawia.
    var externalURL: String
    /// Klucz API audiobookshelf (nagłówek `Authorization: Bearer …`).
    var token: String
    var updatedAt: Date

    /// Czy rekordy różnią się czymś poza czasem aktualizacji.
    func hasSameContent(as other: PairingRecord) -> Bool {
        var other = other
        other.updatedAt = updatedAt
        return self == other
    }

    /// Adresy bazowe API do wypróbowania po kolei: nazwa `.local`, adresy IP, adres zewnętrzny.
    /// W sieci lokalnej serwer mówi zwykłym HTTP.
    var candidateURLs: [URL] {
        let hosts = (localHostName.isEmpty ? [] : [localHostName]) + addresses
        var urls = hosts.compactMap { URL(string: "http://\($0):\(port)\(basePath)") }
        if let external = URL(string: externalURL), external.host() != nil {
            urls.append(external)
        }
        return urls
    }
}

// MARK: - CloudKit

extension PairingRecord {
    enum DecodingError: LocalizedError {
        case missingField(String)
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .missingField(let name): "Rekord parowania nie ma pola „\(name)”."
            case .unsupportedVersion(let version): "Nieobsługiwana wersja rekordu parowania: \(version)."
            }
        }
    }

    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: serverID, zoneID: PairingSchema.zoneID)
    }

    /// Nowy `CKRecord` z kompletem pól; zapisywany z polityką `.allKeys` nadpisuje poprzedni.
    func makeRecord() -> CKRecord {
        let record = CKRecord(recordType: PairingSchema.recordType, recordID: recordID)
        record["version"] = PairingSchema.version
        record["name"] = name
        record["localHostName"] = localHostName
        record["addresses"] = addresses
        record["port"] = port
        record["basePath"] = basePath
        record["serverVersion"] = serverVersion
        record["username"] = username
        record["externalURL"] = externalURL
        record["updatedAt"] = updatedAt
        record.encryptedValues["token"] = token
        return record
    }

    init(record: CKRecord) throws {
        let version = record["version"] as? Int ?? 0
        guard version == PairingSchema.version else { throw DecodingError.unsupportedVersion(version) }
        func required<T>(_ key: String, _ value: T?) throws -> T {
            guard let value else { throw DecodingError.missingField(key) }
            return value
        }
        self.init(
            serverID: record.recordID.recordName,
            name: try required("name", record["name"] as? String),
            localHostName: record["localHostName"] as? String ?? "",
            // CloudKit nie przechowuje pustych list — brak pola oznacza brak adresów.
            addresses: record["addresses"] as? [String] ?? [],
            port: try required("port", record["port"] as? Int),
            basePath: try required("basePath", record["basePath"] as? String),
            serverVersion: record["serverVersion"] as? String ?? "",
            username: record["username"] as? String ?? "",
            externalURL: record["externalURL"] as? String ?? "",
            token: try required("token", record.encryptedValues["token"] as? String),
            updatedAt: record["updatedAt"] as? Date ?? record.modificationDate ?? .distantPast
        )
    }
}
