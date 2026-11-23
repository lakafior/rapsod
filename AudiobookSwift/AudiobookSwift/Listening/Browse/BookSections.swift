import AppKit
import AudiobookshelfKit
import AudiobookshelfPlayback
import SwiftUI

/// Zakładki książki: przejście do miejsca, zmiana nazwy, usunięcie.
struct BookmarksSection: View {
    let browser: LibraryBrowser
    let itemID: String
    @State private var renaming: AudiobookshelfClient.Bookmark?
    @State private var newTitle = ""

    var body: some View {
        let bookmarks = browser.listening.bookmarks[itemID] ?? []
        if !bookmarks.isEmpty {
            DisclosureGroup("Zakładki (\(bookmarks.count))") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(bookmarks) { bookmark in
                        HStack {
                            Button {
                                Task { await browser.listening.play(itemID: itemID, at: bookmark.time) }
                            } label: {
                                HStack {
                                    Image(systemName: "bookmark.fill").foregroundStyle(.tint)
                                    Text(bookmark.title).lineLimit(1)
                                    Spacer()
                                    Text(PlaybackFormat.clock(bookmark.time)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Menu {
                                Button("Zmień nazwę…") { newTitle = bookmark.title; renaming = bookmark }
                                Button("Usuń", role: .destructive) { Task { await browser.listening.deleteBookmark(bookmark) } }
                            } label: { Image(systemName: "ellipsis") }
                                .menuIndicator(.hidden).fixedSize().buttonStyle(.borderless)
                                .accessibilityLabel("Zakładka „\(bookmark.title)” — więcej")
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: 760)
            .alert("Nazwa zakładki", item: $renaming) { bookmark in
                TextField("Nazwa", text: $newTitle)
                Button("Zapisz") {
                    let title = newTitle
                    Task { await browser.listening.renameBookmark(bookmark, to: title) }
                }
                Button("Anuluj", role: .cancel) {}
            }
        }
    }
}

/// Rozdziały z przejściem: bieżąca książka przewija, inna zaczyna grać od rozdziału.
struct ChaptersSection: View {
    let browser: LibraryBrowser
    let item: AudiobookshelfClient.ItemDetail

    var body: some View {
        let chapters = item.media.chapters ?? []
        if !chapters.isEmpty {
            let titles = Dictionary(zip(chapters.map(\.id), PlaybackTimeline.displayTitles(chapters.map(\.title))), uniquingKeysWith: { first, _ in first })
            DisclosureGroup("Rozdziały (\(chapters.count))") {
                Table(chapters) {
                    TableColumn("#") { Text("\($0.id + 1)").monospacedDigit() }.width(36)
                    TableColumn("Tytuł") { chapter in
                        Button(titles[chapter.id] ?? chapter.title) { Task { await browser.listening.play(itemID: item.id, at: chapter.start) } }
                            .buttonStyle(.link)
                            .help("Odtwarzaj od tego rozdziału")
                    }
                    TableColumn("Początek") { Text(PlaybackFormat.clock($0.start)).monospacedDigit() }.width(80)
                    TableColumn("Czas") { Text(PlaybackFormat.clock($0.end - $0.start)).monospacedDigit() }.width(80)
                }
                .frame(height: min(CGFloat(chapters.count) * 24 + 32, 360))
                .accessibilityIdentifier("book.chapters")
            }
            .frame(maxWidth: 760)
        }
    }
}

struct TracksSection: View {
    let item: AudiobookshelfClient.ItemDetail

    var body: some View {
        let tracks = item.media.tracks?.elements ?? []
        if !tracks.isEmpty {
            DisclosureGroup("Ścieżki audio (\(tracks.count))") {
                Table(tracks) {
                    TableColumn("#") { Text("\($0.index)").monospacedDigit() }.width(36)
                    TableColumn("Plik") { Text($0.metadata?.filename ?? "—").lineLimit(1).help($0.metadata?.relPath ?? "") }
                    TableColumn("Kodek") { Text($0.codec ?? "—") }.width(60)
                    TableColumn("Bitrate") { Text($0.bitRate.map { "\(Int($0 / 1000)) kb/s" } ?? "—") }.width(70)
                    TableColumn("Rozmiar") { Text(Formats.size($0.metadata?.size)) }.width(80)
                    TableColumn("Czas") { Text(PlaybackFormat.clock($0.duration ?? 0)).monospacedDigit() }.width(80)
                }
                .frame(height: min(CGFloat(tracks.count) * 24 + 32, 300))
            }
            .frame(maxWidth: 760)
        }
    }
}

/// Pliki pozycji z menu „…” w wierszu (etap 9g): e-book podstawowy/dodatkowy, czytanie,
/// informacje o pliku audio z ffprobe, usunięcie pliku.
struct FilesSection: View {
    let browser: LibraryBrowser
    let item: AudiobookshelfClient.ItemDetail
    @Binding var request: LibraryFileRequest?

    var body: some View {
        let files = item.libraryFiles?.elements ?? []
        if !files.isEmpty {
            DisclosureGroup("Pliki (\(files.count))") {
                Table(files) {
                    TableColumn("Ścieżka") { file in
                        Button(file.metadata.relPath ?? file.metadata.filename ?? "—") {
                            if let path = file.metadata.path { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
                        }
                        .buttonStyle(.link)
                        .help("Pokaż w Finderze")
                    }
                    TableColumn("Rozmiar") { Text(Formats.size($0.metadata.size)) }.width(80)
                    TableColumn("Typ") { Text(typeName($0)) }.width(130)
                    TableColumn("") { file in
                        LibraryFileMenu(browser: browser, item: item, file: file, request: $request)
                    }
                    .width(28)
                }
                .frame(height: min(CGFloat(files.count) * 24 + 32, 300))
            }
            .frame(maxWidth: 760)
        }
    }

    private func typeName(_ file: AudiobookshelfClient.ItemDetail.LibraryFile) -> String {
        guard file.isEbook else { return Self.typeName(file.fileType) }
        return item.media.ebookFile?.ino == file.ino ? "e-book podstawowy" : "e-book dodatkowy"
    }

    static func typeName(_ type: String?) -> String {
        switch type {
        case "audio": "audio"
        case "image": "obraz"
        case "ebook": "e-book"
        case "text": "tekst"
        case "metadata": "metadane"
        default: "inny"
        }
    }
}
