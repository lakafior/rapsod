// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Odpowiedź `GET /repos/{owner}/{repo}/releases/latest` API GitHuba — tylko pola,
/// których używa aktualizacja.
public struct GitHubRelease: Decodable, Sendable, Equatable {
    public struct Asset: Decodable, Sendable, Equatable {
        public let name: String
        public let downloadURL: URL
        public let size: Int

        public init(name: String, downloadURL: URL, size: Int) {
            self.name = name
            self.downloadURL = downloadURL
            self.size = size
        }

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
            case size
        }
    }

    public let tagName: String
    public let name: String?
    public let body: String?
    public let pageURL: URL?
    public let isDraft: Bool
    public let isPrerelease: Bool
    public let publishedAt: Date?
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case pageURL = "html_url"
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case publishedAt = "published_at"
        case assets
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        pageURL = try? container.decodeIfPresent(URL.self, forKey: .pageURL)
        isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        isPrerelease = try container.decodeIfPresent(Bool.self, forKey: .isPrerelease) ?? false
        if let text = try container.decodeIfPresent(String.self, forKey: .publishedAt) {
            publishedAt = try? Date(text, strategy: .iso8601)
        } else {
            publishedAt = nil
        }
        assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }

    public static func decode(_ data: Data) throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}

/// Wydanie gotowe do zaproponowania: wersja ze znacznika, opis zmian (Markdown),
/// obraz dysku i plik z jego sumą SHA-256.
///
/// Umowa z `scripts/release.sh --publish`: znacznik `v<wersja>`, zasób `Rapsod-<wersja>.dmg`
/// i obok `Rapsod-<wersja>.dmg.sha256` (wiersz w formacie `shasum -a 256`).
public struct AppUpdate: Sendable, Equatable {
    public let version: AppVersion
    public let title: String
    public let notes: String
    public let pageURL: URL?
    public let publishedAt: Date?
    public let diskImage: GitHubRelease.Asset
    public let checksum: GitHubRelease.Asset

    public enum Problem: Error, Equatable, Sendable {
        case draftOrPrerelease
        case invalidTag(String)
        case missingDiskImage
        case ambiguousDiskImage([String])
        case missingChecksum(String)
    }

    /// Dopisek pliku z `release.sh --skip-notarize`: taki obraz nigdy nie jest aktualizacją.
    public static let unnotarizedMarker = "nienotaryzowany"

    public init(release: GitHubRelease, appName: String = "Rapsod") throws(Problem) {
        guard !release.isDraft, !release.isPrerelease else { throw .draftOrPrerelease }
        guard let version = AppVersion(release.tagName), !version.isPrerelease else { throw .invalidTag(release.tagName) }

        let images = release.assets.filter {
            $0.name.hasPrefix("\(appName)-") && $0.name.lowercased().hasSuffix(".dmg")
                && !$0.name.contains(Self.unnotarizedMarker)
        }
        let image: GitHubRelease.Asset
        if let exact = images.first(where: { $0.name == "\(appName)-\(version.string).dmg" }) {
            image = exact
        } else if images.count == 1 {
            image = images[0]
        } else if images.isEmpty {
            throw .missingDiskImage
        } else {
            throw .ambiguousDiskImage(images.map(\.name))
        }

        let checksumNames = ["\(image.name).sha256", "SHA256SUMS", "SHA256SUMS.txt"]
        guard let checksum = checksumNames.lazy.compactMap({ name in release.assets.first { $0.name == name } }).first else {
            throw .missingChecksum(image.name)
        }

        self.version = version
        let trimmedName = release.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = trimmedName.isEmpty ? "\(appName) \(version.string)" : trimmedName
        notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        pageURL = release.pageURL
        publishedAt = release.publishedAt
        diskImage = image
        self.checksum = checksum
    }
}

/// Plik sum kontrolnych w formacie `shasum -a 256` / `sha256sum`: wiersze
/// „<64 znaki hex><spacje>[*]<nazwa>”. Pojedyncza suma bez nazwy też się liczy.
public enum ChecksumFile {
    /// Suma (małymi literami) dla pliku o podanej nazwie albo `nil`, gdy jej nie ma.
    public static func sha256(for fileName: String, in text: String) -> String? {
        var unnamed: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let hash = String(line.prefix(while: { !$0.isWhitespace }))
            guard isSHA256(hash) else { continue }
            var name = line.dropFirst(hash.count).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            if name.isEmpty {
                unnamed.append(hash.lowercased())
            } else if (name as NSString).lastPathComponent == fileName {
                return hash.lowercased()
            }
        }
        return unnamed.count == 1 ? unnamed[0] : nil
    }

    public static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy(\.isHexDigit)
    }
}

/// Kiedy sprawdzać i kiedy pokazywać okno aktualizacji.
public enum UpdatePolicy {
    public static let checkInterval: TimeInterval = 24 * 60 * 60
    /// „Przypomnij później” — następne automatyczne okno najwcześniej po tym czasie.
    public static let remindInterval: TimeInterval = 24 * 60 * 60

    /// Czy przyszła pora na automatyczne sprawdzenie.
    public static func isCheckDue(lastCheck: Date?, now: Date, interval: TimeInterval = checkInterval) -> Bool {
        guard let lastCheck else { return true }
        // Zegar cofnięty w przeszłość: lepiej sprawdzić niż czekać do daty z przyszłości.
        if lastCheck > now { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    public enum Verdict: Equatable, Sendable {
        /// Nowa wersja do pokazania.
        case present
        /// Nowa wersja, ale użytkownik ją pominął albo kazał przypomnieć później.
        case quiet
        /// Nie nowsza niż uruchomiona.
        case upToDate
    }

    /// Ręczne sprawdzenie zawsze pokazuje nowszą wersję, także pominiętą;
    /// automatyczne szanuje „Pomiń tę wersję” i „Przypomnij później”.
    public static func verdict(
        for update: AppVersion,
        current: AppVersion,
        userInitiated: Bool,
        skippedVersion: String?,
        remindAfter: Date?,
        now: Date
    ) -> Verdict {
        guard update > current else { return .upToDate }
        if userInitiated { return .present }
        if let skippedVersion, let skipped = AppVersion(skippedVersion), skipped == update { return .quiet }
        if let remindAfter, now < remindAfter { return .quiet }
        return .present
    }
}
