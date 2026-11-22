// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Pliki pozycji (etap 9g): e-book podstawowy/dodatkowy, usunięcie pojedynczego pliku
/// i dane ffprobe pliku audio. Jak reszta `Manage/` — tokenem root przez `ItemManager`.
/// Kształty z upstreamu v2.38.0: `LibraryItemController.updateEbookFileStatus`,
/// `deleteLibraryFile` i `getFFprobeData` (`AudioFileScanner.probeAudioFile` → surowy ffprobe).
extension AudiobookshelfClient {
    /// Przełącza e-book między podstawowym a dodatkowym (`PATCH /api/items/:id/ebook/:fileid/status`).
    /// Dodatkowy staje się podstawowym (poprzedni podstawowy — dodatkowym), podstawowy — dodatkowym.
    public func toggleEbookStatus(itemID: String, ino: String, token: String) async throws {
        _ = try await send("PATCH", "api/items/\(itemID)/ebook/\(ino)/status", token: token)
    }

    /// Usuwa plik z pozycji (`DELETE /api/items/:id/file/:fileid`). Serwer kasuje go trwale,
    /// więc aplikacja przenosi go wcześniej do Kosza (`ItemManager.deleteFile`).
    public func deleteLibraryFile(itemID: String, ino: String, token: String) async throws {
        _ = try await send("DELETE", "api/items/\(itemID)/file/\(ino)", token: token)
    }

    /// Surowy wynik ffprobe pliku audio (`GET /api/items/:id/ffprobe/:fileid`, tylko administrator).
    public func ffprobe(itemID: String, ino: String, token: String) async throws -> Data {
        try await send("GET", "api/items/\(itemID)/ffprobe/\(ino)", token: token, timeout: 60)
    }
}
