import Charts
import SwiftUI

// MARK: - Statystyki słuchania

struct StatsView: View {
    let listening: ListeningController
    @State private var stats: AudiobookshelfClient.ListeningStats?
    @State private var error: String?

    var body: some View {
        Group {
            if let stats {
                ListeningStatsContent(stats: stats, finished: listening.progress.values.filter(\.isFinished).count)
            } else {
                LoadingState(error: error) { await load() }
            }
        }
        .navigationTitle("Statystyki")
        .task { await load() }
    }

    private func load() async {
        do {
            stats = try await listening.api { try await $0.listeningStats(token: $1) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Statystyki słuchania jednego konta: kafelki, ostatnie 30 dni, najdłużej słuchane i ostatnie sesje.
/// Wspólne dla „Twoje słuchanie” i Ustawień → Konta (etap 9i, `pages/config/users/_id/index.vue`).
struct ListeningStatsContent: View {
    let stats: AudiobookshelfClient.ListeningStats
    /// Liczba ukończonych — znana tylko dla własnego konta (postęp słuchacza).
    let finished: Int?

    private struct Day: Identifiable {
        let date: Date
        let minutes: Double
        var id: Date { date }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 16) {
                    StatTile(title: "Łącznie", value: Formats.duration(stats.totalTime))
                    StatTile(title: "Dzisiaj", value: Formats.duration(stats.today ?? 0))
                    StatTile(title: "Dni słuchania", value: "\(stats.days.values.filter { $0 > 0 }.count)")
                    if let finished { StatTile(title: "Ukończone", value: "\(finished)") }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ostatnie 30 dni").font(.title2.weight(.semibold))
                    Chart(lastDays) { day in
                        BarMark(x: .value("Dzień", day.date, unit: .day), y: .value("Minuty", day.minutes))
                    }
                    .chartYAxisLabel("min")
                    .environment(\.locale, Locale(identifier: "pl_PL"))
                    .frame(height: 180)
                }
                let top = stats.items.values.sorted { $0.timeListening > $1.timeListening }.prefix(10)
                if !top.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Najdłużej słuchane").font(.title2.weight(.semibold))
                        ForEach(Array(top)) { item in
                            HStack {
                                Text(item.mediaMetadata?.title ?? "—").lineLimit(1)
                                Text(item.mediaMetadata?.authorName ?? item.mediaMetadata?.author ?? "").foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Text(Formats.duration(item.timeListening)).monospacedDigit()
                            }
                            Divider()
                        }
                    }
                }
                if let sessions = stats.recentSessions?.elements, !sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Ostatnie sesje").font(.title2.weight(.semibold))
                        ForEach(sessions) { session in
                            HStack {
                                Text(session.displayTitle ?? "—").lineLimit(1)
                                Spacer()
                                if let date = Formats.date(ms: session.updatedAt) { Text(date).foregroundStyle(.secondary) }
                                Text(Formats.duration(session.timeListening)).monospacedDigit().frame(width: 110, alignment: .trailing)
                            }
                            Divider()
                        }
                    }
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(24)
        }
    }

    private var lastDays: [Day] {
        let calendar = Calendar.current
        // Klucze serwera „rrrr-MM-dd” w czasie lokalnym i kalendarzu gregoriańskim — bez tworzenia
        // `DateFormatter` przy każdym przebiegu `body`.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let today = calendar.startOfDay(for: .now)
        return (0..<30).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let day = gregorian.dateComponents([.year, .month, .day], from: date)
            let key = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
            return Day(date: date, minutes: (stats.days[key] ?? 0) / 60)
        }
    }
}
