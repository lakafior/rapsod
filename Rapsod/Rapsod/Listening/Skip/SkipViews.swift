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

/// Segmenty odcinka: przesuwanie granic, rodzaj, usuwanie i dodawanie, z informacją o źródle
/// i o reklamach, których położenia nie znamy. Zapis — plik obok odcinka na serwerze.
/// Z odtwarzacza (`init(listening:)`) albo z menu odcinka bez odtwarzania (`EpisodeSkipSheet`).
struct SkipEditorSheet: View {
    let title: String?
    let context: PlaybackCoordinator.SkipContext?
    let duration: Double
    /// Ten odcinek gra: są przyciski „bieżące miejsce” (sam czas czytany dopiero przy kliknięciu).
    let isLive: Bool
    let current: () -> Double
    /// Odsłuch od miejsca (odcinek, który nie gra, zaczyna grać).
    let seek: (Double) -> Void
    let save: (SkipMap) async throws -> Void
    /// Wykrywanie tego odcinka od nowa (menu odcinka); `nil` — bez przycisku.
    var detect: (() -> Void)?
    var detecting = false
    var unavailable = "Ten odcinek nie ma jeszcze znaczników. Użyj „Wykryj segmenty” na stronie podcastu albo dodaj segment ręcznie."
    @State private var map: SkipMap?
    /// Stan przed poprawkami (do „Zapisz” i do odświeżenia po wykryciu od nowa).
    @State private var baseline: SkipMap?
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    private var edited: Bool { map != baseline }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Segmenty sponsorowane").font(.title2.weight(.semibold))
            if let title { Text(title).foregroundStyle(.secondary).lineLimit(1) }
            if let context {
                status(context)
                if map != nil { segmentList }
            } else {
                Text(unavailable).foregroundStyle(.secondary)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            HStack {
                Button(isLive ? "Dodaj w bieżącym miejscu" : "Dodaj segment", systemImage: "plus") { addSegment() }
                    .disabled(context == nil)
                    .help(isLive ? "Nowy segment od bieżącej pozycji (30 s) — potem popraw granice"
                                 : "Nowy segment od początku odcinka (30 s) — potem popraw granice")
                if map?.corrections.isEmpty == false {
                    Button("Przywróć wykryte") { map?.resetCorrections() }
                        .help("Usuwa wszystkie ręczne poprawki tego odcinka")
                }
                if let detect {
                    Button(context?.map == nil ? "Wykryj teraz" : "Wykryj ponownie", systemImage: "wand.and.stars", action: detect)
                        .disabled(detecting || edited)
                        .help(edited ? "Najpierw zapisz albo cofnij poprawki" : "Wykrywanie segmentów w tym odcinku (ręczne poprawki zostają)")
                    if detecting { ProgressView().controlSize(.small) }
                }
                Spacer()
                Button("Anuluj", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Zapisz") { saveMap() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || map == nil || !edited)
            }
        }
        .padding(20)
        .frame(width: 600, height: 520)
        .onAppear(perform: reset)
        // Znaczniki policzone od nowa (np. „Wykryj teraz”): bez poprawek — pokaż nowe.
        .onChange(of: context?.map) { if !edited { reset() } }
    }

    private func reset() {
        map = context.map { $0.map ?? Self.emptyMap($0) }
        baseline = map
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
                SkipSegmentRow(segment: segment, duration: duration, current: isLive ? current : nil,
                               seek: seek) { start, end, kind in
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
        let start = isLive ? current() : 0
        map?.add(start: start, end: min(start + 30, duration), kind: .sponsor)
    }

    private func saveMap() {
        guard let map else { return }
        saving = true
        Task {
            do {
                try await save(map)
                dismiss()
            } catch {
                self.error = "Nie udało się zapisać: \(error.localizedDescription)"
            }
            saving = false
        }
    }
}

/// Edytor bieżącego odcinka w odtwarzaczu (znaczniki czytane na bieżąco).
struct PlayerSkipEditorSheet: View {
    let listening: ListeningController

    var body: some View {
        let playback = listening.playback, player = listening.player
        SkipEditorSheet(title: player.book?.title, context: playback.skipContext, duration: player.duration,
                        isLive: true, current: { player.currentTime }, seek: { player.seek(to: $0) },
                        save: { try await playback.saveSkips($0) })
    }
}

/// Segmenty odcinka z menu odcinka, bez odtwarzania: gdy ten odcinek gra — edytor odtwarzacza,
/// inaczej znaczniki z pliku obok odcinka na tym Macu, z „Wykryj teraz” i zapisem do tego pliku.
struct EpisodeSkipSheet: View {
    let listening: ListeningController
    let itemID: String
    let episode: AudiobookshelfClient.PodcastEpisode
    /// Wybór przy otwarciu (nie zmienia się, gdy odcinek ruszy z „Odtwórz” — edycja zostaje).
    @State private var fromPlayer: Bool?
    @State private var loaded: PlaybackCoordinator.SkipContext??

    private var key: String { ListeningController.key(itemID, episode.id) }

    var body: some View {
        let player = listening.player
        let skip = listening.skip
        Group {
            if fromPlayer == true {
                PlayerSkipEditorSheet(listening: listening)
            } else if fromPlayer == false, let loaded {
                let hasAudio = SkipController.audioURL(episode) != nil
                SkipEditorSheet(
                    title: episode.title, context: loaded, duration: loaded?.actual.duration ?? 0,
                    isLive: player.book?.key == key, current: { player.currentTime },
                    seek: { position in Task { await listening.play(itemID: itemID, episodeID: episode.id, at: position) } },
                    save: { map in
                        guard let audio = SkipController.audioURL(episode) else { return }
                        try await skip.save(map, audio: audio, itemID: itemID)
                        skip.onChanged?(itemID, episode.id)
                    },
                    detect: hasAudio ? { skip.analyze(itemID: itemID, episodeID: episode.id) } : nil,
                    detecting: skip.phase(itemID: itemID, episodeID: episode.id)?.isActive == true,
                    unavailable: hasAudio ? "Nie udało się odczytać pliku odcinka."
                                          : "Pliku tego odcinka nie ma na tym Macu — serwer go jeszcze nie pobrał.")
            } else {
                ProgressView("Wczytywanie segmentów…").frame(width: 600, height: 520)
            }
        }
        .onAppear {
            if fromPlayer == nil { fromPlayer = player.book?.key == key && listening.playback.skipContext != nil }
        }
        // Także po zapisie znaczników tego podcastu (np. „Wykryj teraz” skończyło).
        .task(id: skip.revision[itemID] ?? 0) {
            loaded = .some(await SkipController.context(for: episode, itemID: itemID))
        }
    }
}

/// Jeden segment w edytorze: rodzaj, granice (pole czasu, „bieżące miejsce”), odsłuch i usunięcie.
struct SkipSegmentRow: View {
    let segment: SkipSegment
    let duration: Double
    /// `nil` — odcinek nie gra, bez „bieżącego miejsca”.
    let current: (() -> Double)?
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
                if let current {
                    Button("Bieżące miejsce jako początek", systemImage: "arrow.down.to.line") { change(current(), segment.end, nil) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                Text("–")
                ClockField(label: "Koniec", value: segment.end) { change(segment.start, $0, nil) }
                if let current {
                    Button("Bieżące miejsce jako koniec", systemImage: "arrow.down.to.line") { change(segment.start, current(), nil) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
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
    @State private var preference = SkipPreference.inherit
    @State private var withoutModel = 0

    private var defaults: SkipSettings { listening.skipSettings.categoryDefaults }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Segmenty sponsorowane").font(.headline)
            Toggle("Oznaczaj i pomijaj w tym podcaście", isOn: $preference.enabled)
                .accessibilityIdentifier("podcastSkip.enabled")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Reklamy i sponsorzy")
                    Picker("Reklamy i sponsorzy", selection: $preference.sponsor) { actions(default: defaults.sponsor) }
                        .labelsHidden().accessibilityIdentifier("podcastSkip.sponsor")
                }
                GridRow {
                    Text("Autopromocja")
                    Picker("Autopromocja", selection: $preference.selfPromo) { actions(default: defaults.selfPromo) }
                        .labelsHidden().accessibilityIdentifier("podcastSkip.selfPromo")
                }
            }
            .disabled(!preference.enabled)
            Text("Ustawienie dotyczy tego Maca; „Jak w ustawieniach” idzie za Ustawieniami → Ogólne → Fragmenty sponsorowane. Znaczniki pochodzą z opisu odcinka (czasy przy słowach jak „sponsor”, „partner odcinka”, „autopromocja”), rozdziałów, informacji o reklamach wstawianych przez serwer wydawcy\(listening.skip.modelEnabled ? " i z transkrypcji ocenionej przez model językowy" : "").")
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
            Text(listening.skip.modelEnabled
                 ? "Liczy się samo po pobraniu nowego odcinka na serwer. Ten przycisk wyśle do modelu także pobrane odcinki, których jeszcze nie oceniał (teraz: \(withoutModel)); ponownie jeden odcinek — z menu odcinka. Ręczne poprawki zostają przy ponownym wykrywaniu."
                 : "Liczy się samo po pobraniu nowego odcinka na serwer. Ręczne poprawki zostają przy ponownym wykrywaniu.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            preference = listening.skipSettings.preference(podcastID: item.id)
            withoutModel = listening.skip.episodesWithoutModel(item)
        }
        .onChange(of: preference) { listening.setSkipPreference(preference, podcastID: item.id) }
    }

    @ViewBuilder private func actions(default value: SkipAction) -> some View {
        Text("Jak w ustawieniach (\(value.title.lowercased()))").tag(SkipAction?.none)
        ForEach(SkipAction.allCases, id: \.self) { Text($0.title).tag(SkipAction?.some($0)) }
    }
}

/// Podsumowanie znaczników w wierszu odcinka.
struct EpisodeSkipBadge: View {
    let skip: SkipController
    let itemID: String
    let episode: AudiobookshelfClient.PodcastEpisode

    var body: some View {
        switch skip.phase(itemID: itemID, episodeID: episode.id) {
        case .queued?:
            Label(skip.isModelQueued(itemID: itemID, episodeID: episode.id) ? "Segmenty: w kolejce do analizy" : "Wykrywanie segmentów…", systemImage: "hourglass")
        case .running?:
            Label("Wykrywanie segmentów…", systemImage: "hourglass")
        case .transcribing(let fraction)?:
            Label("Transkrypcja \(Int((fraction * 100).rounded())) %", systemImage: "waveform")
                .help("Rozpoznawanie mowy na tym Macu, do oceny fragmentów sponsorowanych")
        case .classifying(let done, let total)?:
            Label("Klasyfikacja \(done)/\(total)", systemImage: "text.magnifyingglass")
                .help("Fragmenty transkrypcji oceniane przez model językowy")
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
