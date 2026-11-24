// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 11b).

import SwiftUI
import AudiobookshelfKit
import AudiobookshelfPlayback

// Tryb „Tekst” odtwarzacza (etap 11b, ruch przebudowany w 11d): tekst książki z bieżącym
// zdaniem w pełnej jasności i resztą przygaszoną, przewijany tak, by czytany wiersz stał
// w górnej jednej trzeciej ekranu. Skład, warstwy wierszy i ruch są we wspólnym
// `TextFlowController` (pakiet); tu stany, przycisk powrotu i ustawienia.

/// Ustawienia tekstu zapamiętane na urządzeniu.
enum BookTextSettings {
    static let serifKey = "bookText.serif"
    static let scaleKey = "bookText.scale"
    static let scales: [Double] = [0.8, 0.9, 1, 1.12, 1.25, 1.4, 1.6]
}

/// Tekst książki w odtwarzaczu: stany (wczytywanie, brak mapy, mapa nieaktualna) i przewijany tekst.
struct BookTextView: View {
    let model: TextFollowModel
    let player: AudiobookPlayer
    /// Wysokość wolnego miejsca pod tekstem (sterowanie) — przycisk powrotu stoi nad nim.
    var bottomInset: CGFloat = 0

    var body: some View {
        switch model.phase {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Wczytywanie tekstu…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let reason):
            ContentUnavailableView {
                Label("Brak tekstu", systemImage: "text.page.slash")
            } description: {
                Text(reason.message)
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Nie udało się wczytać tekstu", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Spróbuj ponownie") { model.reload() }
                    .buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if let document = model.document {
                BookTextScroll(model: model, document: document, player: player, bottomInset: bottomInset)
            }
        }
    }
}

private struct BookTextScroll: View {
    let model: TextFollowModel
    let document: TextSyncDocument
    let player: AudiobookPlayer
    let bottomInset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(BookTextSettings.serifKey) private var serif = true
    @AppStorage(BookTextSettings.scaleKey) private var scale = 1.0
    @ScaledMetric(relativeTo: .body) private var baseSize: CGFloat = 21

    var body: some View {
        // Zgodny z Dynamic Type, ale z górną granicą — przy rozmiarach dostępności 60-punktowy
        // tekst mieściłby dwa słowa w wierszu; dalsze powiększenie daje menu „Aa”.
        let size = min(baseSize, 34) * scale * (sizeClass == .regular ? 1.15 : 1)
        let dimmed = contrast == .increased ? 0.62 : 0.4
        let _ = RenderCounter.tick("BookTextScroll")
        BookTextCanvas(
            model: model, document: document,
            sentence: model.currentSentence, following: model.isFollowing,
            jump: model.jumpRequest, back: model.returnRequest,
            size: size, serif: serif, dimmed: dimmed,
            columnWidth: sizeClass == .regular ? 660 : 620, reduceMotion: reduceMotion,
            onTap: play(sentence:)
        )
        .overlay(alignment: .bottom) {
            if !model.isFollowing {
                Button {
                    model.resumeFollowing()
                } label: {
                    Label("Wróć do bieżącego miejsca", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding(.bottom, 12 + bottomInset)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) { notices }
        // Przejście przycisku powrotu tylko z animacją; z „Ogranicz ruch” — samo pojawienie się.
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: model.isFollowing)
    }

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 6) {
            if model.isStale {
                Label("Nagranie albo e-book zmieniły się od synchronizacji — tekst może nie trafiać w audio. Zsynchronizuj e-book na Macu ponownie.", systemImage: "exclamationmark.triangle.fill")
            }
            if model.isOffline {
                Label("Tekst z urządzenia (bez połączenia z serwerem)", systemImage: "wifi.slash")
            }
        }
        .font(.footnote)
        .padding(10)
        .frame(maxWidth: 560)
        .glassEffect(in: .rect(cornerRadius: 14))
        .padding(.horizontal, 16)
        .opacity(model.isStale || model.isOffline ? 1 : 0)
        .accessibilityHidden(!(model.isStale || model.isOffline))
    }

    private func play(sentence: Int) {
        guard let time = model.time(forSentence: sentence) else { return }
        player.seek(to: time)
        if !player.isPlaying { player.togglePlayPause() }
    }
}

/// Podaje modelowi czas z odtwarzacza. Osobny, pusty widok: tylko on obserwuje zegar
/// (dwa razy na sekundę), reszta trybu tekstu odświeża się, gdy zmieni się zdanie.
struct TextTimeFeed: View {
    let model: TextFollowModel
    let player: AudiobookPlayer

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: player.currentTime, initial: true) { feed() }
            .onChange(of: player.isPlaying) { feed() }
            .onChange(of: player.rate) { feed() }
            .accessibilityHidden(true)
    }

    private func feed() {
        model.update(time: player.currentTime, rate: player.rate, isPlaying: player.isPlaying)
    }
}

/// Menu „Aa”: krój i rozmiar tekstu.
struct BookTextSettingsMenu: View {
    @AppStorage(BookTextSettings.serifKey) private var serif = true
    @AppStorage(BookTextSettings.scaleKey) private var scale = 1.0

    var body: some View {
        Menu {
            Picker("Krój", selection: $serif) {
                Text("Szeryfowy").tag(true)
                Text("Bezszeryfowy").tag(false)
            }
            ControlGroup {
                Button("Mniejszy tekst", systemImage: "textformat.size.smaller") { step(-1) }
                    .disabled(scale <= BookTextSettings.scales.first!)
                Button("Większy tekst", systemImage: "textformat.size.larger") { step(1) }
                    .disabled(scale >= BookTextSettings.scales.last!)
            }
        } label: {
            Label("Wygląd tekstu", systemImage: "textformat.size")
        }
        .menuActionDismissBehavior(.disabled)
    }

    private func step(_ direction: Int) {
        let scales = BookTextSettings.scales
        let current = scales.firstIndex { $0 >= scale - 0.001 } ?? 2
        scale = scales[min(max(0, current + direction), scales.count - 1)]
    }
}
