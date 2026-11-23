import AppKit
import SwiftUI

// Wspólne elementy stron ustawień (etap 1 planu w `docs/ustawienia-nowy-uklad.md`, część 6).

// MARK: - Wiersz obiektu

/// Wiersz prowadzący do podstrony obiektu (root, w kolejnych etapach biblioteka): ikona, nazwa,
/// podpis, opcjonalny znak uwagi i strzałka. Klik w cały wiersz przechodzi dalej — jak w Ustawieniach
/// systemowych. Poza `Form` rysuje własne tło karty.
struct ObjectRow<Icon: View>: View {
    let destination: SettingsDestination
    let title: String
    var subtitle: String?
    var needsAttention = false
    @ViewBuilder var icon: Icon

    var body: some View {
        NavigationLink(value: destination) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(needsAttention ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if needsAttention {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(needsAttention ? "\(title), wymaga uwagi" : title)
        .accessibilityHint("Otwiera podstronę")
    }
}

// MARK: - Zaawansowane

/// Sekcja „Zaawansowane” na dole strony: zwinięta, z jednym zdaniem streszczenia, co jest w środku.
/// Zaawansowane to rzadkie ustawienia, nie gorsze — więc nic tu nie jest ukryte na stałe.
struct AdvancedSection<Content: View, Footer: View>: View {
    let summary: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    @State private var isExpanded = false

    init(summary: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.summary = summary
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                content
            } label: {
                // Cały nagłówek jest przyciskiem: klik w tekst też rozwija, a z klawiatury działa spacja.
                Button {
                    withAnimation { isExpanded.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Zaawansowane")
                        if !isExpanded {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zaawansowane")
                .accessibilityValue(isExpanded ? "rozwinięte" : "zwinięte")
                .accessibilityHint(summary)
            }
        } footer: {
            footer
        }
    }
}

/// Sam nagłówek „Zaawansowane” sterowany z zewnątrz — dla stron, na których po rozwinięciu
/// dochodzą całe sekcje (np. „Dostęp zdalny”), a ich modele mają powstać dopiero wtedy.
struct AdvancedHeader: View {
    let summary: String
    @Binding var isExpanded: Bool

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                EmptyView()
            } label: {
                Button {
                    withAnimation { isExpanded.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Zaawansowane")
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zaawansowane")
                .accessibilityValue(isExpanded ? "rozwinięte" : "zwinięte")
                .accessibilityHint(summary)
            }
        }
    }
}

// MARK: - Harmonogram

/// Wiersze harmonogramu (wyłączony, codziennie, co tydzień, własny cron z web UI) — wspólne dla
/// automatycznego skanu biblioteki i automatycznych kopii. Zapis zostaje po stronie wywołującego:
/// kopie mają „Zapisz/Cofnij”, podstrona biblioteki zapisuje zmianę sama.
struct ScheduleRows: View {
    @Binding var choice: BackupScheduleChoice
    /// Godzina proponowana przy przejściu z „Wyłączony” na codziennie albo co tydzień.
    var defaultTime: (hour: Int, minute: Int) = (3, 0)
    /// Harmonogram zapisany na serwerze — ponowny wybór „Własny” wraca do jego wyrażenia.
    var saved: BackupScheduleChoice = .disabled
    var customNote: String?

    private enum Mode: Hashable { case disabled, daily, weekly, custom }

    var body: some View {
        Picker("Harmonogram", selection: modeBinding) {
            Text("Wyłączony").tag(Mode.disabled)
            Text("Codziennie").tag(Mode.daily)
            Text("Co tydzień").tag(Mode.weekly)
            if case .custom = choice { Text("Własny (cron)").tag(Mode.custom) }
        }
        if case .weekly(let weekday, let hour, let minute) = choice {
            Picker("Dzień", selection: Binding(
                get: { weekday },
                set: { choice = .weekly(weekday: $0, hour: hour, minute: minute) }
            )) {
                ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { day in
                    Text(Self.weekdayName(day)).tag(day)
                }
            }
        }
        if let time = timeBinding {
            DatePicker("Godzina", selection: time, displayedComponents: .hourAndMinute)
        }
        if case .custom(let expression) = choice {
            LabeledContent("Wyrażenie cron", value: expression)
            if let customNote {
                Text(customNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var mode: Mode {
        switch choice {
        case .disabled: .disabled
        case .daily: .daily
        case .weekly: .weekly
        case .custom: .custom
        }
    }

    private var currentTime: (Int, Int)? {
        switch choice {
        case .daily(let hour, let minute), .weekly(_, let hour, let minute): (hour, minute)
        case .disabled, .custom: nil
        }
    }

    private var modeBinding: Binding<Mode> {
        Binding(get: { mode }, set: { newMode in
            let (hour, minute) = currentTime ?? (defaultTime.hour, defaultTime.minute)
            switch newMode {
            case .disabled: choice = .disabled
            case .daily: choice = .daily(hour: hour, minute: minute)
            case .weekly: choice = .weekly(weekday: 1, hour: hour, minute: minute)
            case .custom: if case .custom = saved { choice = saved }
            }
        })
    }

    private var timeBinding: Binding<Date>? {
        guard let (hour, minute) = currentTime else { return nil }
        return Binding(
            get: { Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                let hour = parts.hour ?? 0
                let minute = parts.minute ?? 0
                switch choice {
                case .daily: choice = .daily(hour: hour, minute: minute)
                case .weekly(let weekday, _, _): choice = .weekly(weekday: weekday, hour: hour, minute: minute)
                case .disabled, .custom: break
                }
            }
        )
    }

    static func weekdayName(_ cronDay: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "pl_PL")
        return calendar.standaloneWeekdaySymbols[cronDay % 7]
    }
}

// MARK: - Hasło

/// Wiersz hasła jak w menedżerach haseł: kropki, „Pokaż” (zakrywa się samo po minucie i przy
/// przejściu do innej aplikacji), „Kopiuj” i opcjonalnie „Zmień…”. Bez znanego hasła (serwer
/// haseł nie zwraca) zostaje sam przycisk „Zmień…”.
struct PasswordRow: View {
    var title = "Hasło"
    /// Hasło z pęku kluczy; `nil`, gdy aplikacja go nie zna.
    let password: String?
    var unknownText = "nieznane tej aplikacji"
    var change: (() -> Void)?

    @State private var isRevealed = false
    @State private var hideTask: Task<Void, Never>?

    private static let visibleFor: Duration = .seconds(60)

    var body: some View {
        LabeledContent(title) {
            HStack {
                if let password {
                    Text(isRevealed ? password : String(repeating: "•", count: 10))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // Bez własnej etykiety: w `LabeledContent` etykieta tekstu wskazywała na wiersz,
                        // a wiersz na tekst, i AppKit wpadał w nieskończoną rekurencję (awaria przy VoiceOver).
                        .accessibilityHidden(!isRevealed)
                    Button(isRevealed ? "Ukryj" : "Pokaż") { toggle() }
                        .accessibilityLabel(isRevealed ? "Ukryj hasło" : "Pokaż hasło")
                    Button("Kopiuj") { NSPasteboard.copy(password) }
                        .accessibilityLabel("Kopiuj hasło")
                } else {
                    Text(unknownText).foregroundStyle(.secondary)
                }
                if let change {
                    Button("Zmień…", action: change)
                        .accessibilityLabel("Zmień hasło…")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            hide()
        }
        .onDisappear { hide() }
    }

    private func toggle() {
        if isRevealed {
            hide()
            return
        }
        isRevealed = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled else { return }
            isRevealed = false
        }
    }

    private func hide() {
        isRevealed = false
        hideTask?.cancel()
    }
}

// MARK: - Wartość do skopiowania

/// Wiersz z wartością do przepisania i przyciskiem kopiowania.
struct CopyableRow<Accessory: View>: View {
    let title: String
    let value: String
    var shown: String?
    @ViewBuilder var accessory: Accessory

    init(title: String, value: String, shown: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.value = value
        self.shown = shown
        self.accessory = accessory()
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(shown ?? value)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                accessory
                Button("Kopiuj") { NSPasteboard.copy(value) }
            }
        }
    }
}

// MARK: - Baner

/// Baner na górze strony: krótki komunikat i jedna akcja, która prowadzi do miejsca,
/// gdzie sprawę się załatwia (zamiast kopii kontrolek z tamtego miejsca).
struct ActionBanner: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"
    var tint: Color = .orange
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(actionTitle, action: action)
        }
        .accessibilityElement(children: .contain)
    }
}
