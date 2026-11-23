import AppKit
import Observation
import OSLog
import SwiftUI

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Avatars")

/// Awatary osób (etap 2d planu, część 9 `docs/ustawienia-nowy-uklad.md`). Audiobookshelf nie ma
/// pola awatara, więc awatar żyje tylko na tym Macu: w folderze `avatars/` folderu danych serwera,
/// obok `sharing.json` (przenosi się razem z serwerem; testowa kopia z `-ABSDataRoot` ma własny).
/// Plik `<id-konta>.png` to zdjęcie, `<id-konta>.json` — symbol na kolorowym tle. Brak pliku
/// oznacza domyślny gradient z inicjałami. Kopia zapasowa audiobookshelf awatarów nie obejmuje,
/// a telefony ich nie widzą — mówi o tym arkusz wyboru.
@MainActor
@Observable
final class AvatarStore {
    enum Avatar: Equatable {
        case initials
        case symbol(String, color: Int)
        case photo(NSImage)
    }

    /// Pary kolorów gradientu; indeks jest zapisywany w pliku, więc kolejności nie zmieniać.
    static let palette: [[Color]] = [
        [.orange, .pink],
        [.teal, .blue],
        [.purple, .indigo],
        [.green, .teal],
        [.yellow, .orange],
        [.pink, .purple],
        [.blue, .indigo],
        [.red, .orange],
    ]

    static let symbols = ["🎧", "📚", "🦊", "🐱", "🐶", "🐻", "🦉", "🐢", "🌻", "🌙", "⭐️", "🎸", "☕️", "🚲", "⚽️", "🍀"]

    /// Rośnie przy każdej zmianie, żeby widoki przerysowały awatar.
    private(set) var revision = 0
    @ObservationIgnored private var cache: [String: Avatar] = [:]
    @ObservationIgnored private let folder: URL?

    init() {
        folder = (try? ServerEnvironment.resolveDataRoot())?.appending(path: "avatars", directoryHint: .isDirectory)
    }

    func avatar(for userID: String) -> Avatar {
        _ = revision
        if let cached = cache[userID] { return cached }
        let avatar = load(userID)
        cache[userID] = avatar
        return avatar
    }

    /// Domyślny kolor osoby — stały dla identyfikatora konta.
    static func defaultColor(for userID: String) -> Int {
        userID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palette.count
    }

    func setSymbol(_ symbol: String, color: Int, for userID: String) throws {
        let data = try JSONEncoder().encode(SymbolFile(symbol: symbol, color: color))
        try write(data, to: file(userID, "json"), removing: file(userID, "png"))
        update(userID, .symbol(symbol, color: color))
    }

    /// Zdjęcie: środek obrazu przycięty do kwadratu i zmniejszony do 256 px (koło rysuje widok).
    func setPhoto(from url: URL, for userID: String) throws {
        guard let image = NSImage(contentsOf: url), let png = Self.squarePNG(image, side: 256) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try write(png, to: file(userID, "png"), removing: file(userID, "json"))
        update(userID, NSImage(data: png).map(Avatar.photo) ?? .initials)
    }

    /// Przywraca inicjały (usuwa pliki awatara). Także po usunięciu konta.
    func reset(_ userID: String) {
        for url in [file(userID, "png"), file(userID, "json")].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        update(userID, .initials)
    }

    // MARK: - Pliki

    private struct SymbolFile: Codable {
        let symbol: String
        let color: Int
    }

    private func load(_ userID: String) -> Avatar {
        if let url = file(userID, "png"), let image = NSImage(contentsOf: url) {
            return .photo(image)
        }
        if let url = file(userID, "json"), let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(SymbolFile.self, from: data) {
            return .symbol(saved.symbol, color: saved.color)
        }
        return .initials
    }

    /// Plik awatara; identyfikator konta trafia do nazwy pliku tylko z bezpiecznych znaków.
    private func file(_ userID: String, _ ext: String) -> URL? {
        let safe = String(userID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
        guard let folder, !safe.isEmpty else { return nil }
        return folder.appending(path: "\(safe).\(ext)")
    }

    private func write(_ data: Data, to url: URL?, removing other: URL?) throws {
        guard let url, let folder else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if let other { try? FileManager.default.removeItem(at: other) }
        logger.notice("Zapisano awatar")
    }

    private func update(_ userID: String, _ avatar: Avatar) {
        cache[userID] = avatar
        revision += 1
    }

    private static func squarePNG(_ image: NSImage, side: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let edge = min(cg.width, cg.height)
        let crop = CGRect(x: (cg.width - edge) / 2, y: (cg.height - edge) / 2, width: edge, height: edge)
        guard let square = cg.cropping(to: crop) else { return nil }
        let pixels = Int(side)
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }
}

/// Okrągły awatar osoby: zdjęcie, symbol na kolorze albo gradient z inicjałami.
struct AvatarView: View {
    let store: AvatarStore
    let userID: String
    let name: String
    var size: CGFloat = 96
    var isMacAccount = false
    var isInactive = false

    var body: some View {
        ZStack {
            switch store.avatar(for: userID) {
            case .photo(let image):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            case .symbol(let symbol, let color):
                Circle().fill(gradient(color))
                Text(symbol).font(.system(size: size * 0.48))
            case .initials:
                Circle().fill(gradient(AvatarStore.defaultColor(for: userID)))
                Text(Self.initials(name))
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .opacity(isInactive ? 0.45 : 1)
        .overlay(alignment: .bottomTrailing) {
            if isMacAccount {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: size * 0.15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(size * 0.07)
                    .background(Circle().fill(Color.accentColor))
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 3))
            }
        }
        .accessibilityHidden(true)
    }

    private func gradient(_ index: Int) -> LinearGradient {
        let colors = AvatarStore.palette[((index % AvatarStore.palette.count) + AvatarStore.palette.count) % AvatarStore.palette.count]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Do dwóch pierwszych liter członów nazwy („babcia.ela” → „BE”, „tomek” → „T”).
    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { " ._-".contains($0) })
        let letters = parts.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}
