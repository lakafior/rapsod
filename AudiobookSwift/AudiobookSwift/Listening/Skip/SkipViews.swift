// Pochodzenie: kod własny projektu (etap 13a).

import AudiobookshelfKit
import AudiobookshelfPlayback
import SwiftUI

/// Kolor rodzaju segmentu (znaczniki na pasku i w edytorze).
extension SkipKind {
    var color: Color { self == .selfPromo ? .purple : .orange }
}

/// Znaczniki segmentów pod suwakiem postępu, w tym samym zakresie co suwak (rozdział albo całość).
/// Dla VoiceOver ukryte — segmenty opisuje komunikat i edytor.
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
                        .fill(entry.kind.color.opacity(entry.action == .skip ? 0.9 : 0.4))
                        .frame(width: max(3, (b - a) * proxy.size.width), height: 4)
                        .offset(x: a * proxy.size.width)
                }
            }
        }
        .frame(height: visible.isEmpty ? 0 : 4)
        .accessibilityHidden(true)
    }
}

/// Komunikat o pominięciu („Pominięto reklamę (0:58) · Cofnij”) albo — w segmencie tylko do pokazania
/// lub po przewinięciu w jego środek — „Reklama do 12:30 · Pomiń”.
struct SkipBanner: View {
    let player: AudiobookPlayer
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        Group {
            if let event = player.lastSkip {
                HStack(spacing: 8) {
                    Image(systemName: "forward.end.fill").foregroundStyle(event.entry.kind.color)
                    Text(event.message).lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Cofnij") { player.undoSkip() }
                        .accessibilityHint("Wraca na początek pominiętego fragmentu i odtwarza go")
                        .accessibilityIdentifier("skip.undo")
                    if !compact {
                        Button("Zamknij", systemImage: "xmark") { player.dismissLastSkip() }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("skip.banner")
            } else if let entry = player.skipPlan.entry(at: player.currentTime), !compact {
                HStack(spacing: 8) {
                    Image(systemName: "megaphone").foregroundStyle(entry.kind.color)
                    Text("\(entry.kind.title) do \(PlaybackFormat.clock(entry.end))").lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Pomiń") { player.skipCurrentSegment() }
                        .accessibilityLabel("Pomiń: \(entry.kind.title.lowercased())")
                        .accessibilityIdentifier("skip.skipNow")
                }
                .accessibilityElement(children: .contain)
            }
        }
        .font(compact ? .caption : .callout)
        .controlSize(.small)
        .padding(.horizontal, compact ? 0 : 10)
        .padding(.vertical, compact ? 0 : 6)
        .background(compact ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary), in: .rect(cornerRadius: 8))
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: player.lastSkip?.id)
        .onChange(of: player.lastSkip?.id) {
            guard !compact, let event = player.lastSkip else { return }
            AccessibilityNotification.Announcement(event.accessibilityMessage).post()
        }
        .onChange(of: voiceOver, initial: true) {
            // Z VoiceOver „Cofnij” trzeba najpierw znaleźć — dłużej niż 10 s.
            player.skipUndoWindow = voiceOver ? .seconds(30) : .seconds(10)
        }
    }
}

// MARK: - Edytor

/// Segmenty bieżącego odcinka: przesuwanie granic, rodzaj, usuwanie i dodawanie, z informacją
/// o źródle i o reklamach, których położenia nie znamy. Zapis — plik obok odcinka na serwerze.
struct SkipEditorSheet: View {
    let listening: ListeningController
    @State private var map: SkipMap?
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    private var playback: PlaybackCoordinator { listening.playback }
    private var player: AudiobookPlayer { listening.player }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Segmenty sponsorowane").font(.title2.weight(.semibold))
            if let book = player.book { Text(book.title).foregroundStyle(.secondary).lineLimit(1) }
            if let context = playback.skipContext {
                status(context)
                if map != nil { segmentList }
            } else {
                Text("Ten odcinek nie ma jeszcze znaczników. Użyj „Wykryj segmenty” na stronie podcastu albo dodaj segment ręcznie.")
                    .foregroundStyle(.secondary)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Dodaj w bieżącym miejscu", systemImage: "plus") { addSegment() }
                    .disabled(playback.skipContext == nil)
                    .help("Nowy segment od bieżącej pozycji (30 s) — potem popraw granice")
                if map?.corrections.isEmpty == false {
                    Button("Przywróć wykryte") { map?.resetCorrections() }
                        .help("Usuwa wszystkie ręczne poprawki tego odcinka")
                }
                Spacer()
                Button("Anuluj", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Zapisz") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || map == nil || map == playback.skipContext?.map)
            }
        }
        .padding(20)
        .frame(width: 600, height: 520)
        .onAppear { map = playback.skipContext.map { $0.map ?? Self.emptyMap($0) } }
    }

    static func emptyMap(_ context: PlaybackCoordinator.SkipContext) -> SkipMap {
        SkipMap(episode: .init(itemID: context.podcastID), audio: context.actual)
    }

    @ViewBuilder private func status(_ context: PlaybackCoordinator.SkipContext) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .mismatch(let reason)? = context.match {
                Label("Znaczniki dotyczą innej wersji pliku (\(reason)) — odtwarzacz ich nie używa. Wykryj segmenty ponownie.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let ads = context.map?.insertedAds, !ads.located {
                Label(SkipEditorSheet.insertedText(ads), systemImage: "questionmark.circle")
            }
            ForEach(context.map?.notices ?? [], id: \.self) { notice in
                Label("Opis: \(notice.text)" + (notice.time.map { " (od \(PlaybackFormat.clock($0)), bez końca)" } ?? ""), systemImage: "text.quote")
                    .lineLimit(2)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    static func insertedText(_ ads: InsertedAds) -> String {
        let amount = ads.seconds.map { " (ok. \(PlaybackFormat.clock($0)))" } ?? ads.slots.map { " (\($0) slotów)" } ?? ""
        return "Plik ma reklamy wstawiane dynamicznie\(amount), ale nie wiadomo gdzie — bez zgadywania granic."
            + (ads.source == .durationDifference ? " Czasy z opisu mogą być przesunięte, więc są tylko znacznikami." : "")
    }

    private var segmentList: some View {
        List {
            let segments = map?.effectiveSegments ?? []
            if segments.isEmpty {
                Text("Brak segmentów.").foregroundStyle(.secondary)
            }
            ForEach(segments) { segment in
                SkipSegmentRow(segment: segment, duration: player.duration, current: { player.currentTime },
                               seek: { player.seek(to: $0) }) { start, end, kind in
                    map?.adjust(segment, start: start, end: end, kind: kind)
                } remove: {
                    map?.remove(segment)
                }
            }
        }
        .listStyle(.bordered)
    }

    private func addSegment() {
        guard map != nil else { return }
        let start = player.currentTime
        map?.add(start: start, end: min(start + 30, player.duration), kind: .sponsor)
    }

    private func save() {
        guard let map else { return }
        saving = true
        Task {
            do {
                try await playback.saveSkips(map)
                dismiss()
            } catch {
                self.error = "Nie udało się zapisać: \(error.localizedDescription)"
            }
            saving = false
        }
    }
}

/// Jeden segment w edytorze: rodzaj, granice (pole czasu, „bieżące miejsce”), odsłuch i usunięcie.
struct SkipSegmentRow: View {
    let segment: SkipSegment
    let duration: Double
    let current: () -> Double
    let seek: (Double) -> Void
    let change: (_ start: Double, _ end: Double, _ kind: SkipKind?) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Rodzaj", selection: Binding(get: { segment.kind }, set: { change(segment.start, segment.end, $0) })) {
                    ForEach(SkipKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                Text(segment.source == .user ? "ręcznie" : "źródło: \(segment.source.title)")
                    .font(.caption).foregroundStyle(.secondary)
                if !segment.autoSkip {
                    Text("tylko znacznik").font(.caption).foregroundStyle(.orange)
                        .help("Granice niepewne (np. długi zakres z opisu albo reklamy wstawione w nieznanych miejscach) — bez automatycznego pomijania")
                }
                Spacer()
                Button("Odtwórz od początku segmentu", systemImage: "play") { seek(segment.start) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                Button("Usuń segment", systemImage: "trash", role: .destructive, action: remove)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            HStack(spacing: 6) {
                ClockField(label: "Początek", value: segment.start) { change($0, segment.end, nil) }
                Button("Bieżące miejsce jako początek", systemImage: "arrow.down.to.line") { change(current(), segment.end, nil) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                Text("–")
                ClockField(label: "Koniec", value: segment.end) { change(segment.start, $0, nil) }
                Button("Bieżące miejsce jako koniec", systemImage: "arrow.down.to.line") { change(segment.start, current(), nil) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                Text(PlaybackFormat.clock(segment.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let label = segment.label { Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(segment.kind.title), \(SkipText.range(segment.start, segment.end))")
    }
}

/// Pole czasu „m:ss” albo „h:mm:ss” (sekundy też); zatwierdza po Enter i utracie fokusu.
struct ClockField: View {
    let label: String
    let value: Double
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text)
            .labelsHidden()
            .font(.body.monospacedDigit())
            .frame(width: 80)
            .focused($focused)
            .onAppear { text = PlaybackFormat.clock(value) }
            .onChange(of: value) { if !focused { text = PlaybackFormat.clock(value) } }
            .onSubmit(apply)
            .onChange(of: focused) { if !focused { apply() } }
            .accessibilityLabel(label)
    }

    private func apply() {
        guard let seconds = Self.parse(text) else {
            text = PlaybackFormat.clock(value)
            return
        }
        // Zatwierdzenie bez zmiany (Enter, utrata fokusu) nie jest poprawką.
        if abs(seconds - value.rounded(.down)) >= 1 { commit(seconds) }
    }

    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0.replacingOccurrences(of: ",", with: ".")) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }
}

// MARK: - Strona podcastu

/// Ustawienie pomijania dla podcastu (na tym Macu) i wykrywanie w pobranych odcinkach.
struct PodcastSkipButton: View {
    let listening: ListeningController
    let item: AudiobookshelfClient.ItemDetail
    @State private var shown = false

    var body: some View {
        Button("Segmenty sponsorowane", systemImage: "forward.end.alt") { shown = true }
            .labelStyle(.iconOnly)
            .help("Segmenty sponsorowane: pomijanie i wykrywanie")
            .accessibilityIdentifier("podcast.skip")
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                PodcastSkipSettingsView(listening: listening, item: item).padding(16).frame(width: 360)
            }
    }
}

struct PodcastSkipSettingsView: View {
    let listening: ListeningController
    let item: AudiobookshelfClient.ItemDetail
    @State private var settings = SkipSettings.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Segmenty sponsorowane").font(.headline)
            Toggle("Oznaczaj i pomijaj w tym podcaście", isOn: $settings.enabled)
                .accessibilityIdentifier("podcastSkip.enabled")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Reklamy i sponsorzy")
                    Picker("Reklamy i sponsorzy", selection: $settings.sponsor) { actions }
                        .labelsHidden().accessibilityIdentifier("podcastSkip.sponsor")
                }
                GridRow {
                    Text("Autopromocja")
                    Picker("Autopromocja", selection: $settings.selfPromo) { actions }
                        .labelsHidden().accessibilityIdentifier("podcastSkip.selfPromo")
                }
            }
            .disabled(!settings.enabled)
            Text("Ustawienie dotyczy tego Maca. Znaczniki pochodzą z opisu odcinka (czasy przy słowach jak „sponsor”, „partner odcinka”, „autopromocja”), rozdziałów i informacji o reklamach wstawianych przez serwer wydawcy.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button("Wykryj w pobranych odcinkach") {
                    listening.skip.analyze(itemID: item.id, force: true)
                }
                .disabled(listening.skip.isBusy)
                .accessibilityIdentifier("podcastSkip.analyze")
                if listening.skip.isBusy { ProgressView().controlSize(.small) }
            }
            Text("Liczy się samo po pobraniu nowego odcinka na serwer. Ręczne poprawki zostają przy ponownym wykrywaniu.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { settings = listening.skipSettings.settings(podcastID: item.id) }
        .onChange(of: settings) { listening.setSkipSettings(settings, podcastID: item.id) }
    }

    @ViewBuilder private var actions: some View {
        ForEach(SkipAction.allCases, id: \.self) { Text($0.title).tag($0) }
    }
}

/// Podsumowanie znaczników w wierszu odcinka.
struct EpisodeSkipBadge: View {
    let skip: SkipController
    let itemID: String
    let episode: AudiobookshelfClient.PodcastEpisode

    var body: some View {
        switch skip.phase(itemID: itemID, episodeID: episode.id) {
        case .queued?, .running?:
            Label("Wykrywanie segmentów…", systemImage: "hourglass")
        case .failed(let message)?:
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1)
        default:
            if let summary = skip.summary(itemID: itemID, episode: episode) {
                Label(summary, systemImage: "forward.end.alt")
                    .help("Segmenty sponsorowane w tym odcinku")
            }
        }
    }
}
