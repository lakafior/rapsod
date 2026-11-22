import Foundation

/// Punkty API narzędzi pozycji (etap 9e): usunięcie, ponowny skan, kolejność plików,
/// osadzenie metadanych, scalenie do M4B i wgrywanie. Jak reszta `Manage/` — tylko przez
/// `ItemManager`, tokenem konta root.
///
/// Kształty z upstreamu v2.38.0: `LibraryItemController.js` (`delete`, `scan`, `updateTracks`),
/// `ToolsController.js` (`encodeM4b`, `cancelM4bEncode`, `embedAudioFileMetadata`),
/// `MiscController.js` (`handleUpload`, `getTasks`), `FileSystemController.js` (`checkPathExists`),
/// `managers/AbMergeManager.js` i `AudioMetadataManager.js` (zadania i zdarzenia postępu).
extension AudiobookshelfClient {
    // MARK: Modele

    /// Plik audio książki (`media.audioFiles`, także wykluczone — w przeciwieństwie do `tracks`).
    public struct AudioFileEntry: Decodable, Sendable, Identifiable, Hashable {
        public let ino: String
        public let index: Int?
        public let exclude: Bool?
        public let duration: Double?
        public let codec: String?
        public let bitRate: Double?
        public let channels: Int?
        public let trackNumFromMeta: Int?
        public let trackNumFromFilename: Int?
        public let discNumFromMeta: Int?
        public let discNumFromFilename: Int?
        public let metadata: ItemDetail.Media.FileMetadata?
        // Szczegóły pliku (etap 9g, okno „Informacje o pliku audio”).
        public let format: String?
        public let channelLayout: String?
        public let timeBase: String?
        public let language: String?
        public let embeddedCoverArt: String?
        public let chapters: LenientList<ItemDetail.Media.Chapter>?
        public var id: String { ino }
    }

    /// Wynik `POST /api/items/:id/scan` (`ScanResult` z `utils/constants.js`).
    public enum ItemScanResult: String, Sendable {
        case nothing = "NOTHING"
        case added = "ADDED"
        case updated = "UPDATED"
        case removed = "REMOVED"
        case upToDate = "UPTODATE"
    }

    /// Opcje kodowania M4B (`?codec=&bitrate=&channels=` jak w `manage.vue`).
    public struct EncodeOptions: Sendable, Hashable {
        public var codec = "aac"
        public var bitrate = "128k"
        public var channels = 2

        public init(codec: String = "", bitrate: String = "", channels: Int = 2) {
            self.codec = codec
            self.bitrate = bitrate
            self.channels = channels
        }
    }

    /// `GET /api/tasks?include=queue`: zadania w toku i czekające osadzenia metadanych.
    public struct TaskList: Decodable, Sendable {
        public struct Queue: Decodable, Sendable {
            public struct Entry: Decodable, Sendable { public let libraryItemId: String? }
            public let embedMetadata: LenientList<Entry>?
        }
        public let tasks: LenientList<ServerTask>
        public let queuedTaskData: Queue?

        public var queuedEmbeds: Set<String> {
            Set(queuedTaskData?.embedMetadata?.elements.compactMap(\.libraryItemId) ?? [])
        }
    }

    // MARK: Usunięcie i skan

    /// `hard` kasuje folder pozycji trwale (`fs.remove`). Aplikacja zamiast tego przenosi
    /// go do Kosza sama (decyzja użytkownika), a trwałe usunięcie zostaje jako wyjście, gdy Kosza nie ma.
    public func deleteItem(id: String, hard: Bool, token: String) async throws {
        let query = hard ? [URLQueryItem(name: "hard", value: "1")] : []
        _ = try await send("DELETE", "api/items/\(id)", query: query, token: token, timeout: 120)
    }

    public func scanItem(id: String, token: String) async throws -> ItemScanResult? {
        struct Response: Decodable { let result: String? }
        let data = try await send("POST", "api/items/\(id)/scan", token: token, timeout: 300)
        return try decode(Response.self, from: data).result.flatMap(ItemScanResult.init(rawValue:))
    }

    // MARK: Pliki audio

    /// Zastępuje listę plików audio: **zawsze wszystkie** pliki pozycji, w nowej kolejności
    /// (serwer zapisuje tylko to, co dostał — pominięty plik zniknąłby z książki).
    public func updateTracks(itemID: String, _ files: [(ino: String, exclude: Bool)], token: String) async throws {
        struct Entry: Encodable { let ino: String; let exclude: Bool }
        struct Body: Encodable { let orderedFileData: [Entry] }
        let body = Body(orderedFileData: files.map { Entry(ino: $0.ino, exclude: $0.exclude) })
        _ = try await send("PATCH", "api/items/\(itemID)/tracks", body: body, token: token)
    }

    // MARK: Narzędzia (ffmpeg na serwerze)

    public func embedMetadata(itemID: String, backup: Bool, token: String) async throws {
        let query = [URLQueryItem(name: "backup", value: backup ? "1" : "0")]
        _ = try await send("POST", "api/tools/item/\(itemID)/embed-metadata", query: query, token: token)
    }

    public func encodeM4b(itemID: String, options: EncodeOptions, token: String) async throws {
        let query = [
            URLQueryItem(name: "codec", value: options.codec),
            URLQueryItem(name: "bitrate", value: options.bitrate),
            URLQueryItem(name: "channels", value: String(options.channels)),
        ]
        _ = try await send("POST", "api/tools/item/\(itemID)/encode-m4b", query: query, token: token)
    }

    public func cancelM4b(itemID: String, token: String) async throws {
        _ = try await send("DELETE", "api/tools/item/\(itemID)/encode-m4b", token: token)
    }

    public func itemTasks(token: String) async throws -> TaskList {
        let query = [URLQueryItem(name: "include", value: "queue")]
        return try decode(TaskList.self, from: await send("GET", "api/tasks", query: query, token: token))
    }

    // MARK: Wgrywanie

    /// Czy `directory` (względem folderu biblioteki) już istnieje — serwer odmawia wgrania
    /// w zajęte miejsce. `itemTitle` — pozycja biblioteki, w której podfolderze to leży
    /// (albo która właśnie tam powstała po skanie).
    public func pathExists(directory: String, folderPath: String, token: String) async throws -> (exists: Bool, itemTitle: String?) {
        struct Body: Encodable { let directory: String; let folderPath: String }
        struct Response: Decodable { let exists: Bool; let libraryItemTitle: String? }
        let data = try await send("POST", "api/filesystem/pathexists", body: Body(directory: directory, folderPath: folderPath), token: token)
        let response = try decode(Response.self, from: data)
        return (response.exists, response.libraryItemTitle)
    }

    /// `POST /api/upload` (`multipart/form-data` jak `pages/upload/index.vue`): pola `title`,
    /// `author`, `series`, `library`, `folder` i pliki pod kluczami `0`, `1`, …
    /// Treść jest składana w pliku tymczasowym i wysyłana strumieniowo — książka może mieć gigabajty.
    public func upload(
        files: [URL],
        title: String,
        author: String?,
        series: String?,
        libraryID: String,
        folderID: String,
        token: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let boundary = "AudiobookSwift-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appending(path: "item-upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: body.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: body) }

        func field(_ name: String, _ value: String) -> Data {
            Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        let output = try FileHandle(forWritingTo: body)
        do {
            try output.write(contentsOf: field("title", title))
            if let author { try output.write(contentsOf: field("author", author)) }
            if let series { try output.write(contentsOf: field("series", series)) }
            try output.write(contentsOf: field("library", libraryID))
            try output.write(contentsOf: field("folder", folderID))
            let names = UploadGrouping.uploadNames(for: files)
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                // Nazwa pliku w nagłówku: cudzysłów i znaki nowej linii rozbiłyby nagłówek.
                let name = names[index].replacingOccurrences(of: "\"", with: "'")
                    .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
                try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(index)\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
                let input = try FileHandle(forReadingFrom: file)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
                try output.write(contentsOf: Data("\r\n".utf8))
            }
            try output.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
            try output.close()
        } catch {
            try? output.close()
            throw error
        }

        var request = URLRequest(url: baseURL.appending(path: "api/upload"))
        request.httpMethod = "POST"
        // Limit bezczynności, nie całości: serwer przenosi pliki dopiero po odebraniu wszystkiego.
        request.timeoutInterval = 900
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, fromFile: body, delegate: UploadProgress(report: progress))
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw APIError.unauthorized
        default:
            let message = String(decoding: data.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw APIError.http(status: http.statusCode, message: message)
        }
    }
}

/// Postęp wysyłania treści zapytania (`didSendBodyData`).
private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    public let report: @Sendable (Double) -> Void

    public init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

// Rozdziały pliku audio w `AudioFileEntry` (etap 9g) — lista łagodna, a wpis musi być `Hashable`.
extension AudiobookshelfClient.LenientList: Equatable where Element: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.elements == rhs.elements }
}

extension AudiobookshelfClient.LenientList: Hashable where Element: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(elements) }
}
