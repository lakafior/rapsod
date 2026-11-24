import SwiftUI

/// „O programie”: wersje, licencja aplikacji i lista dołączonych komponentów.
struct AboutWindow: View {
    static let windowID = "about"

    let supervisor: ServerSupervisor
    /// Treść THIRD-PARTY-NOTICES.txt, wczytana raz po otwarciu okna (nie przy każdym `body`).
    @State private var notices = ""

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    /// Adres repozytorium ze źródłami (klucz `ABSSourceURL` w Info.plist); pusty, dopóki
    /// repozytorium nie jest publiczne.
    private var sourceURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "ABSSourceURL") as? String, !text.isEmpty else { return nil }
        return URL(string: text)
    }

    private static func loadNotices() -> String {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rapsod")
                .font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Wersja aplikacji").foregroundStyle(.secondary)
                    Text(appVersion)
                }
                GridRow {
                    Text("Wersja audiobookshelf").foregroundStyle(.secondary)
                    Text(supervisor.environment?.serverVersion ?? "—")
                }
            }
            .textSelection(.enabled)

            ScrollView {
                Text(notices)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 320)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))

            HStack {
                if let licenses = ServerEnvironment.licensesDirectory() {
                    Button("Pokaż teksty licencji") { NSWorkspace.shared.open(licenses) }
                }
                if let sourceURL {
                    Link("Kod źródłowy", destination: sourceURL)
                }
                Spacer()
                Link("audiobookshelf.org", destination: URL(string: "https://www.audiobookshelf.org")!)
            }
        }
        .padding(20)
        .frame(width: 640)
        .task {
            notices = Self.loadNotices()
        }
    }
}
