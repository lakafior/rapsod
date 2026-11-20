import dnssd
import Foundation

/// Ogłasza serwer w sieci lokalnej przez Bonjour (`DNSServiceRegister`).
///
/// Port należy do procesu `node`, więc nie możemy użyć `NWListener`; rejestrujemy samą
/// usługę dla cudzego portu. Rekord TXT zawiera identyfikator serwera, po którym klient
/// dopasowuje usługę do rekordu CloudKit — nigdy token.
@MainActor
final class BonjourAdvertiser {
    enum Status: Equatable {
        case stopped
        case registering
        /// Nazwa, pod którą usługa jest widoczna (system może ją zmienić przy konflikcie).
        case advertised(name: String)
        case failed(String)
    }

    private(set) var status: Status = .stopped {
        didSet {
            if status != oldValue { onStatusChange?(status) }
        }
    }
    var onStatusChange: ((Status) -> Void)?

    private var service: DNSServiceRef?
    /// Co jest zarejestrowane — żeby nie rejestrować ponownie bez zmian.
    private var registration: Registration?

    private struct Registration: Equatable {
        let serverID: String
        let port: Int
        let basePath: String
    }

    func start(serverID: String, port: Int, basePath: String) {
        let wanted = Registration(serverID: serverID, port: port, basePath: basePath)
        if registration == wanted, service != nil { return }
        stop()

        let txt = Self.txtRecord([
            (PairingSchema.txtServerID, serverID),
            (PairingSchema.txtBasePath, basePath),
            (PairingSchema.txtVersion, String(PairingSchema.version)),
        ])
        var reference: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let error = txt.withUnsafeBytes { bytes in
            // Nazwa `nil` = nazwa komputera; port w sieciowej kolejności bajtów.
            DNSServiceRegister(
                &reference, 0, 0, nil, PairingSchema.bonjourType, nil, nil,
                UInt16(port).bigEndian, UInt16(bytes.count), bytes.baseAddress,
                { _, _, error, name, _, _, context in
                    guard let context else { return }
                    let registered = name.map { String(cString: $0) }
                    // Wywołania zwrotne przychodzą na kolejce głównej (`DNSServiceSetDispatchQueue`).
                    MainActor.assumeIsolated {
                        Unmanaged<BonjourAdvertiser>.fromOpaque(context).takeUnretainedValue()
                            .registrationDidFinish(error: error, name: registered)
                    }
                },
                context
            )
        }
        guard error == kDNSServiceErr_NoError, let reference else {
            status = .failed("Bonjour: błąd rejestracji usługi (\(error)).")
            return
        }
        DNSServiceSetDispatchQueue(reference, .main)
        service = reference
        registration = wanted
        status = .registering
    }

    func stop() {
        if let service {
            // Po zwolnieniu na kolejce głównej wywołania zwrotne już nie przyjdą.
            DNSServiceRefDeallocate(service)
        }
        service = nil
        registration = nil
        status = .stopped
    }

    private func registrationDidFinish(error: DNSServiceErrorType, name: String?) {
        guard service != nil else { return }
        if error == kDNSServiceErr_NoError, let name {
            status = .advertised(name: name)
        } else {
            status = .failed("Bonjour: nie udało się ogłosić usługi (\(error)).")
        }
    }

    /// Format rekordu TXT: ciąg wpisów „długość + `klucz=wartość`”.
    private static func txtRecord(_ entries: [(String, String)]) -> Data {
        var data = Data()
        for (key, value) in entries {
            let entry = Array("\(key)=\(value)".utf8.prefix(255))
            data.append(UInt8(entry.count))
            data.append(contentsOf: entry)
        }
        return data
    }
}
