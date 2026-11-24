// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 11d).

#if DEBUG
import AVFoundation
import AudiobookshelfKit
import AudiobookshelfPlayback
import SwiftUI

/// Tryb pokazowy tekstu — tylko Debug, do nagrań i pomiarów ruchu bez serwera i parowania.
/// Prawdziwy odtwarzacz z plikami z dysku i mapa `*.sync.json` z „Synchronizuj e-book” na Macu:
///
///     xcrun simctl launch booted net.smigi.rapsod.ios -BookTextDemo /ścieżka/do/folderu \
///         [-BookTextDemoStart 1790] [-BookTextDemoRate 2] [-BookTextDemoScript /ścieżka/skrypt.txt]
///
/// Folder: pliki audio (`*.m4a`, kolejno według nazwy) i jedna mapa `*.sync.json`. Skrypt: wiersze
/// `sekunda polecenie [wartość]` liczone od startu — `seek 1234.5`, `skip 30`, `rate 2`, `pause`,
/// `play`, `chapter` (następny), `resume` (Wróć do bieżącego miejsca).
enum BookTextDemo {
    static var folder: URL? {
        UserDefaults.standard.string(forKey: "BookTextDemo").map { URL(filePath: $0, directoryHint: .isDirectory) }
    }
}

struct BookTextDemoView: View {
    let folder: URL
    @State private var player = AudiobookPlayer()
    @State private var text = TextFollowModel()
    @State private var status = "Wczytywanie…"

    var body: some View {
        VStack(spacing: 0) {
            Text(status).font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            BookTextView(model: text, player: player, bottomInset: 8)
                .mask(LinearGradient(stops: [
                    .init(color: .clear, location: 0), .init(color: .black, location: 0.07),
                    .init(color: .black, location: 0.9), .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom))
                .frame(maxHeight: .infinity)
            HStack(spacing: 28) {
                Button("−15", systemImage: "gobackward.15") { player.skip(by: -15) }
                Button(player.isPlaying ? "Pauza" : "Graj", systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.togglePlayPause() }
                    .font(.title)
                Button("+30", systemImage: "goforward.30") { player.skip(by: 30) }
                Button("\(player.rate, format: .number)×") {
                    let rates = AudiobookPlayer.rates
                    player.rate = rates[((rates.firstIndex(of: player.rate) ?? 0) + 1) % rates.count]
                }
                .monospacedDigit()
            }
            .labelStyle(.iconOnly)
            .padding(.vertical, 14)
        }
        .background { TextTimeFeed(model: text, player: player) }
        .background(Color(white: 0.09).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await start() }
    }

    private func start() async {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let audio = files.filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let mapURL = files.first(where: { $0.lastPathComponent.hasSuffix(TextSyncMap.fileSuffix) }),
              let data = try? Data(contentsOf: mapURL),
              let map = try? TextSyncMap.decode(data) else {
            status = "Brak mapy w \(folder.path)"
            return
        }
        var tracks: [PlaybackTrack] = [], chapters: [PlaybackChapter] = []
        var offset = 0.0
        for (index, url) in audio.enumerated() {
            let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            tracks.append(PlaybackTrack(startOffset: offset, duration: duration, title: url.lastPathComponent, source: .file(url)))
            chapters.append(PlaybackChapter(id: index, start: offset, end: offset + duration, title: url.deletingPathExtension().lastPathComponent))
            offset += duration
        }
        let book = PlaybackBook(itemID: "demo", episodeID: nil, title: folder.lastPathComponent, author: nil, duration: offset, tracks: tracks, chapters: chapters)
        player.assetProvider = { track, _ in
            guard case .file(let url) = track.source else { throw CancellationError() }
            return AVURLAsset(url: url)
        }
        let defaults = UserDefaults.standard
        if defaults.double(forKey: "BookTextDemoRate") > 0 { player.rate = Float(defaults.double(forKey: "BookTextDemoRate")) }
        text.apply(.ready(TextSyncDocument(map: map), isStale: false, isOffline: false))
        player.start(book, at: defaults.double(forKey: "BookTextDemoStart"), autoplay: true)
        status = "\(map.sentences.count) zdań, \(audio.count) plików"
        if let script = defaults.string(forKey: "BookTextDemoScript") { await run(script: script) }
    }

    /// Elementy VoiceOver tekstu (etykieta, cechy, ramka) — do sprawdzenia bez Accessibility Inspectora.
    static func dumpAccessibility() {
        func find(_ view: UIView) -> TextCanvasContentView? {
            if let view = view as? TextCanvasContentView { return view }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let content = windows.lazy.compactMap({ find($0) }).first else { print("A11Y brak widoku"); return }
        let elements = content.accessibilityElements as? [UIAccessibilityElement] ?? []
        print("A11Y elementów: \(elements.count), zaznaczonych: \(elements.filter { $0.accessibilityTraits.contains(.selected) }.count), nagłówków: \(elements.filter { $0.accessibilityTraits.contains(.header) }.count)")
        for element in elements.prefix(12) {
            print("A11Y [\(element.accessibilityTraits.contains(.selected) ? "zaznaczone " : "")\(element.accessibilityTraits.contains(.header) ? "nagłówek " : "")przycisk] \(element.accessibilityLabel ?? "-") | \(element.accessibilityHint ?? "") | \(element.accessibilityFrameInContainerSpace)")
        }
    }

    /// Polecenia o ustalonych porach — powtarzalne nagrania przed i po zmianie.
    private func run(script path: String) async {
        guard let lines = try? String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") else { return }
        let begin = ContinuousClock.now
        for line in lines {
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count >= 2, let at = Double(parts[0]) else { continue }
            try? await Task.sleep(until: begin + .seconds(at))
            let value = parts.count > 2 ? Double(parts[2]) ?? 0 : 0
            switch parts[1] {
            case "seek": player.seek(to: value)
            case "skip": player.skip(by: value)
            case "rate": player.rate = Float(value)
            case "pause": player.pause()
            case "play": player.play()
            case "chapter": player.nextChapter()
            case "resume": text.resumeFollowing()
            case "a11y": Self.dumpAccessibility()
            default: break
            }
        }
    }
}
#endif
