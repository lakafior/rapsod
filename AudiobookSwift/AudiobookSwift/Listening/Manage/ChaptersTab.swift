import SwiftUI

/// Rozdział w edycji: czas początku jako tekst (jak wpisany), koniec wynika z następnego.
struct ChapterDraft: Identifiable {
    let id = UUID()
    var startText: String
    var title: String

    init(start: Double, title: String) {
        startText = ChapterTime.format(start)
        self.title = title
    }

    var start: Double? { ChapterTime.parse(startText) }

    static func list(_ item: AudiobookshelfClient.ItemDetail) -> [ChapterDraft] {
        (item.media.chapters ?? []).map { ChapterDraft(start: $0.start, title: $0.title) }
    }

    /// Reguły z `chapters.vue` (`checkChapters`, `saveChapters`) — serwer odpowiada na błąd gołym statusem.
    static func problem(in chapters: [ChapterDraft], duration: Double) -> String? {
        var previous = -1.0
        for (index, chapter) in chapters.enumerated() {
            let number = index + 1
            guard let start = chapter.start else { return "Rozdział \(number): nieprawidłowy czas „\(chapter.startText)” (np. 1:02:03 albo 62:03)." }
            if index == 0, start != 0 { return "Pierwszy rozdział musi zaczynać się od 0:00." }
            if index > 0, start <= previous { return "Rozdział \(number) musi zaczynać się później niż poprzedni." }
            if duration > 0, start >= duration { return "Rozdział \(number) zaczyna się za końcem książki (\(ChapterTime.format(duration)))." }
            if chapter.title.trimmingCharacters(in: .whitespaces).isEmpty { return "Rozdział \(number) musi mieć tytuł." }
            previous = start
        }
        return nil
    }

    static func payload(_ chapters: [ChapterDraft], duration: Double) -> [AudiobookshelfClient.ChapterUpdate] {
        let starts = chapters.map { $0.start ?? 0 }
        return chapters.enumerated().map { index, chapter in
            let end = index + 1 < starts.count ? starts[index + 1] : duration
            return .init(start: starts[index], end: end, title: chapter.title.trimmingCharacters(in: .whitespaces))
        }
    }
}

extension ChapterDraft: Equatable {
    static func == (a: ChapterDraft, b: ChapterDraft) -> Bool { a.startText == b.startText && a.title == b.title }
}

/// Czas rozdziału: `G:MM:SS` albo `M:SS`, z ułamkiem sekundy tylko gdy jest (żeby nie zaokrąglać przy zapisie).
enum ChapterTime {
    static func format(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        let fraction = seconds - Double(whole)
        let base = String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
        guard fraction > 0.0005 else { return base }
        let millis = String(format: "%.3f", fraction).dropFirst() // ".123"
        return base + millis.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }

    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0 else { return nil }
            // Minuty i sekundy (poza pierwszym członem) poniżej 60; ułamek tylko w sekundach.
            if index > 0, value >= 60 { return nil }
            if index < parts.count - 1, value.rounded(.down) != value { return nil }
            total = total * 60 + value
        }
        return total
    }
}

/// Rozdziały książki: tytuły i początki, dodawanie i usuwanie, wyszukiwanie po ASIN (Audnexus).
struct ChaptersTab: View {
    @Bindable var model: ItemEditorModel
    @State private var asin = ""
    @State private var region = "us"
    @State private var removeBranding = true
    @State private var found: [AudiobookshelfClient.ChapterLookup.Chapter]?
    @State private var lookupNote: String?

    private static let regions = ["us", "ca", "uk", "au", "fr", "de", "jp", "it", "in", "es"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            lookup
            Divider()
            HStack {
                Text("Rozdziały: \(model.chapters.count)  ·  długość książki \(ChapterTime.format(model.duration))")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if model.chapters.isEmpty {
                    Button("Dodaj rozdział", systemImage: "plus") { model.chapters = [ChapterDraft(start: 0, title: "Rozdział 1")] }
                }
            }
            List {
                ForEach(Array(model.chapters.enumerated()), id: \.element.id) { index, chapter in
                    row(index: index, chapter: chapter)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .accessibilityIdentifier("chapters.list")
            HStack {
                Text("Koniec rozdziału to początek następnego; ostatni kończy się z książką.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Przywróć") { model.resetChapters() }
                    .disabled(!model.chaptersDirty || model.isBusy)
                Button("Zapisz") { Task { await model.saveChapters() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.chaptersDirty || model.isBusy)
                    .accessibilityIdentifier("chapters.save")
            }
        }
        .padding(.top, 12)
        .onAppear { if asin.isEmpty { asin = model.details.asin } }
    }

    private func row(index: Int, chapter: ChapterDraft) -> some View {
        let valid = chapter.start != nil
        return HStack(spacing: 8) {
            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
            TextField("Początek", text: binding(chapter.id, \.startText))
                .labelsHidden()
                .monospacedDigit()
                .frame(width: 110)
                .foregroundStyle(valid ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
                .accessibilityIdentifier("chapter.start.\(index)")
            TextField("Tytuł", text: binding(chapter.id, \.title))
                .labelsHidden()
                .accessibilityIdentifier("chapter.title.\(index)")
            Button("Dodaj rozdział po", systemImage: "plus.circle") { insert(after: index) }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help("Dodaj rozdział po tym")
                .accessibilityIdentifier("chapter.add.\(index)")
            Button("Usuń rozdział", systemImage: "minus.circle") { model.chapters.remove(at: index) }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help("Usuń rozdział")
                .accessibilityIdentifier("chapter.remove.\(index)")
        }
    }

    private func binding(_ id: UUID, _ keyPath: WritableKeyPath<ChapterDraft, String>) -> Binding<String> {
        Binding {
            model.chapters.first { $0.id == id }?[keyPath: keyPath] ?? ""
        } set: { value in
            if let index = model.chapters.firstIndex(where: { $0.id == id }) { model.chapters[index][keyPath: keyPath] = value }
        }
    }

    /// Nowy rozdział w połowie między tym a następnym (albo końcem książki).
    private func insert(after index: Int) {
        let start = model.chapters[index].start ?? 0
        let next = index + 1 < model.chapters.count ? (model.chapters[index + 1].start ?? model.duration) : model.duration
        let middle = ((start + next) / 2).rounded()
        model.chapters.insert(ChapterDraft(start: middle > start ? middle : start + 1, title: "Rozdział \(index + 2)"), at: index + 1)
    }

    private var lookup: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("ASIN", text: $asin, prompt: Text("ASIN z Audible"))
                    .frame(width: 160)
                    .accessibilityIdentifier("chapters.asin")
                Picker("Region", selection: $region) {
                    ForEach(Self.regions, id: \.self) { Text($0.uppercased()) }
                }
                .fixedSize()
                Toggle("Bez wstawek Audible", isOn: $removeBranding)
                    .help("Usuwa zapowiedź na początku i zakończenie Audible z czasów rozdziałów")
                Button("Znajdź rozdziały") { Task { await search() } }
                    .disabled(asin.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy)
                    .accessibilityIdentifier("chapters.lookup")
            }
            if let found {
                HStack {
                    Text("Znaleziono \(found.count) rozdziałów (do \(ChapterTime.format((found.last.map { ($0.startOffsetMs + $0.lengthMs) / 1000 }) ?? 0))). Zastąpią obecne w edycji — zapis dopiero po „Zapisz”.")
                        .font(.callout)
                    Button("Zastosuj") { apply(found) }.accessibilityIdentifier("chapters.applyLookup")
                    Button("Anuluj") { self.found = nil }
                }
            } else if let lookupNote {
                Text(lookupNote).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func search() async {
        found = nil
        lookupNote = nil
        let asin = asin.trimmingCharacters(in: .whitespaces).uppercased()
        let region = region
        await model.perform("Szukanie rozdziałów…", failure: "Nie udało się wyszukać rozdziałów") {
            let result = try await model.manager.run { try await $0.searchChapters(asin: asin, region: region, token: $1) }
            if let error = result.error {
                lookupNote = error == "Invalid ASIN" ? "Nieprawidłowy ASIN." : "Nie znaleziono rozdziałów dla tego ASIN w regionie \(region.uppercased())."
                return nil
            }
            var chapters = result.chapters ?? []
            if removeBranding { chapters = Self.withoutBranding(chapters, intro: result.brandIntroDurationMs ?? 0, outro: result.brandOutroDurationMs ?? 0) }
            if chapters.isEmpty { lookupNote = "Brak rozdziałów w odpowiedzi." } else { found = chapters }
            return nil
        }
    }

    /// Jak `removeBrandingFromData` w `chapters.vue`.
    static func withoutBranding(_ chapters: [AudiobookshelfClient.ChapterLookup.Chapter], intro: Double, outro: Double) -> [AudiobookshelfClient.ChapterLookup.Chapter] {
        var result = chapters.enumerated().map { index, chapter in
            AudiobookshelfClient.ChapterLookup.Chapter(
                title: chapter.title,
                startOffsetMs: chapter.startOffsetMs < intro ? Double(index * 1000) : chapter.startOffsetMs - intro,
                lengthMs: chapter.lengthMs
            )
        }
        if let last = result.last, last.lengthMs <= outro { result.removeLast() }
        return result
    }

    private func apply(_ chapters: [AudiobookshelfClient.ChapterLookup.Chapter]) {
        let duration = model.duration
        model.chapters = chapters
            .filter { duration <= 0 || $0.startOffsetMs / 1000 < duration }
            .map { ChapterDraft(start: $0.startOffsetMs / 1000, title: $0.title) }
        found = nil
    }
}
