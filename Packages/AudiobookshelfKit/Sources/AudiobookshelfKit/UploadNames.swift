// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

extension AudiobookshelfClient {
    /// Nazwy plików do wysłania. Serwer kładzie każdy plik płasko w folderze książki pod jego samą
    /// nazwą (`MiscController.handleUpload`: `sanitizeFilename(file.name)`), więc `CD1/01.mp3`
    /// i `Disc 2/01.mp3` nadpisałyby się nawzajem. Gdy nazwy się powtarzają, każdy plik z podfolderu
    /// dostaje prefiks folderu (`CD1 - 01.mp3`) — wszystkie, żeby kolejność płyt została. Bez powtórek
    /// nazwy zostają (np. `Extras/cover.jpg` to dalej `cover.jpg`). Co się wciąż powtarza, dostaje numer.
    public static func uploadNames(for files: [URL]) -> [String] {
        let plain = files.map(\.lastPathComponent)
        guard Set(plain.map { $0.lowercased() }).count < plain.count else { return plain }
        let parents = files.map { $0.deletingLastPathComponent().standardizedFileURL.path }
        // Wspólny folder nadrzędny (książka z samymi podfolderami płyt nie ma plików na wierzchu).
        let split = parents.map { $0.split(separator: "/", omittingEmptySubsequences: false) }
        var common = split.first ?? []
        for components in split.dropFirst() {
            common = Array(zip(common, components).prefix { $0 == $1 }.map(\.0))
        }
        let base = common.joined(separator: "/")
        var used: Set<String> = []
        return zip(files, parents).map { file, parent in
            var name = file.lastPathComponent
            if parent != base, parent.hasPrefix(base + "/") {
                let relative = parent.dropFirst(base.count + 1).replacingOccurrences(of: "/", with: " - ")
                name = "\(relative) - \(name)"
            }
            var candidate = name
            var counter = 2
            while used.contains(candidate.lowercased()) {
                let ext = (name as NSString).pathExtension
                let stem = (name as NSString).deletingPathExtension
                candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
                counter += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }
}
