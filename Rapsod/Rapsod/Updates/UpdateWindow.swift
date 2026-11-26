import RapsodUpdates
import SwiftUI

/// Okno „Aktualizacja Rapsod” (etap 14b): wynik sprawdzenia, opis zmian z wydania i decyzja.
struct UpdateWindow: View {
    static let windowID = "updates"

    let updates: UpdateController
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .padding(20)
        // Stały rozmiar: okno z `.contentSize` nie zawsze rośnie przy zmianie stanu
        // (np. z błędu z powrotem do opisu zmian), a wtedy opis byłby ucięty.
        .frame(width: 600, height: 470, alignment: .top)
        .onDisappear { updates.windowClosed() }
    }

    @ViewBuilder
    private var content: some View {
        switch updates.phase {
        case .idle:
            status(symbol: "arrow.triangle.2.circlepath", title: Text("Aktualizacje Rapsodu"), detail: Text("Uruchomiona wersja: \(updates.currentVersion.string)")) {
                Button("Sprawdź teraz") { updates.checkFromMenu() }
                    .keyboardShortcut(.defaultAction)
            }
        case .checking:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Sprawdzanie dostępności nowej wersji…")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .upToDate:
            status(symbol: "checkmark.circle", title: Text("Masz najnowszą wersję"), detail: Text("Rapsod \(updates.currentVersion.string) to najnowsze wydanie.")) {
                Button("OK") { dismissWindow(id: Self.windowID) }
                    .keyboardShortcut(.defaultAction)
            }
        case .failed(let message):
            status(symbol: "exclamationmark.triangle", title: Text("Aktualizacja się nie udała"), detail: Text(message)) {
                if let page = updates.pending?.pageURL {
                    Link("Strona wydania", destination: page)
                }
                Button("Spróbuj ponownie") { updates.checkFromMenu() }
                Button("Zamknij") { dismissWindow(id: Self.windowID) }
                    .keyboardShortcut(.defaultAction)
            }
        case .available(let update):
            available(update)
        case .downloading(let update, let fraction):
            progress(update, title: Text("Pobieranie Rapsod \(update.version.string)…"), fraction: fraction, cancellable: true)
        case .verifying(let update):
            progress(update, title: Text("Sprawdzanie podpisu, notaryzacji i sumy kontrolnej…"), fraction: nil, cancellable: false)
        case .installing(let update):
            progress(update, title: Text("Zamykanie Rapsodu i instalacja wersji \(update.version.string)…"), fraction: nil, cancellable: false)
        }
    }

    private func available(_ update: AppUpdate) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dostępna jest nowa wersja Rapsodu")
                        .font(.headline)
                    Text("Rapsod \(update.version.string) — masz \(updates.currentVersion.string). Instalacja zamknie aplikację razem z serwerem i uruchomi ją ponownie.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let page = update.pageURL {
                        Link("Strona wydania", destination: page)
                    }
                }
            }
            ScrollView {
                ReleaseNotesView(title: update.title, markdown: update.notes)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(height: 260)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Pomiń tę wersję") {
                    updates.skip(update)
                    dismissWindow(id: Self.windowID)
                }
                Spacer()
                Button("Przypomnij później") {
                    updates.remindLater()
                    dismissWindow(id: Self.windowID)
                }
                Button("Zainstaluj i uruchom ponownie") { updates.install(update) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func progress(_ update: AppUpdate, title: Text, fraction: Double?, cancellable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            title
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text("Obraz dysku: \(update.diskImage.size.formatted(.byteCount(style: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if cancellable {
                    Button("Anuluj") { updates.cancelDownload() }
                }
            }
        }
    }

    private func status(symbol: String, title: Text, detail: Text, @ViewBuilder buttons: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    title.font(.headline)
                    detail
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                buttons()
            }
        }
    }
}

/// Opis zmian z wydania w Markdown: nagłówki, listy i akapity blokami, formatowanie w wierszu
/// (pogrubienie, kursywa, kod, odnośniki) przez `AttributedString`.
struct ReleaseNotesView: View {
    let title: String
    let markdown: String

    private enum Block: Hashable {
        case heading(String, level: Int)
        case bullet(String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                let level = line.prefix(while: { $0 == "#" }).count
                result.append(.heading(line.dropFirst(level).trimmingCharacters(in: .whitespaces), level: level))
            } else if let marker = ["- ", "* ", "+ "].first(where: { line.hasPrefix($0) }) {
                flush()
                result.append(.bullet(String(line.dropFirst(marker.count))))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title).font(.title3.weight(.semibold))
            if markdown.isEmpty {
                Text("Wydanie nie ma opisu zmian.").foregroundStyle(.secondary)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text, let level):
                    Text(inline(text)).font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                        .padding(.top, 4)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•")
                        Text(inline(text))
                    }
                case .paragraph(let text):
                    Text(inline(text))
                }
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// Jedna pozycja w menu (aplikacji i na pasku menu): „Sprawdź aktualizacje…” albo, gdy czeka
/// nowa wersja, jej oznaczenie.
struct UpdateMenuItem: View {
    let updates: UpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            if updates.pending == nil { updates.checkFromMenu() } else if let pending = updates.pending, !updates.isBusy {
                updates.showAvailable(pending)
            }
            openWindow.bringToFront(id: UpdateWindow.windowID)
        } label: {
            if let pending = updates.pending {
                Text("Zainstaluj Rapsod \(pending.version.string)…")
            } else {
                Text("Sprawdź aktualizacje…")
            }
        }
    }
}
