import AudiobookshelfKit
import Foundation

/// Rozpoznanie książek w upuszczonym folderze (etap 9h; wzorzec `client/mixins/uploadHelpers.js`).
/// Bez zależności od widoków, żeby dało się je sprawdzić osobno. Zostaje w aplikacji (GPL-3.0), poza
/// pakietem MPL-2.0: algorytm jest przetłumaczony z klienta web audiobookshelf.
///
/// Folder z plikami książki (audio albo e-book) to jedna książka; folder z samymi podfolderami —
/// przechodzimy w głąb. Z drogi od upuszczonego folderu: ostatni człon to tytuł, przedostatni
/// seria (gdy są co najmniej trzy człony), wcześniejszy autor — `Autor/Seria/Tytuł` albo
/// `Autor/Tytuł`. Odstępstwo od web UI: podfoldery płyt (`CD1`, `Disc 2`) zostają częścią
/// książki, tak jak przy skanie serwera (`server/utils/scandir.js`) — web UI zrobiłby z nich
/// osobne pozycje.
enum UploadGrouping {
    struct Book: Equatable {
        let files: [URL]
        let title: String
        let author: String
        let series: String
    }

    static let ebookExtensions: Set<String> = ["epub", "pdf", "mobi", "azw3", "cbr", "cbz"]

    static func isDiscFolder(_ name: String) -> Bool {
        name.range(of: #"^(cd|dis[ck])\s*\d{1,3}$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func books(in directory: URL, path: [String], supported: Set<String>, audio: Set<String>, ignored: inout [String]) -> [Book] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let isFolder = { (url: URL) in (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let folders = children.filter(isFolder)
        let files = children.filter { !isFolder($0) }
        let isItemFile = { (url: URL) -> Bool in
            let ext = url.pathExtension.lowercased()
            return audio.contains(ext) || ebookExtensions.contains(ext)
        }
        let isBook = files.contains(where: isItemFile) || (!folders.isEmpty && folders.allSatisfy { isDiscFolder($0.lastPathComponent) })
        if isBook {
            let collected = collect(in: directory, supported: supported, ignored: &ignored)
            guard !collected.isEmpty else { return [] }
            var dirs = path
            let title = dirs.removeLast()
            let series = dirs.count > 1 ? dirs.removeLast() : ""
            let author = dirs.last ?? ""
            return [Book(files: collected, title: title, author: author, series: series)]
        }
        // Luźne pliki obok podfolderów książek (np. okładka serii) web UI też pomija.
        ignored += files.map(\.lastPathComponent)
        return folders
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .flatMap { books(in: $0, path: path + [$0.lastPathComponent], supported: supported, audio: audio, ignored: &ignored) }
    }

    /// Nazwy plików do wysłania — w pakiecie (`AudiobookshelfClient.uploadNames`), bo używa ich `upload`.
    static func uploadNames(for files: [URL]) -> [String] { AudiobookshelfClient.uploadNames(for: files) }

    /// Pliki folderu razem z podfolderami (serwer i tak kładzie je płasko w folderze książki).
    static func collect(in directory: URL, supported: Set<String>, ignored: inout [String]) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if supported.contains(url.pathExtension.lowercased()) { files.append(url) } else { ignored.append(url.lastPathComponent) }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
