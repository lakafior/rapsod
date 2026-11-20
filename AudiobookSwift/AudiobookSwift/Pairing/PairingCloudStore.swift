import CloudKit
import Foundation

/// Rekordy parowania w prywatnej bazie CloudKit. Mac zapisuje i usuwa swój rekord,
/// klient iOS (etap 4) wywołuje `fetchAll()`. Zależy tylko od CloudKit.
struct PairingCloudStore: Sendable {
    var containerID = PairingSchema.containerID

    private var container: CKContainer { CKContainer(identifier: containerID) }
    private var database: CKDatabase { container.privateCloudDatabase }

    func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    /// Zapisuje rekord, nadpisując poprzednią wersję; w razie potrzeby tworzy strefę.
    func save(_ record: PairingRecord) async throws {
        let zone = CKRecordZone(zoneID: PairingSchema.zoneID)
        let zones = try await database.modifyRecordZones(saving: [zone], deleting: [])
        for result in zones.saveResults.values {
            _ = try result.get()
        }
        let saved = try await database.modifyRecords(saving: [record.makeRecord()], deleting: [], savePolicy: .allKeys)
        for result in saved.saveResults.values {
            _ = try result.get()
        }
    }

    /// Usuwa rekord serwera. Brak rekordu albo strefy nie jest błędem.
    func delete(serverID: String) async throws {
        let id = CKRecord.ID(recordName: serverID, zoneID: PairingSchema.zoneID)
        do {
            let deleted = try await database.modifyRecords(saving: [], deleting: [id])
            for result in deleted.deleteResults.values {
                try result.get()
            }
        } catch let error as CKError where Self.isMissing(error) {
            return
        }
    }

    /// Wszystkie rekordy parowania użytkownika, pobrane z serwera CloudKit.
    /// Rekordy w nieznanej wersji schematu są pomijane.
    func fetchAll() async throws -> [PairingRecord] {
        var records: [PairingRecord] = []
        var token: CKServerChangeToken?
        do {
            while true {
                let changes = try await database.recordZoneChanges(inZoneWith: PairingSchema.zoneID, since: token)
                for result in changes.modificationResultsByID.values {
                    let record = try result.get().record
                    if record.recordType == PairingSchema.recordType, let parsed = try? PairingRecord(record: record) {
                        records.append(parsed)
                    }
                }
                token = changes.changeToken
                if !changes.moreComing { break }
            }
        } catch let error as CKError where Self.isMissing(error) {
            return []
        }
        return records.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func isMissing(_ error: CKError) -> Bool {
        switch error.code {
        case .unknownItem, .zoneNotFound, .userDeletedZone: true
        case .partialFailure:
            error.partialErrorsByItemID?.values.allSatisfy { ($0 as? CKError).map(isMissing) ?? false } ?? false
        default: false
        }
    }
}
