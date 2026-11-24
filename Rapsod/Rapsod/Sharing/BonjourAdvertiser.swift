import dnssd
import Foundation
import OSLog
import AudiobookshelfKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Rapsod", category: "Bonjour")

/// Ogłoszenie serwera w sieci lokalnej (etap 10c): usługa `_rapsod._tcp` na porcie serwera
/// z identyfikatorem serwera i adresem `.local` w rekordzie TXT. Sparowany telefon szuka jej,
/// gdy zapisany adres lokalny przestał odpowiadać (np. Mac dostał nowy adres), i sprawdza
/// znaleziony adres swoim kluczem, zanim go zapisze. Ogłoszenie nie niesie żadnego sekretu.
@MainActor
final class BonjourAdvertiser {
    struct Advertisement: Equatable {
        let serverID: String
        let url: URL
        let port: UInt16
    }

    private var current: Advertisement?
    private var service: DNSServiceRef?

    /// Ustawia ogłoszenie; `nil` je wycofuje. Ta sama wartość niczego nie zmienia.
    func update(_ advertisement: Advertisement?) {
        guard advertisement != current else { return }
        stop()
        guard let advertisement else { return }
        current = advertisement

        var txt = TXTRecordRef()
        TXTRecordCreate(&txt, 0, nil)
        defer { TXTRecordDeallocate(&txt) }
        for (key, value) in LocalDiscovery.txtRecord(serverID: advertisement.serverID, url: advertisement.url) {
            let bytes = Array(value.utf8)
            _ = TXTRecordSetValue(&txt, key, UInt8(min(bytes.count, 255)), bytes)
        }

        var ref: DNSServiceRef?
        let error = DNSServiceRegister(
            &ref, 0, 0,
            nil, // nazwa usługi: nazwa komputera
            LocalDiscovery.serviceType,
            nil, nil,
            advertisement.port.bigEndian,
            TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt),
            nil, nil
        )
        guard error == kDNSServiceErr_NoError, let ref else {
            logger.error("Ogłoszenie Bonjour nie powiodło się (\(error))")
            current = nil
            return
        }
        DNSServiceSetDispatchQueue(ref, .main)
        service = ref
        logger.notice("Ogłoszenie Bonjour: \(advertisement.url.absoluteString, privacy: .public)")
    }

    func stop() {
        if let service {
            DNSServiceRefDeallocate(service)
            logger.notice("Wycofano ogłoszenie Bonjour")
        }
        service = nil
        current = nil
    }
}
