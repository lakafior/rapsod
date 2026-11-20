import Foundation

/// Diagnostyka uruchamiana argumentem `-ABSPairingCheck YES`: osobny proces pobiera
/// rekordy parowania prosto z CloudKit (tak jak zrobi to klient iOS), wypisuje je bez
/// tokenu i sprawdza tokenem każdy adres (`GET /api/me`). Serwer nie jest uruchamiany.
///
/// Z dodatkowym `-ABSPairingCheckRevocation YES` czeka potem (do 2 minut), aż w iCloud
/// pojawi się nowy token — po „Unieważnij…” w oknie statusu — i sprawdza, że stary
/// jest już odrzucany, a nowy działa. Tokeny nie są wypisywane.
enum PairingSelfCheck {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "ABSPairingCheck") }

    static func run() async -> Int32 {
        do {
            let records = try await PairingCloudStore().fetchAll()
            print("Rekordy parowania w iCloud: \(records.count)")
            for record in records {
                print("""
                — \(record.serverID)
                  name: \(record.name)
                  localHostName: \(record.localHostName)
                  addresses: \(record.addresses.joined(separator: ", "))
                  port: \(record.port)  basePath: \(record.basePath)
                  serverVersion: \(record.serverVersion)  username: \(record.username)
                  externalURL: \(record.externalURL.isEmpty ? "(pusty)" : record.externalURL)
                  token: (zaszyfrowany, \(record.token.count) znaków)
                  updatedAt: \(record.updatedAt.formatted(.iso8601))
                """)
                for url in record.candidateURLs {
                    print("  \(url.absoluteString) → \(await probe(url, token: record.token))")
                }
            }
            if UserDefaults.standard.bool(forKey: "ABSPairingCheckRevocation") {
                try await watchRevocation(of: records)
            }
            return 0
        } catch {
            print("Błąd odczytu z iCloud: \(error.localizedDescription)")
            return 1
        }
    }

    private static func watchRevocation(of records: [PairingRecord]) async throws {
        print("Czekam na nowy token w iCloud…")
        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let current = try await PairingCloudStore().fetchAll()
            for old in records {
                guard let new = current.first(where: { $0.serverID == old.serverID }), new.token != old.token,
                      let url = new.candidateURLs.first else { continue }
                print("— \(old.serverID): token w iCloud zmieniony")
                print("  stary token → \(await probe(url, token: old.token))")
                print("  nowy token → \(await probe(url, token: new.token))")
                return
            }
        }
        print("Token nie zmienił się w ciągu 2 minut.")
    }

    private static func probe(_ url: URL, token: String) async -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let client = AudiobookshelfClient(baseURL: url, session: URLSession(configuration: configuration))
        do {
            let user = try await client.me(token: token)
            return "OK, token należy do „\(user.username)” (\(user.type))"
        } catch AudiobookshelfClient.APIError.unauthorized {
            return "401 — token odrzucony"
        } catch {
            return "brak połączenia: \(error.localizedDescription)"
        }
    }
}
