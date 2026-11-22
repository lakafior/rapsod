// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AudiobookshelfKit

typealias Client = AudiobookshelfClient

/// Cel nawigacji w każdej zakładce. Serie i autorzy to encje połączone z kilku bibliotek.
enum Route: Hashable {
    case item(String)
    case series(MergedEntity<Client.Series>)
    case author(MergedEntity<Client.Author>)
    /// Seria albo autor ze strony pozycji (znani z jednej biblioteki) — pozostałe biblioteki
    /// dopytuje strona docelowa.
    case seriesSeed(libraryID: String, id: String, name: String)
    case authorSeed(libraryID: String, id: String, name: String)
    case narrator(String)
}

extension View {
    /// Strony pozycji, serii, autora i lektora — te same w każdej zakładce.
    func browseDestinations(model: AppModel, session: ServerSession) -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .item(let id):
                ItemDetailView(itemID: id, model: model, session: session)
            case .series(let series):
                SeriesPage(series: series, seed: nil, model: model, session: session)
            case .seriesSeed(let libraryID, let id, let name):
                SeriesPage(series: nil, seed: Tagged(libraryID: libraryID, value: Client.Series(id: id, name: name, description: nil, books: nil)), model: model, session: session)
            case .author(let author):
                AuthorPage(author: author, seed: nil, model: model, session: session)
            case .authorSeed(let libraryID, let id, let name):
                AuthorPage(author: nil, seed: Tagged(libraryID: libraryID, value: Client.Author(id: id, name: name, description: nil, imagePath: nil, numBooks: nil, updatedAt: nil)), model: model, session: session)
            case .narrator(let name):
                NarratorPage(name: name, model: model, session: session)
            }
        }
    }
}

/// Okładka pozycji z pamięci okładek; pobieranie anulowane, gdy karta zniknie z ekranu.
struct ItemCover: View {
    let itemID: String
    let session: ServerSession
    /// Rozmiar w punktach, do którego serwer zmniejsza okładkę (kubełki: mniej wariantów w pamięci).
    var points: CGFloat = 180
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "book.closed")
                        .font(.title)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .task(id: itemID) {
                image = await session.cover(itemID: itemID, path: nil, size: points, scale: displayScale)
            }
            .accessibilityHidden(true)
    }
}

/// Karta książki w siatce i na półkach: okładka, tytuł, autor, pasek postępu.
struct BookCard: View {
    let item: Client.LibraryItem
    let session: ServerSession
    /// Nazwa biblioteki — tylko gdy bibliotek książek jest więcej niż jedna.
    let libraryName: String?
    @State private var downloadError: String?

    var body: some View {
        let download = session.downloads.manager.entry(itemID: item.id, episodeID: nil)
        NavigationLink(value: Route.item(item.id)) {
            VStack(alignment: .leading, spacing: 4) {
                ItemCover(itemID: item.id, session: session)
                    .overlay(alignment: .bottom) {
                        CardProgress(entry: session.library.progress.entry(item.id))
                    }
                    .overlay(alignment: .topTrailing) {
                        DownloadEntryBadge(entry: download)
                            .padding(4)
                            .background(.regularMaterial, in: .circle)
                            .padding(4)
                            .opacity(download.status == .notDownloaded ? 0 : 1)
                    }
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let author = item.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let libraryName {
                    LibraryBadge(name: libraryName)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(.rect)
            // Jedna etykieta na całej zawartości — odnośnik jest wtedy jednym przyciskiem dla VoiceOver.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(BookAccessibility.label(item: item, libraryName: libraryName))
            .accessibilityValue(Text("\(ProgressText(entry: session.library.progress.entry(item.id)))\(download.status == .notDownloaded ? "" : ", " + download.status.text)"))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !item.isPodcast {
                DownloadMenuItems(target: .book(itemID: item.id), session: session) { downloadError = $0 }
            }
        }
        .alert("Nie udało się pobrać", isPresented: Binding(get: { downloadError != nil }, set: { if !$0 { downloadError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
    }
}

enum BookAccessibility {
    static func label(item: Client.LibraryItem, libraryName: String?) -> Text {
        var parts = [item.title]
        if let author = item.author, !author.isEmpty { parts.append(author) }
        if let libraryName { parts.append("biblioteka \(libraryName)") }
        return Text(parts.joined(separator: ", "))
    }
}

/// Postęp słownie dla VoiceOver — czyta tylko postęp tej jednej pozycji.
@MainActor private func ProgressText(entry: ProgressStore.Entry) -> Text {
    guard let value = entry.value else { return Text("nierozpoczęte") }
    if value.isFinished { return Text("ukończone") }
    let percent = Int(((value.progress ?? 0) * 100).rounded())
    return percent > 0 ? Text("przesłuchane \(percent) procent") : Text("nierozpoczęte")
}

/// Pasek postępu na okładce. Osobny widok: obserwuje tylko swój `Entry`.
struct CardProgress: View {
    let entry: ProgressStore.Entry

    var body: some View {
        if let value = entry.value, value.isFinished {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .font(.title3)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else if let fraction = entry.fraction {
            GeometryReader { proxy in
                Capsule()
                    .fill(.tint)
                    .frame(width: max(4, proxy.size.width * fraction), height: 4)
            }
            .frame(height: 4)
            .background(.black.opacity(0.35), in: .capsule)
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
    }
}

/// Dyskretna nazwa biblioteki przy pozycji.
struct LibraryBadge: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
    }
}

/// Biblioteki, które nie odpowiedziały — pozostałe działają.
struct FailureNotice: View {
    let failures: [LibraryFailure]

    var body: some View {
        if !failures.isEmpty {
            Label {
                Text(failures.count == 1
                     ? "Biblioteka „\(failures[0].libraryName)” nie odpowiada — pokazane są pozostałe."
                     : "Nie odpowiadają: \(failures.map(\.libraryName).joined(separator: ", ")) — pokazane są pozostałe.")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Kolumny siatki okładek: tyle, ile się zmieści (iPhone w pionie — 3, iPad — więcej).
/// Większy tekst (Dynamic Type) — szersze karty, czyli mniej kolumn.
/// `minimum` z `@ScaledMetric` widoku (domyślnie 104 pt).
/// Przy największych rozmiarach tekstu karta nie rośnie ponad 150 pt — na iPhonie zostają
/// dwie kolumny zamiast jednej ogromnej okładki (tekst i tak się zawija).
func coverColumns(minimum: CGFloat) -> [GridItem] {
    let width = min(minimum, 150)
    return [GridItem(.adaptive(minimum: width, maximum: width * 1.8), spacing: 14, alignment: .top)]
}

/// Stan pusty / błąd z przyciskiem ponowienia.
struct LoadFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Nie udało się wczytać", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Spróbuj ponownie", action: retry)
        }
    }
}

/// Liczebniki po polsku: 1 książka, 2–4 książki, 5–21 książek, 22–24 książki…
enum PolishCount {
    static func form(_ n: Int, one: String, few: String, many: String) -> String {
        if n == 1 { return "1 \(one)" }
        let tens = n % 100, units = n % 10
        let word = (2...4).contains(units) && !(12...14).contains(tens) ? few : many
        return "\(n) \(word)"
    }

    static func books(_ n: Int) -> String { form(n, one: "książka", few: "książki", many: "książek") }
    static func series(_ n: Int) -> String { form(n, one: "seria", few: "serie", many: "serii") }
    static func episodes(_ n: Int) -> String { form(n, one: "odcinek", few: "odcinki", many: "odcinków") }
    static func positions(_ n: Int) -> String { form(n, one: "pozycja", few: "pozycje", many: "pozycji") }
}
