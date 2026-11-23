// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 10g).

import Foundation
import OSLog

private let logger = Logger(subsystem: "net.smigi.abswift", category: "Ebook")

/// Format e-booka z punktu widzenia czytnika na telefonie.
public enum EbookFormat: Equatable, Sendable {
    case epub
    case pdf
    /// Inny format (MOBI, AZW3, CBZ…) — nazwa do komunikatu, wielkimi literami.
    case unsupported(String)

    /// `format` — `ebookFormat` z serwera; bez niego rozszerzenie pliku.
    public init(format: String?, filename: String?) {
        let name = (format?.isEmpty == false ? format : filename.map { ($0 as NSString).pathExtension })?.lowercased() ?? ""
        switch name {
        case "epub": self = .epub
        case "pdf": self = .pdf
        default: self = .unsupported(name.uppercased())
        }
    }

    /// Rozszerzenie pliku zapisanego na telefonie.
    public var fileExtension: String? {
        switch self {
        case .epub: "epub"
        case .pdf: "pdf"
        case .unsupported: nil
        }
    }

    /// Komunikat dla formatu, którego telefon nie czyta.
    public var unsupportedMessage: String? {
        guard case .unsupported(let name) = self else { return nil }
        let label = name.isEmpty ? "Ten format e-booka" : "Format \(name)"
        return "\(label) nie jest obsługiwany na telefonie — czytnik iOS otwiera EPUB i PDF. Książkę w tym formacie przeczytasz w AudiobookSwift na Macu albo w przeglądarce."
    }
}

/// Miejsce w e-booku zapisywane na serwerze (`ebookLocation`) — ten sam zapis co czytnik Maca i web UI:
/// CFI epub.js dla EPUB-a, numer strony od 1 dla PDF-a.
public enum EbookLocationValue {
    /// Strona PDF z zapisu (od 1); zapis innego formatu albo bzdura — `nil`.
    public static func pdfPage(_ value: String?) -> Int? {
        guard let value, let number = Double(value), number.isFinite, number >= 1, number < 1_000_000 else { return nil }
        return Int(number.rounded(.down))
    }

    /// CFI z zapisu; zapis innego formatu — `nil` (jak web UI: obca pozycja jest pomijana).
    public static func epubCFI(_ value: String?) -> String? {
        guard let value, value.hasPrefix("epubcfi(") else { return nil }
        return value
    }

    /// Postęp PDF-a liczony jak w czytniku Maca: przeczytane strony przed bieżącą.
    public static func pdfProgress(page: Int, count: Int) -> Double? {
        count > 0 ? Double(max(0, page - 1)) / Double(count) : nil
    }
}

/// Miejsce czytania zapamiętane na telefonie — czytanie bez sieci i zapis, który nie doszedł do
/// serwera. Jeden plik JSON na serwer (jak dziennik postępu słuchania).
@MainActor
public final class EbookPositionStore {
    public struct Record: Codable, Sendable, Equatable {
        public var location: String
        public var progress: Double?
        public var date: Date
        /// Zapis jest już na serwerze.
        public var sent: Bool

        public init(location: String, progress: Double?, date: Date, sent: Bool) {
            self.location = location
            self.progress = progress
            self.date = date
            self.sent = sent
        }
    }

    private let url: URL?
    private var records: [String: Record]

    /// `url == nil` — tylko w pamięci (testy).
    public init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    public func record(itemID: String) -> Record? { records[itemID] }

    /// Nowe miejsce z czytnika — do wysłania.
    public func update(itemID: String, location: String, progress: Double?, at date: Date = .now) {
        records[itemID] = Record(location: location, progress: progress, date: date, sent: false)
        persist()
    }

    /// Serwer przyjął zapis. Nowsze miejsce zapisane w międzyczasie zostaje do wysłania.
    public func markSent(itemID: String, location: String) {
        guard var record = records[itemID], record.location == location else { return }
        record.sent = true
        records[itemID] = record
        persist()
    }

    /// Niewysłane miejsca (do ponowienia przy następnej okazji).
    public var unsent: [(itemID: String, record: Record)] {
        records.filter { !$0.value.sent }.map { ($0.key, $0.value) }.sorted { $0.itemID < $1.itemID }
    }

    /// Skąd zacząć: niewysłany zapis z telefonu wygrywa (jest nowszy niż to, co wie serwer);
    /// inaczej pozycja z serwera (mogła się zmienić na innym urządzeniu), a bez sieci — ostatnia znana.
    public func startLocation(itemID: String, server: String?, serverReachable: Bool) -> String? {
        let local = records[itemID]
        if let local, !local.sent { return local.location }
        if serverReachable, let server, !server.isEmpty { return server }
        return local?.location ?? (server?.isEmpty == false ? server : nil)
    }

    public func removeAll() {
        records = [:]
        persist()
    }

    private func persist() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: url, options: .atomic)
        } catch {
            logger.error("Zapis miejsca czytania: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// E-booki otwarte bez pobierania książki — w `Caches` (system może je usunąć). Klucz: `ino`,
/// rozmiar i czas zmiany pliku, więc podmieniony e-book na serwerze pobiera się od nowa.
public struct EbookFileCache: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func standard() -> EbookFileCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return EbookFileCache(directory: caches.appending(path: "Ebooks", directoryHint: .isDirectory))
    }

    public static func key(ino: String, size: Double?, mtimeMs: Double?) -> String {
        let safe = ino.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return "\(safe)-\(Int64(size ?? 0))-\(Int64(mtimeMs ?? 0))"
    }

    private func folder(_ itemID: String) -> URL {
        directory.appending(path: DownloadedItem.folderName(for: itemID), directoryHint: .isDirectory)
    }

    /// Plik o tym kluczu, jeśli jest.
    public func file(itemID: String, key: String, ext: String) -> URL? {
        let url = folder(itemID).appending(path: "\(key).\(ext)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Ostatnio otwarty plik pozycji (bez sieci nie znamy klucza).
    public func latest(itemID: String) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(itemID), includingPropertiesForKeys: nil)) ?? []
        return files.first
    }

    /// Zapisuje plik (starsze wersje tej pozycji znikają) i zwraca jego adres.
    @discardableResult
    public func store(_ data: Data, itemID: String, key: String, ext: String) -> URL? {
        let folder = folder(itemID)
        let url = folder.appending(path: "\(key).\(ext)")
        do {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            logger.error("Zapis e-booka w pamięci podręcznej: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
