import SwiftUI

/// Wiersze sekcji „Źródła metadanych” w oknie statusu: przełącznik, stan,
/// przyciski stron konfiguracji i wyszukiwarki, log.
struct MetadataSourcesSection: View {
    let sources: MetadataSourcesController

    @State private var showsLog = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("Polskie źródła metadanych", isOn: Binding(
            get: { sources.isEnabled },
            set: { enabled in Task { await sources.setEnabled(enabled) } }
        ))
        .disabled(sources.isBusy)

        Text("LubimyCzytać, Audioteka, Storytel i Audible jako jedno źródło w oknie dopasowywania książki w audiobookshelf. Aplikacja dodaje je do serwera sama. Działają tylko wtedy, gdy serwer o nie pyta — w spoczynku nie zajmują pamięci.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if sources.isEnabled {
            LabeledContent("Stan") {
                Label(sources.state.title, systemImage: sources.state.symbolName)
                    .foregroundStyle(sources.state.tint)
            }
            if let detail = sources.state.detail {
                Text(detail)
                    .foregroundStyle(sources.state.tint)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            LabeledContent("W audiobookshelf") {
                Text(sources.registration.title)
                    .foregroundStyle(sources.registration.tint)
            }
            if case .failed(let message) = sources.registration {
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                if sources.state.canRetry {
                    Button("Spróbuj ponownie") { Task { await sources.retry() } }
                }
                Button("Konfiguracja…") { open(.configuration) }
                    .disabled(!sources.state.canOpenPages)
                Button("Wyszukiwarka…") { open(.search) }
                    .disabled(!sources.state.canOpenPages)
            }
            if !sources.recentLog.isEmpty {
                DisclosureGroup("Log źródeł", isExpanded: $showsLog) {
                    VStack(alignment: .trailing) {
                        ScrollView([.vertical, .horizontal]) {
                            Text(sources.recentLog.suffix(120).joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .fixedSize()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 160)
                        Button("Kopiuj log źródeł") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(sources.recentLog.joined(separator: "\n"), forType: .string)
                        }
                    }
                }
            }
        }
    }

    private func open(_ page: MetadataSourcesController.Page) {
        sources.page = page
        openWindow.bringToFront(id: MetadataSourcesWindow.windowID)
    }
}

extension MetadataSourcesController.State {
    var title: String {
        switch self {
        case .disabled: "Wyłączone"
        case .unavailable: "Niedostępne"
        case .sleeping: "Uśpione"
        case .starting: "Uruchamianie…"
        case .running: "Działa"
        case .failed: "Błąd"
        }
    }

    var detail: String? {
        switch self {
        case .unavailable(let reason), .failed(let reason): reason
        case .sleeping: "Uruchomią się przy pierwszym zapytaniu z audiobookshelf."
        default: nil
        }
    }

    var symbolName: String {
        switch self {
        case .running: "checkmark.circle.fill"
        case .starting: "arrow.triangle.2.circlepath"
        case .sleeping: "moon.zzz"
        case .failed, .unavailable: "exclamationmark.triangle.fill"
        case .disabled: "circle"
        }
    }

    var tint: Color {
        switch self {
        case .running: .green
        case .starting: .orange
        case .failed, .unavailable: .red
        case .sleeping, .disabled: .secondary
        }
    }

    var canRetry: Bool {
        switch self {
        case .failed, .unavailable: true
        default: false
        }
    }

    /// Strony agregatora da się otworzyć, gdy aplikacja nasłuchuje (agregator obudzi się sam).
    var canOpenPages: Bool {
        switch self {
        case .sleeping, .starting, .running: true
        case .disabled, .unavailable, .failed: false
        }
    }
}

extension MetadataSourcesController.Registration {
    var title: String {
        switch self {
        case .none: "—"
        case .waitingForServer: "Czeka na serwer"
        case .registered: "Dodane jako „\(MetadataSourcesController.providerName)”"
        case .failed: "Nie udało się dodać"
        }
    }

    var tint: Color {
        switch self {
        case .registered: .primary
        case .failed: .red
        case .none, .waitingForServer: .secondary
        }
    }
}
