// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AudiobookshelfKit
import AudiobookshelfPlayback

// Wspólne klocki wyglądu (etap 10i): nagłówek sekcji, pozioma półka, okładka, tło z okładki,
// stany puste i szkielet ładowania. Kolor akcentu: `AccentColor` z katalogu (pomarańcz z ikony).
// Liquid Glass dają same kontrolki systemowe (paski, przyciski `.glass`, akcesorium paska
// zakładek); własne tła kart są zwykłymi wypełnieniami, bez szkła na szkle.

enum Design {
    /// Odstęp od krawędzi ekranu (jak w aplikacjach systemowych).
    static let margin: CGFloat = 16
    /// Zaokrąglenie okładek — względem szerokości, ale nie mniej niż 6 i nie więcej niż 14 pt.
    static func coverRadius(_ width: CGFloat) -> CGFloat { min(14, max(6, width * 0.06)) }
    /// Zaokrąglenie kart.
    static let cardRadius: CGFloat = 22
}

// MARK: - Nagłówek sekcji

/// Nagłówek sekcji w stylu aplikacji systemowych: pogrubiony tytuł, a gdy jest pełna lista —
/// cały nagłówek prowadzi do niej („Zobacz wszystko” jako strzałka przy tytule).
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var destination: Route? = nil

    var body: some View {
        Group {
            if let destination {
                NavigationLink(value: destination) { label(chevron: true) }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Pokazuje wszystko"))
            } else {
                label(chevron: false)
            }
        }
        .padding(.horizontal, Design.margin)
        .accessibilityAddTraits(.isHeader)
    }

    private func label(chevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.title2.bold())
                if chevron {
                    Image(systemName: "chevron.forward")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }
}

// MARK: - Pozioma półka

/// Jak szerokie są karty półki.
enum ShelfWidth {
    /// Okładki: na iPhonie ok. 2,3 karty na ekranie, na iPadzie 5–6.
    case cover
    /// Duże karty „Słuchaj dalej” i kolumny odcinków: na iPhonie jedna z kawałkiem następnej.
    case wide
    /// Okrągłe zdjęcia autorów.
    case round

    func count(regular: Bool, largeText: Bool) -> (count: Int, span: Int) {
        switch (self, regular, largeText) {
        case (.cover, false, false): (7, 3)
        case (.cover, false, true): (5, 3)
        case (.cover, true, false): (11, 2)
        case (.cover, true, true): (7, 2)
        case (.wide, false, _): (12, 11)
        case (.wide, true, false): (5, 2)
        case (.wide, true, true): (3, 2)
        case (.round, false, false): (4, 1)
        case (.round, false, true): (5, 2)
        case (.round, true, false): (8, 1)
        case (.round, true, true): (5, 1)
        }
    }
}

/// Pozioma półka: nagłówek i przewijane karty, zatrzymujące się na krawędzi karty.
struct Shelf<Data: RandomAccessCollection, Card: View>: View where Data.Element: Identifiable {
    let title: String
    var subtitle: String? = nil
    var destination: Route? = nil
    var width: ShelfWidth = .cover
    let items: Data
    @ViewBuilder let card: (Data.Element) -> Card

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if !items.isEmpty {
            // iPhone w poziomie liczy się jak szeroki ekran (więcej, węższych kart).
            let layout = width.count(regular: sizeClass == .regular || verticalSizeClass == .compact, largeText: typeSize >= .xxLarge)
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: title, subtitle: subtitle, destination: destination)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            card(item)
                                .containerRelativeFrame(.horizontal, count: layout.count, span: layout.span, spacing: 12)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, Design.margin, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
            }
        }
    }
}

// MARK: - Okładka

/// Okładka pozycji z pamięci okładek; pobieranie anulowane, gdy karta zniknie z ekranu.
/// Zaokrąglenie ciągłe, delikatna obwódka i cień jak w aplikacjach systemowych.
struct ItemCover: View {
    let itemID: String
    let session: ServerSession
    /// Rozmiar w punktach, do którego serwer zmniejsza okładkę (kubełki: mniej wariantów w pamięci).
    var points: CGFloat = 180
    var isPodcast = false
    /// Cień tylko przy większych okładkach (miniatury w wierszach bez cienia).
    var shadow: Bool? = nil
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    CoverPlaceholder(isPodcast: isPodcast)
                }
            }
            .coverStyle(shadow: shadow ?? (points >= 120))
            .task(id: itemID) {
                image = await session.cover(itemID: itemID, path: nil, size: points, scale: displayScale)
            }
            .accessibilityHidden(true)
    }
}

/// Zamiast okładki: spokojny gradient z symbolem.
struct CoverPlaceholder: View {
    var isPodcast = false

    var body: some View {
        LinearGradient(colors: [Color(.systemGray4), Color(.systemGray5)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Image(systemName: isPodcast ? "dot.radiowaves.left.and.right" : "book.closed")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
    }
}

private struct CoverStyle: ViewModifier {
    let shadow: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(shadow ? (scheme == .dark ? 0.35 : 0.14) : 0), radius: 8, y: 4)
    }
}

extension View {
    /// Zaokrąglenie, obwódka i cień okładki.
    func coverStyle(shadow: Bool = true) -> some View { modifier(CoverStyle(shadow: shadow)) }
}

/// Okładka z gotowego obrazu (odtwarzacz, strona pozycji).
struct CoverImage: View {
    let image: UIImage?
    var isPodcast = false
    var shadow = true

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    CoverPlaceholder(isPodcast: isPodcast)
                }
            }
            .coverStyle(shadow: shadow)
    }
}

// MARK: - Tło z okładki

/// Rozmyta okładka jako tło nagłówka strony albo odtwarzacza. Przy „Zmniejsz przezroczystość”
/// — jednolity kolor tła (bez rozmycia).
struct ArtworkBackdrop: View {
    let image: UIImage?
    /// Jak mocno tło przechodzi w kolor systemowy na dole (strony) — odtwarzacz zostaje ciemny.
    var fadesToBackground = true
    /// Kolor, w który tło przechodzi (strona z listą — tło pogrupowane).
    var base = Color(.systemBackground)
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            base
            if let image, !reduceTransparency {
                // Obraz w nakładce: wypełnia miejsce, ale nie wpływa na rozmiar układu.
                Color.clear.overlay {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 50, opaque: true)
                        .saturation(1.3)
                        .opacity(fadesToBackground ? 0.55 : 1)
                }
                .clipped()
            }
            if fadesToBackground {
                LinearGradient(colors: [.clear, base], startPoint: .center, endPoint: .bottom)
            } else {
                // Jasne okładki: biały tekst odtwarzacza musi zostać czytelny.
                Color.black.opacity(reduceTransparency ? 0.85 : 0.5)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Postęp

/// Cienki pasek postępu (karty, wiersze odcinków).
struct ProgressCapsule: View {
    let fraction: Double
    var height: CGFloat = 4

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(.tint).frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
                }
            }
            .accessibilityHidden(true)
    }
}

/// „Zostało 12 min” / „Ukończone” / długość.
enum RemainingText {
    static func text(currentTime: Double?, duration: Double?, isFinished: Bool) -> String? {
        if isFinished { return "Ukończone" }
        guard let duration, duration > 0 else { return nil }
        guard let time = currentTime, time > 0 else { return TimeText.long(duration) }
        return "Zostało \(TimeText.long(max(0, duration - time)))"
    }
}

// MARK: - Stany

/// Stan pusty z opcjonalnym działaniem.
struct EmptyState: View {
    let title: String
    let systemImage: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.glass)
            }
        }
    }
}

/// Stan błędu z ponowieniem.
struct LoadFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        EmptyState(title: "Nie udało się wczytać", systemImage: "exclamationmark.triangle", message: message,
                   actionTitle: "Spróbuj ponownie", action: retry)
    }
}

/// Szkielet ekranu z półkami, zanim przyjdą dane (zamiast kręciołka na cały ekran).
struct ShelvesSkeleton: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                skeletonShelf(width: .wide, height: 150)
                skeletonShelf(width: .cover, height: nil)
                skeletonShelf(width: .cover, height: nil)
            }
            .padding(.vertical)
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Wczytywanie"))
    }

    private func skeletonShelf(width: ShelfWidth, height: CGFloat?) -> some View {
        let layout = width.count(regular: sizeClass == .regular, largeText: false)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Wczytywanie półki").font(.title2.bold()).padding(.horizontal, Design.margin)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(0..<6, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: height == nil ? 10 : Design.cardRadius, style: .continuous)
                                .fill(.quaternary)
                                .aspectRatio(height == nil ? 1 : nil, contentMode: .fit)
                                .frame(height: height)
                            if height == nil {
                                Text("Tytuł książki").font(.subheadline)
                                Text("Autor").font(.caption)
                            }
                        }
                        .containerRelativeFrame(.horizontal, count: layout.count, span: layout.span, spacing: 12)
                    }
                }
            }
            .contentMargins(.horizontal, Design.margin, for: .scrollContent)
        }
        .redacted(reason: .placeholder)
    }
}

// MARK: - Przycisk odtwarzania na karcie

/// Okrągły przycisk odtwarzania/pauzy (Liquid Glass z kolorem akcentu).
struct CirclePlayButton: View {
    let isCurrent: Bool
    let isPlaying: Bool
    var isStarting = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isStarting {
                    ProgressView()
                } else {
                    Image(systemName: isCurrent && isPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(minWidth: 22, minHeight: 22)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .accessibilityLabel(Text(isCurrent && isPlaying ? "Pauza" : "Odtwarzaj"))
    }
}
