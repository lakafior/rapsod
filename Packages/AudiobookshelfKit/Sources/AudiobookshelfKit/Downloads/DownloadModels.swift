// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 10f). Pomysł stanów pobrania i sprawdzania miejsca —
// z `DownloadRecord`/`DownloadManager` projektu Dove (MPL-2.0, ten sam autor), przepisany dla
// pozycji audiobookshelf z wieloma plikami.

import Foundation

/// Plik audio pobieranej pozycji.
public struct DownloadedFile: Codable, Sendable, Equatable, Identifiable {
    public enum State: Codable, Sendable, Equatable {
        /// Czeka na swoją kolej (albo na właściwą sieć).
        case queued
        case downloading
        case done
        /// Błąd, którego ponawianie nie naprawi (brak uprawnień, plik zniknął z serwera).
        case failed(String)
    }

    /// Identyfikator pliku na serwerze (`/api/items/:id/file/:ino`).
    public var ino: String
    /// Kolejność na osi czasu książki (`index` ścieżki z serwera).
    public var index: Int
    /// Nazwa pliku w katalogu pozycji — rozszerzenie z oryginału (AVFoundation rozpoznaje po nim format).
    public var fileName: String
    public var title: String
    public var startOffset: Double
    public var duration: Double
    /// Rozmiar według serwera — do sprawdzenia miejsca i kompletności pliku.
    public var expectedSize: Int64?
    public var state: State
    /// Nieudane próby z rzędu (błędy sieci), zerowane po sukcesie.
    public var attempts: Int

    public var id: String { ino }

    public init(ino: String, index: Int, fileName: String, title: String, startOffset: Double, duration: Double, expectedSize: Int64?, state: State = .queued, attempts: Int = 0) {
        self.ino = ino
        self.index = index
        self.fileName = fileName
        self.title = title
        self.startOffset = startOffset
        self.duration = duration
        self.expectedSize = expectedSize
        self.state = state
        self.attempts = attempts
    }

    /// Bezpieczna nazwa pliku z identyfikatora i rozszerzenia oryginału.
    public static func localName(index: Int, ino: String, originalName: String?) -> String {
        let ext = (originalName.map { ($0 as NSString).pathExtension } ?? "").lowercased()
        let safeIno = ino.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let stem = String(format: "%03d-", index) + (safeIno.isEmpty ? "plik" : safeIno)
        return ext.isEmpty || ext.count > 5 ? stem : stem + "." + ext
    }
}

public struct DownloadedChapter: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var title: String

    public init(start: Double, end: Double, title: String) {
        self.start = start
        self.end = end
        self.title = title
    }
}

/// Pozycja (książka) albo odcinek podcastu pobrany na urządzenie — z metadanymi potrzebnymi bez sieci.
public struct DownloadedItem: Codable, Sendable, Equatable, Identifiable {
    /// `ProgressJournal.key(itemID, episodeID)`.
    public var id: String
    /// Serwer, z którego pochodzi (identyfikator serwera z parowania).
    public var scope: String
    public var itemID: String
    public var episodeID: String?
    public var libraryID: String?
    /// `book` albo `podcast`.
    public var mediaType: String
    public var title: String
    /// Autor książki albo tytuł podcastu.
    public var author: String?
    public var duration: Double
    /// Rozdziały z serwera (puste — po jednym na plik).
    public var chapters: [DownloadedChapter]
    public var files: [DownloadedFile]
    /// Katalog pozycji względem katalogu pobranych (ścieżki względne: katalog aplikacji
    /// zmienia położenie po aktualizacji).
    public var folder: String
    public var hasCover: Bool
    public var addedAt: Date
    /// Wstrzymane przez użytkownika.
    public var isPaused: Bool
    public var completedAt: Date?

    /// Mapa tekstu (etap 11b) w katalogu pozycji — sama obecność pliku wystarcza, indeks się nie zmienia.
    public static let textSyncFileName = "textsync.json"
    /// Znaczniki segmentów sponsorowanych odcinka (etap 13a) — pomijanie bez sieci.
    public static let skipFileName = "skip.json"
    /// E-book książki (etap 10g) — `ebook.epub` albo `ebook.pdf`; czytnik działa bez sieci.
    public static let ebookFileStem = "ebook"
    public static func ebookFileName(ext: String) -> String { "\(ebookFileStem).\(ext)" }
    static func isEbookFileName(_ name: String) -> Bool { name.hasPrefix(ebookFileStem + ".") && !name.dropFirst(ebookFileStem.count + 1).contains("/") }

    public var isEpisode: Bool { episodeID != nil }
    public var isComplete: Bool { !files.isEmpty && files.allSatisfy { $0.state == .done } }
    public var expectedBytes: Int64 { files.reduce(0) { $0 + ($1.expectedSize ?? 0) } }
    public var failure: String? {
        for file in files { if case .failed(let reason) = file.state { return reason } }
        return nil
    }
    /// Bajty, które jeszcze trzeba pobrać (według rozmiarów z serwera).
    public var remainingBytes: Int64 {
        files.filter { $0.state != .done }.reduce(0) { $0 + ($1.expectedSize ?? 0) }
    }

    public init(scope: String, itemID: String, episodeID: String?, libraryID: String?, mediaType: String, title: String, author: String?, duration: Double, chapters: [DownloadedChapter], files: [DownloadedFile], hasCover: Bool = false, addedAt: Date = .now) {
        self.id = ProgressJournal.key(itemID, episodeID)
        self.scope = scope
        self.itemID = itemID
        self.episodeID = episodeID
        self.libraryID = libraryID
        self.mediaType = mediaType
        self.title = title
        self.author = author
        self.duration = duration
        self.chapters = chapters
        self.files = files.sorted { $0.index < $1.index }
        self.folder = Self.folderName(for: id)
        self.hasCover = hasCover
        self.addedAt = addedAt
        self.isPaused = false
        self.completedAt = nil
    }

    /// Stała nazwa katalogu z klucza (FNV-1a) — bez znaków z tytułu.
    public static func folderName(for key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// Dlaczego pobieranie czeka.
public enum DownloadWait: Sendable, Equatable {
    /// Ustawienie „tylko przez Wi-Fi”, a telefon jest w sieci komórkowej.
    case wifi
    /// Połączenie z serwerem idzie przez dostęp spoza domu, a pobieranie przez tunel jest wyłączone.
    case homeNetwork
    /// Brak połączenia z serwerem.
    case connection

    public var text: String {
        switch self {
        case .wifi: "Czeka na Wi-Fi"
        case .homeNetwork: "Czeka na sieć domową"
        case .connection: "Czeka na połączenie z serwerem"
        }
    }
}

/// Czy wolno teraz pobierać i skąd.
public enum DownloadGate: Sendable, Equatable {
    case open(baseURL: URL, allowsCellular: Bool)
    case closed(DownloadWait)
}

/// Ustawienia „skąd pobierać” zamienione na decyzję dla bieżącego połączenia.
public struct DownloadPolicy: Sendable, Equatable {
    /// Domyślnie włączone: duże pliki nie zjadają pakietu danych.
    public var wifiOnly: Bool
    /// Domyślnie wyłączone: darmowy plan Cloudflare zastrzega ograniczenia dla dużych plików
    /// (treści innych niż strony) przesyłanych przez tunel.
    public var allowsTunnel: Bool

    public init(wifiOnly: Bool = true, allowsTunnel: Bool = false) {
        self.wifiOnly = wifiOnly
        self.allowsTunnel = allowsTunnel
    }

    /// - Parameters:
    ///   - baseURL: bieżący adres serwera, `nil` — brak połączenia.
    ///   - isLocalAddress: adres w sieci domowej (nie tunel).
    ///   - onWiFi: telefon jest w sieci Wi-Fi albo na kablu.
    public func gate(baseURL: URL?, isLocalAddress: Bool, onWiFi: Bool) -> DownloadGate {
        guard let baseURL else { return .closed(.connection) }
        if wifiOnly, !onWiFi { return .closed(.wifi) }
        if !isLocalAddress, !allowsTunnel { return .closed(.homeNetwork) }
        return .open(baseURL: baseURL, allowsCellular: !wifiOnly)
    }
}

/// Stan pobrania pozycji do pokazania.
public enum DownloadStatus: Sendable, Equatable {
    case notDownloaded
    case queued
    case waiting(DownloadWait)
    /// 0…1.
    case downloading(Double)
    case paused(Double)
    case failed(String)
    case downloaded

    public var isActive: Bool {
        switch self {
        case .queued, .waiting, .downloading, .paused, .failed: true
        case .notDownloaded, .downloaded: false
        }
    }

    /// Do etykiety VoiceOver i podpisu.
    public var text: String {
        switch self {
        case .notDownloaded: "Nie pobrano"
        case .queued: "W kolejce"
        case .waiting(let wait): wait.text
        case .downloading(let fraction): "Pobieranie \(Int((fraction * 100).rounded(.down))) %"
        case .paused(let fraction): fraction > 0 ? "Wstrzymane, \(Int((fraction * 100).rounded(.down))) %" : "Wstrzymane"
        case .failed(let reason): "Błąd pobierania: \(reason)"
        case .downloaded: "Pobrano na telefon"
        }
    }
}

/// Obliczenia na indeksie pobranych — bez plików i sieci, do testów.
public enum DownloadIndex {
    /// Stan pozycji przy danym stanie sieci. `written` — bajty pobrane w trwających zadaniach.
    public static func status(of item: DownloadedItem?, gate: DownloadGate, written: [String: Int64] = [:]) -> DownloadStatus {
        guard let item else { return .notDownloaded }
        if item.isComplete { return .downloaded }
        if let failure = item.failure { return .failed(failure) }
        let fraction = Self.fraction(of: item, written: written)
        if item.isPaused { return .paused(fraction) }
        if case .closed(let wait) = gate { return .waiting(wait) }
        if item.files.contains(where: { $0.state == .downloading }) || fraction > 0 { return .downloading(fraction) }
        return .queued
    }

    /// Część pobrana: według bajtów, gdy serwer podał rozmiary, inaczej według plików.
    public static func fraction(of item: DownloadedItem, written: [String: Int64] = [:]) -> Double {
        let total = item.expectedBytes
        if total > 0 {
            let done = item.files.reduce(Int64(0)) { sum, file in
                sum + (file.state == .done ? (file.expectedSize ?? 0) : min(written[file.ino] ?? 0, file.expectedSize ?? 0))
            }
            return min(1, Double(done) / Double(total))
        }
        guard !item.files.isEmpty else { return 0 }
        return Double(item.files.count { $0.state == .done }) / Double(item.files.count)
    }

    /// Spójność po awarii albo po wyczyszczeniu plików przez system:
    /// - plik oznaczony jako pobrany, którego nie ma na dysku (albo ma zły rozmiar) → znowu w kolejce,
    /// - plik w trakcie pobierania bez zadania → w kolejce (zadania podłącza się osobno),
    /// - katalog na dysku bez wpisu i pliki w katalogu pozycji, których wpis nie zna → do usunięcia.
    ///
    /// - Parameter disk: katalog pozycji → nazwa pliku → rozmiar.
    public static func reconcile(_ items: [DownloadedItem], disk: [String: [String: Int64]], runningFiles: Set<String> = []) -> (items: [DownloadedItem], orphans: [String]) {
        var fixed: [DownloadedItem] = []
        var orphans: [String] = []
        let known = Set(items.map(\.folder))
        for folder in disk.keys.sorted() where !known.contains(folder) { orphans.append(folder) }
        for var item in items {
            let present = disk[item.folder] ?? [:]
            for index in item.files.indices {
                let file = item.files[index]
                switch file.state {
                case .done:
                    let size = present[file.fileName]
                    let sizeMatches = size != nil && (file.expectedSize.map { $0 == size } ?? true)
                    if !sizeMatches {
                        item.files[index].state = .queued
                        item.files[index].attempts = 0
                        item.completedAt = nil
                    }
                case .downloading where !runningFiles.contains(DownloadTaskID(itemKey: item.id, ino: file.ino).description):
                    item.files[index].state = .queued
                default:
                    break
                }
            }
            let expected = Set(item.files.map(\.fileName) + ["cover.jpg", DownloadedItem.textSyncFileName, DownloadedItem.skipFileName])
            for name in present.keys.sorted() where !expected.contains(name) && !DownloadedItem.isEbookFileName(name) { orphans.append(item.folder + "/" + name) }
            if item.hasCover, present["cover.jpg"] == nil { item.hasCover = false }
            fixed.append(item)
        }
        return (fixed, orphans)
    }

    /// Czy na dysku jest miejsce na `bytes` (z zapasem, żeby nie zapchać telefonu do zera).
    public static func hasRoom(for bytes: Int64, available: Int64, margin: Int64 = 200 * 1_048_576) -> Bool {
        available >= bytes + margin
    }

    /// Opóźnienie ponowienia po `attempts` nieudanych próbach (sieć): 5, 10, 20, 40, 60 s.
    public static func retryDelay(attempts: Int) -> Duration {
        .seconds(min(60, 5 * (1 << max(0, min(attempts - 1, 4)))))
    }

    /// Po tylu nieudanych próbach z rzędu plik czeka na zmianę sieci albo ręczne „Ponów”.
    public static let maxAutomaticAttempts = 5
}

/// Opis zadania `URLSession` (`taskDescription`): przeżywa ponowne uruchomienie aplikacji.
public struct DownloadTaskID: Hashable, Sendable, CustomStringConvertible {
    public let itemKey: String
    public let ino: String

    public init(itemKey: String, ino: String) {
        self.itemKey = itemKey
        self.ino = ino
    }

    public init?(_ text: String) {
        guard let split = text.lastIndex(of: "|") else { return nil }
        itemKey = String(text[..<split])
        ino = String(text[text.index(after: split)...])
        guard !itemKey.isEmpty, !ino.isEmpty else { return nil }
    }

    public var description: String { itemKey + "|" + ino }
}
