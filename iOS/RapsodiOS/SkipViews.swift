// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 13a).

import AudiobookshelfKit
import AudiobookshelfPlayback
import SwiftUI

extension SkipKind {
    var color: Color { self == .selfPromo ? .purple : .orange }
}

/// Znaczniki segmentów pod suwakiem (zakres suwaka: rozdział albo całość). Dla VoiceOver ukryte —
/// segmenty opisuje komunikat i lista segmentów.
struct SkipMarkersBar: View {
    let plan: SkipPlan
    let range: ClosedRange<Double>

    var body: some View {
        let length = max(range.upperBound - range.lowerBound, 0.001)
        let visible = plan.entries.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                ForEach(visible) { entry in
                    let a = (max(entry.start, range.lowerBound) - range.lowerBound) / length
                    let b = (min(entry.end, range.upperBound) - range.lowerBound) / length
                    Capsule()
                        .fill(entry.kind.color.opacity(entry.action == .skip ? 0.95 : 0.45))
                        .frame(width: max(3, (b - a) * proxy.size.width), height: 4)
                        .offset(x: a * proxy.size.width)
                }
            }
        }
        .frame(height: visible.isEmpty ? 0 : 4)
        .accessibilityHidden(true)
    }
}

/// „Pominięto reklamę (0:58) · Cofnij” albo — w segmencie tylko do pokazania — „Reklama do 12:30 · Pomiń”.
struct SkipBanner: View {
    let player: AudiobookPlayer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        VStack {
            if let event = player.lastSkip {
                row(icon: "forward.end.fill", color: event.entry.kind.color, text: event.message) {
                    Button("Cofnij") { player.undoSkip() }
                        .accessibilityHint(Text("Wraca na początek pominiętego fragmentu i odtwarza go"))
                        .accessibilityIdentifier("skip.undo")
                }
            } else if let entry = player.skipPlan.entry(at: player.currentTime) {
                row(icon: "megaphone", color: entry.kind.color, text: "\(entry.kind.title) do \(PlaybackFormat.clock(entry.end))") {
                    Button("Pomiń") { player.skipCurrentSegment() }
                        .accessibilityLabel(Text("Pomiń: \(entry.kind.title.lowercased())"))
                        .accessibilityIdentifier("skip.skipNow")
                }
            }
        }
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: player.lastSkip?.id)
        .onChange(of: player.lastSkip?.id) {
            guard let event = player.lastSkip else { return }
            AccessibilityNotification.Announcement(event.accessibilityMessage).post()
        }
        .onChange(of: voiceOver, initial: true) {
            player.skipUndoWindow = voiceOver ? .seconds(30) : .seconds(10)
        }
    }

    private func row(icon: String, color: Color, text: String, @ViewBuilder action: () -> some View) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(color).accessibilityHidden(true)
                Text(text).font(.subheadline)
                Spacer(minLength: 4)
                action().buttonStyle(.glass)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label { Text(text).font(.subheadline) } icon: { Image(systemName: icon).foregroundStyle(color) }
                action().buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.white.opacity(0.12), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skip.banner")
    }
}

// MARK: - Lista segmentów odcinka

/// Segmenty odcinka: granice, rodzaj, usuwanie i dodawanie. Poprawki zostają na telefonie.
/// Z odtwarzacza (`init(playback:)`) albo z menu odcinka bez odtwarzania (`EpisodeSkipSheet`).
struct SkipEditorSheet: View {
    let title: String?
    let context: PlaybackCoordinator.SkipContext?
    let duration: Double
    /// Ten odcinek gra: są przyciski „bieżące miejsce” (sam czas czytany dopiero przy dotknięciu).
    let isLive: Bool
    let current: () -> Double
    /// Odsłuch od miejsca (odcinek, który nie gra, zaczyna grać).
    let seek: (Double) -> Void
    let save: (SkipMap) async throws -> Void
    var unavailable = "Ten odcinek nie ma znaczników. Mac liczy je po pobraniu odcinka na serwer."
    @State private var map: SkipMap?
    @State private var baseline: SkipMap?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private func reset() {
        map = context.map { $0.map ?? SkipMap(episode: .init(itemID: $0.podcastID), audio: $0.actual) }
        baseline = map
    }

    var body: some View {
        NavigationStack {
            Form {
                if let title {
                    Text(title).font(.headline)
                }
                if let context {
                    statusSection(context)
                    Section {
                        let segments = map?.effectiveSegments ?? []
                        if segments.isEmpty { Text("Brak segmentów.").foregroundStyle(.secondary) }
                        ForEach(segments) { segment in
                            SkipSegmentEditor(segment: segment, duration: duration, current: isLive ? current : nil,
                                              seek: seek) { start, end, kind in
                                map?.adjust(segment, start: start, end: end, kind: kind)
                            }
                            .swipeActions {
                                Button("Usuń", role: .destructive) { map?.remove(segment) }
                            }
                        }
                        Button(isLive ? "Dodaj w bieżącym miejscu" : "Dodaj segment", systemImage: "plus") {
                            let start = isLive ? current() : 0
                            map?.add(start: start, end: min(start + 30, duration), kind: .sponsor)
                        }
                        if map?.corrections.isEmpty == false {
                            Button("Przywróć wykryte", role: .destructive) { map?.resetCorrections() }
                        }
                    } header: {
                        Text("Segmenty")
                    } footer: {
                        Text("Poprawki zapisują się na tym telefonie. Na Macu poprawki trafiają do pliku na serwerze i widzą je wszystkie urządzenia.")
                    }
                } else {
                    Text(unavailable).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Segmenty sponsorowane")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zapisz") { saveMap() }.disabled(map == nil || map == baseline)
                }
            }
        }
        .onAppear(perform: reset)
        // Znaczniki doczytane po otwarciu (odtwarzacz dopiero je wczytał): bez poprawek — pokaż nowe.
        .onChange(of: context?.map) { if map == baseline { reset() } }
    }

    @ViewBuilder private func statusSection(_ context: PlaybackCoordinator.SkipContext) -> some View {
        Section {
            LabeledContent("Źródło", value: Self.originText(context.origin))
            if case .mismatch(let reason)? = context.match {
                Label("Znaczniki dotyczą innej wersji pliku (\(reason)) — bez pomijania.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let ads = context.map?.insertedAds, !ads.located {
                Label(Self.insertedText(ads), systemImage: "questionmark.circle")
            }
            ForEach(context.map?.notices ?? [], id: \.self) { notice in
                Label("Opis: \(notice.text)" + (notice.time.map { " (od \(PlaybackFormat.clock($0)), bez końca)" } ?? ""), systemImage: "text.quote")
            }
        }
        .font(.subheadline)
    }

    static func originText(_ origin: PlaybackCoordinator.SkipContext.Origin) -> String {
        switch origin {
        case .server: "plik z serwera"
        case .downloaded: "kopia na telefonie"
        case .feed: "opis z kanału (na telefonie)"
        }
    }

    static func insertedText(_ ads: InsertedAds) -> String {
        let amount = ads.seconds.map { " (ok. \(PlaybackFormat.clock($0)))" } ?? ads.slots.map { " (\($0) slotów)" } ?? ""
        return "Plik ma reklamy wstawiane dynamicznie\(amount), ale nie wiadomo gdzie — bez zgadywania granic."
    }

    private func saveMap() {
        guard let map else { return }
        Task {
            do {
                try await save(map)
                dismiss()
            } catch {
                self.error = "Nie udało się zapisać: \(error.localizedDescription)"
            }
        }
    }
}

/// Jeden segment: rodzaj, początek i koniec (krok ±1 s, „bieżące miejsce”), odsłuch.
struct SkipSegmentEditor: View {
    let segment: SkipSegment
    let duration: Double
    /// `nil` — odcinek nie gra, bez „bieżącego miejsca”.
    let current: (() -> Double)?
    let seek: (Double) -> Void
    let change: (_ start: Double, _ end: Double, _ kind: SkipKind?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Rodzaj", selection: Binding(get: { segment.kind }, set: { change(segment.start, segment.end, $0) })) {
                    ForEach(SkipKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Spacer()
                Button("Odtwórz", systemImage: "play.fill") { seek(segment.start) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Odtwórz od początku segmentu"))
            }
            bound("Początek", value: segment.start) { change($0, segment.end, nil) }
            bound("Koniec", value: segment.end) { change(segment.start, $0, nil) }
            Text((segment.source == .user ? "ręcznie" : "źródło: \(segment.source.title)") + (segment.autoSkip ? "" : " · tylko znacznik"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func bound(_ label: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack {
            // Krok ±1 s w granicach odcinka (bez `Binding`, którego domknięcia muszą być `@Sendable`).
            Stepper {
                LabeledContent(label, value: PlaybackFormat.clock(value)).monospacedDigit()
            } onIncrement: {
                set(min(value + 1, max(duration, 1)))
            } onDecrement: {
                set(max(value - 1, 0))
            }
            .accessibilityValue(Text(PlaybackFormat.spokenDuration(value)))
            if let current {
                Button("Bieżące miejsce", systemImage: "scope") { set(current()) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("\(label): bieżące miejsce"))
            }
        }
    }
}

/// Edytor bieżącego odcinka w odtwarzaczu (znaczniki czytane na bieżąco — mogą dojść po otwarciu).
struct PlayerSkipEditorSheet: View {
    let playback: PlaybackCoordinator

    var body: some View {
        let player = playback.player
        SkipEditorSheet(title: nil, context: playback.skipContext, duration: player.duration,
                        isLive: true, current: { player.currentTime }, seek: { player.seek(to: $0) },
                        save: { try await playback.saveSkips($0) })
    }
}

/// Segmenty odcinka z menu odcinka, bez odtwarzania: gdy ten odcinek gra — edytor odtwarzacza,
/// inaczej znaczniki wczytane osobno (plik z serwera albo kopia pobrana z odcinkiem) i poprawki
/// zapisane na telefonie, które odtwarzacz nałoży przy starcie odcinka.
struct EpisodeSkipSheet: View {
    let itemID: String
    let episodeID: String
    let title: String
    let model: AppModel
    /// Wybór przy otwarciu (nie zmienia się, gdy odcinek ruszy z „Odtwórz” — edycja zostaje).
    @State private var fromPlayer: Bool?
    @State private var loaded: PlaybackCoordinator.SkipContext??

    private var key: String { PlaybackTimeline.key(itemID, episodeID) }

    var body: some View {
        let playback = model.playback
        let player = playback.player
        if fromPlayer == nil {
            Color.clear.onAppear { fromPlayer = player.book?.key == key && playback.skipContext != nil }
        } else if fromPlayer == true {
            PlayerSkipEditorSheet(playback: playback)
        } else if let loaded {
            SkipEditorSheet(
                title: title, context: loaded, duration: loaded?.actual.duration ?? 0,
                isLive: player.book?.key == key, current: { player.currentTime },
                seek: { position in
                    if player.book?.key == key {
                        player.seek(to: position)
                        if !player.isPlaying { player.play() }
                    } else {
                        Task { await playback.play(itemID: itemID, episodeID: episodeID, from: position) }
                    }
                },
                save: { map in
                    try SkipSupport.saveCorrections(map, itemID: itemID, episodeID: episodeID)
                    if player.book?.key == key { playback.reloadSkips() }
                },
                unavailable: model.isOffline
                    ? "Bez połączenia z serwerem znaczniki są dostępne tylko dla odcinków pobranych na telefon."
                    : "Nie udało się wczytać znaczników tego odcinka.")
        } else {
            NavigationStack {
                ProgressView("Wczytywanie segmentów…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Segmenty sponsorowane")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .task { loaded = .some(await SkipSupport.episodeContext(itemID: itemID, episodeID: episodeID, model: model)) }
        }
    }
}

// MARK: - Strona podcastu

/// Ustawienie pomijania dla podcastu (na tym telefonie) — sekcja arkusza „Ustawienia podcastu”.
/// Zapisuje się od razu, bez „Zapisz”.
struct PodcastSkipSection: View {
    let playback: PlaybackCoordinator
    let podcastID: String
    @State private var settings = SkipSettings.standard

    var body: some View {
        Section {
            Toggle("Oznaczaj i pomijaj", isOn: $settings.enabled)
                .accessibilityIdentifier("podcastSettings.skip")
            Picker("Reklamy i sponsorzy", selection: $settings.sponsor) { actions }.disabled(!settings.enabled)
            Picker("Autopromocja", selection: $settings.selfPromo) { actions }.disabled(!settings.enabled)
        } header: {
            Text("Segmenty sponsorowane")
        } footer: {
            Text("Ustawienie dotyczy tego telefonu i zapisuje się od razu. Znaczniki liczy Mac po pobraniu odcinka na serwer (opis odcinka, rozdziały, reklamy wstawiane przez wydawcę); dla odcinków prosto z kanału — telefon, z opisu. Przy każdym pominięciu jest „Cofnij”.")
        }
        .onAppear { settings = SkipSupport.settings.settings(podcastID: podcastID) }
        .onChange(of: settings) { SkipSupport.setSettings(settings, podcastID: podcastID, playback: playback) }
    }

    @ViewBuilder private var actions: some View {
        ForEach(SkipAction.allCases, id: \.self) { Text($0.title).tag($0) }
    }
}
