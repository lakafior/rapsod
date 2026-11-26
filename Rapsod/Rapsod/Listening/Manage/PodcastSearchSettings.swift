// Pochodzenie: kod własny projektu.

import AudiobookshelfKit
import SwiftUI

/// Klucz Podcast Index tego Maca (pęk kluczy). Wspólny dla wszystkich folderów danych — to klucz
/// do zewnętrznego katalogu, nie do serwera.
enum PodcastIndexKey {
    static let store = CredentialStore<PodcastIndexCredentials>(
        service: "net.smigi.rapsod.podcastindex", account: "default", label: "Rapsod — klucz Podcast Index")

    static func load() -> PodcastIndexCredentials? {
        (try? store.load()).flatMap { $0.isComplete ? $0 : nil }
    }
}

/// Ustawienia → Biblioteki → „Wyszukiwanie podcastów”: katalogi i klucz Podcast Index.
struct PodcastSearchSettingsSection: View {
    @State private var key = ""
    @State private var secret = ""
    @State private var saved: PodcastIndexCredentials?
    @State private var checking = false
    @State private var status: (ok: Bool, text: String)?

    var body: some View {
        Section {
            Text("„Dodaj podcast” szuka naraz w iTunes, fyyd i — z kluczem — w Podcast Index, a każdy kanał pokazuje raz. fyyd jest mocniejszy w podcastach niemieckich i europejskich, Podcast Index ma najwięcej niezależnych podcastów spoza Apple.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Klucz API Podcast Index", text: $key)
                .accessibilityIdentifier("podcastIndex.key")
            SecureField("Sekret API", text: $secret)
                .accessibilityIdentifier("podcastIndex.secret")
            HStack {
                Link("Załóż darmowe konto…", destination: URL(string: "https://api.podcastindex.org/signup")!)
                    .font(.callout)
                Spacer()
                if checking {
                    ProgressView().controlSize(.small)
                } else if let status {
                    Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.ok ? .green : .orange)
                        .textSelection(.enabled)
                }
                if saved != nil {
                    Button("Usuń klucz", role: .destructive, action: remove)
                    Button("Sprawdź", action: check).disabled(checking)
                }
                Button("Zapisz", action: save)
                    .disabled(!PodcastIndexCredentials(key: key, secret: secret).isComplete
                              || PodcastIndexCredentials(key: key, secret: secret) == saved || checking)
            }
        } header: {
            Text("Wyszukiwanie podcastów")
        } footer: {
            Text("Klucz i sekret przychodzą mailem po założeniu konta. Zostają w pęku kluczy tego Maca; telefon ma własne ustawienie.")
        }
        .onAppear {
            saved = PodcastIndexKey.load()
            key = saved?.key ?? ""
            secret = saved?.secret ?? ""
        }
    }

    private func save() {
        let credentials = PodcastIndexCredentials(key: key, secret: secret)
        do {
            try PodcastIndexKey.store.save(credentials)
            saved = credentials
            check()
        } catch {
            status = (false, "Nie udało się zapisać klucza: \(error.localizedDescription)")
        }
    }

    private func check() {
        guard let saved else { return }
        checking = true
        status = nil
        Task {
            defer { checking = false }
            do {
                _ = try await PodcastDirectories.podcastIndex(term: "podcast", credentials: saved, max: 1)
                status = (true, "Klucz działa.")
            } catch {
                status = (false, error.localizedDescription)
            }
        }
    }

    private func remove() {
        try? PodcastIndexKey.store.delete()
        saved = nil
        key = ""
        secret = ""
        status = nil
    }
}
