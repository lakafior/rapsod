import AppKit
import AudiobookshelfKit
import AudiobookshelfPlayback
import SwiftUI

extension ItemManager {
    /// Usuwa jeden plik pozycji: najpierw do Kosza (odwracalne, decyzja z etapu 9e), potem
    /// z pozycji na serwerze. Gdy serwer odmówi, plik wraca z Kosza na miejsce.
    func deleteFile(itemID: String, ino: String, path: String?) async throws {
        var trashed: (original: URL, inTrash: URL)?
        if let path, FileManager.default.fileExists(atPath: path) {
            let original = URL(filePath: path)
            var result: NSURL?
            do {
                try FileManager.default.trashItem(at: original, resultingItemURL: &result)
            } catch {
                throw TrashUnavailable(reason: error.localizedDescription)
            }
            if let inTrash = result as URL? { trashed = (original, inTrash) }
        }
        do {
            try await run { try await $0.deleteLibraryFile(itemID: itemID, ino: ino, token: $1) }
        } catch AudiobookshelfClient.APIError.http(404, _) where trashed != nil {
            // Obserwator plików zdążył zauważyć zniknięcie pliku i przeskanował pozycję.
        } catch {
            if let trashed { try? FileManager.default.moveItem(at: trashed.inTrash, to: trashed.original) }
            throw error
        }
    }

    /// Usuwa plik trwale (tylko gdy Kosz jest niedostępny — po osobnym pytaniu).
    func deleteFilePermanently(itemID: String, ino: String) async throws {
        try await run { try await $0.deleteLibraryFile(itemID: itemID, ino: ino, token: $1) }
    }
}

/// Menu „…” wiersza pliku na stronie książki: czytanie e-booka, podstawowy/dodatkowy,
/// dane pliku audio, Finder i usunięcie.
struct LibraryFileMenu: View {
    let browser: LibraryBrowser
    let item: AudiobookshelfClient.ItemDetail
    let file: AudiobookshelfClient.ItemDetail.LibraryFile
    @Binding var request: LibraryFileRequest?
    @Environment(\.openWindow) private var openWindow

    private var manager: ItemManager { browser.manager }
    private var isPrimaryEbook: Bool { file.isEbook && item.media.ebookFile?.ino == file.ino }
    private var audioFile: AudiobookshelfClient.AudioFileEntry? { item.media.audioFiles?.elements.first { $0.ino == file.ino } }

    var body: some View {
        Menu {
            if file.isEbook {
                Button(isPrimaryEbook ? "Czytaj" : "Czytaj (bez zapisu postępu)") {
                    openWindow(id: ReaderWindow.windowID, value: ReaderTarget(itemID: item.id, fileIno: isPrimaryEbook ? nil : file.ino, title: item.title))
                }
                if manager.isAvailable, !item.isPodcast {
                    Button(isPrimaryEbook ? "Ustaw jako e-book dodatkowy" : "Ustaw jako e-book podstawowy") { request = .toggleEbook(file) }
                }
                Divider()
            }
            if let audioFile {
                Button("Informacje o pliku audio…") { request = .audioInfo(audioFile) }
                Divider()
            }
            if let path = file.metadata.path {
                Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
            }
            if manager.isAvailable {
                Divider()
                Button("Usuń plik…", role: .destructive) { request = .delete(file) }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .buttonStyle(.borderless)
        .accessibilityLabel("Plik „\(file.metadata.filename ?? "")” — więcej")
    }
}

enum LibraryFileRequest: Identifiable {
    case toggleEbook(AudiobookshelfClient.ItemDetail.LibraryFile)
    case delete(AudiobookshelfClient.ItemDetail.LibraryFile)
    case audioInfo(AudiobookshelfClient.AudioFileEntry)

    var id: String {
        switch self {
        case .toggleEbook(let file): "ebook-\(file.ino)"
        case .delete(let file): "delete-\(file.ino)"
        case .audioInfo(let file): "audio-\(file.ino)"
        }
    }
}

/// Potwierdzenia i arkusze dla `LibraryFileMenu` (jeden zestaw na stronę książki).
struct LibraryFileActions: ViewModifier {
    let browser: LibraryBrowser
    let item: AudiobookshelfClient.ItemDetail
    @Binding var request: LibraryFileRequest?
    @State private var permanent: AudiobookshelfClient.ItemDetail.LibraryFile?
    @State private var failure: String?
    @State private var busy = false

    private var manager: ItemManager { browser.manager }

    private var deleting: AudiobookshelfClient.ItemDetail.LibraryFile? {
        if case .delete(let file) = request { return file }
        return nil
    }

    private var audioInfo: AudiobookshelfClient.AudioFileEntry? {
        if case .audioInfo(let file) = request { return file }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: request?.id) {
                if case .toggleEbook(let file) = request {
                    request = nil
                    toggle(file)
                }
            }
            .confirmationDialog("Usunąć plik „\(deleting?.metadata.filename ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0, deleting != nil { request = nil } }), presenting: deleting) { file in
                Button("Przenieś do Kosza", role: .destructive) { delete(file) }
                Button("Anuluj", role: .cancel) {}
            } message: { file in
                Text(deleteMessage(file))
            }
            .alert("Kosz jest niedostępny", item: $permanent) { file in
                Button("Usuń trwale", role: .destructive) { deletePermanently(file) }
                Button("Anuluj", role: .cancel) {}
            } message: { _ in
                Text("Pliku nie da się przenieść do Kosza. Usunąć go trwale? Tego nie można cofnąć.")
            }
            .alert("Nie udało się", item: $failure) { _ in
                Button("OK") {}
            } message: { Text($0) }
            .sheet(item: Binding(get: { audioInfo.map(AudioInfoRequest.init) }, set: { if $0 == nil { request = nil } })) { info in
                AudioFileSheet(manager: manager, itemID: item.id, file: info.file)
            }
    }

    private struct AudioInfoRequest: Identifiable {
        let file: AudiobookshelfClient.AudioFileEntry
        var id: String { file.ino }
    }

    private func deleteMessage(_ file: AudiobookshelfClient.ItemDetail.LibraryFile) -> String {
        var lines = ["Plik trafi do Kosza macOS, a serwer usunie go z pozycji."]
        if file.isEbook, item.media.ebookFile?.ino == file.ino {
            lines.append("To podstawowy e-book — postęp czytania zostanie na serwerze, ale pozycja nie będzie miała e-booka.")
        }
        if file.fileType == "audio" {
            lines.append("Plik audio zniknie też ze ścieżek i z czasu trwania książki.")
        }
        return lines.joined(separator: "\n\n")
    }

    private func toggle(_ file: AudiobookshelfClient.ItemDetail.LibraryFile) {
        Task {
            do {
                try await manager.run { try await $0.toggleEbookStatus(itemID: item.id, ino: file.ino, token: $1) }
            } catch {
                failure = ItemManager.message(for: error, action: "Zmiana e-booka podstawowego")
            }
        }
    }

    private func delete(_ file: AudiobookshelfClient.ItemDetail.LibraryFile) {
        request = nil
        Task {
            // Plik audio odtwarzanej książki: odtwarzacz trzyma go otwartego — zatrzymujemy.
            if file.fileType == "audio" { await browser.listening.release(itemID: item.id) }
            do {
                try await manager.deleteFile(itemID: item.id, ino: file.ino, path: file.metadata.path)
            } catch is ItemManager.TrashUnavailable {
                permanent = file
            } catch {
                failure = ItemManager.message(for: error, action: "Usuwanie pliku")
            }
        }
    }

    private func deletePermanently(_ file: AudiobookshelfClient.ItemDetail.LibraryFile) {
        Task {
            do {
                try await manager.deleteFilePermanently(itemID: item.id, ino: file.ino)
            } catch {
                failure = ItemManager.message(for: error, action: "Usuwanie pliku")
            }
        }
    }
}

/// Dane pliku audio jak w `AudioFileDataModal.vue` web UI i — na żądanie — surowy wynik ffprobe.
struct AudioFileSheet: View {
    let manager: ItemManager
    let itemID: String
    let file: AudiobookshelfClient.AudioFileEntry
    @State private var probe: String?
    @State private var probing = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(file.metadata?.filename ?? "Plik audio").font(.headline).lineLimit(1).truncationMode(.middle)
            if let probe {
                ScrollView([.vertical, .horizontal]) {
                    Text(probe).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 320)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            } else {
                details
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            HStack {
                if let probe {
                    Button("Kopiuj") { NSPasteboard.copy(probe) }
                    Button("Wróć do szczegółów") { self.probe = nil }
                } else {
                    Button {
                        runProbe()
                    } label: {
                        if probing {
                            Label { Text("Badanie pliku…") } icon: { ProgressView().controlSize(.small) }
                        } else {
                            Text("Zbadaj plik (ffprobe)")
                        }
                    }
                    .disabled(probing)
                }
                Spacer()
                Button("Zamknij") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        // Stopka ma też „Kopiuj”/„Zbadaj plik”, więc zostaje; Return zostaje przy „Zamknij”,
        // a Esc obsługuje niewidoczny przycisk anulowania.
        .background {
            Button("Zamknij") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
            row("Ścieżka", file.metadata?.path)
            row("Rozmiar", Formats.size(file.metadata?.size))
            row("Czas trwania", file.duration.map { PlaybackFormat.clock($0) })
            row("Format", file.format)
            row("Kodek", file.codec)
            row("Kanały", file.channels.map { channels in file.channelLayout.map { "\(channels) (\($0))" } ?? "\(channels)" })
            row("Bitrate", file.bitRate.map { "\(Int($0 / 1000)) kb/s" })
            row("Podstawa czasu", file.timeBase)
            row("Język", file.language)
            row("Rozdziały", file.chapters.map { String($0.elements.count) })
            row("Okładka w pliku", file.embeddedCoverArt)
        }
        .font(.callout)
    }

    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text(value).textSelection(.enabled).lineLimit(3)
            }
        }
    }

    private func runProbe() {
        probing = true
        error = nil
        Task {
            defer { probing = false }
            do {
                let data = try await manager.run { try await $0.ffprobe(itemID: itemID, ino: file.ino, token: $1) }
                if let object = try? JSONSerialization.jsonObject(with: data),
                   let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                    probe = String(decoding: pretty, as: UTF8.self)
                } else {
                    probe = String(decoding: data, as: UTF8.self)
                }
            } catch {
                self.error = ItemManager.message(for: error, action: "ffprobe")
            }
        }
    }
}
