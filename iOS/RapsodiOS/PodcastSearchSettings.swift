// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AudiobookshelfKit

/// Klucz Podcast Index tego telefonu (pęk kluczy, bez kopii zapasowej).
enum PodcastIndexKey {
    static var store: KeychainStore<PodcastIndexCredentials> {
        KeychainStore(service: "net.smigi.rapsod.ios.podcastindex", account: "default")
    }

    static func load() -> PodcastIndexCredentials? {
        (try? store.load()).flatMap { $0.isComplete ? $0 : nil }
    }
}

/// Ustawienia → Podcasty → „Wyszukiwanie podcastów”: katalogi i klucz Podcast Index.
struct PodcastSearchSettingsView: View {
    @State private var key = ""
    @State private var secret = ""
    @State private var saved: PodcastIndexCredentials?
    @State private var checking = false
    @State private var status: (ok: Bool, text: String)?

    var body: some View {
        Form {
            Section {
                LabeledContent("iTunes", value: "zawsze")
                LabeledContent("fyyd", value: "zawsze")
                LabeledContent("Podcast Index", value: saved == nil ? "wymaga klucza" : "włączony")
            } header: {
                Text("Katalogi")
            } footer: {
                Text("„Dodaj podcast” szuka we wszystkich naraz i pokazuje każdy kanał raz. fyyd jest mocniejszy w podcastach niemieckich i europejskich, Podcast Index ma najwięcej niezależnych podcastów spoza Apple.")
            }
            Section {
                TextField("Klucz API", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("podcastIndex.key")
                SecureField("Sekret API", text: $secret)
                    .accessibilityIdentifier("podcastIndex.secret")
                Button(saved == nil ? "Zapisz i sprawdź" : "Zapisz zmiany i sprawdź", action: save)
                    .disabled(!PodcastIndexCredentials(key: key, secret: secret).isComplete
                              || PodcastIndexCredentials(key: key, secret: secret) == saved || checking)
                if saved != nil {
                    Button("Sprawdź zapisany klucz", action: check).disabled(checking)
                    Button("Usuń klucz", role: .destructive, action: remove)
                }
                if checking {
                    Label { Text("Sprawdzanie…") } icon: { ProgressView() }.foregroundStyle(.secondary)
                } else if let status {
                    Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.ok ? .green : .orange)
                }
            } header: {
                Text("Podcast Index")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Darmowy klucz i sekret dostaniesz po założeniu konta na stronie Podcast Index (przyjdą mailem). Zostają tylko na tym telefonie, w pęku kluczy.")
                    Link("Załóż konto na api.podcastindex.org", destination: URL(string: "https://api.podcastindex.org/signup")!)
                }
            }
        }
        .navigationTitle("Wyszukiwanie podcastów")
        .navigationBarTitleDisplayMode(.inline)
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
                let results = try await PodcastDirectories.podcastIndex(term: "podcast", credentials: saved, max: 1)
                status = (true, results.isEmpty ? "Klucz działa." : "Klucz działa — Podcast Index odpowiada.")
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
