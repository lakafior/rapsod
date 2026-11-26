// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
import RapsodUpdates

/// Aktualizacje aplikacji na Maca (etap 14b): wersje, odpowiedź GitHuba, wybór zasobu, polityka okna.
@Suite struct AppVersionTests {
    @Test func parsesTagsAndPlainVersions() throws {
        #expect(AppVersion("v1.2.3")?.components == [1, 2, 3])
        #expect(AppVersion("1.0")?.string == "1.0")
        #expect(AppVersion(" V2.0.1 ")?.string == "2.0.1")
        #expect(AppVersion("1.3.0+57")?.string == "1.3.0")
        let beta = try #require(AppVersion("v1.3.0-beta1"))
        #expect(beta.isPrerelease)
        #expect(beta.string == "1.3.0")
    }

    @Test func rejectsGarbage() {
        for text in ["", "v", "latest", "1..2", "1.2.x", "1.2.3.4.5", "-1.0", "1.0 beta", "１.０"] {
            #expect(AppVersion(text) == nil, "\(text)")
        }
    }

    @Test func comparesNumerically() throws {
        func v(_ text: String) throws -> AppVersion { try #require(AppVersion(text)) }
        #expect(try v("1.10.0") > v("1.9.9"))
        #expect(try v("2.0") > v("1.99.99"))
        #expect(try v("1.0.1") > v("1.0"))
        #expect(try v("1.2") == v("1.2.0"))
        #expect(try Set([v("1.2"), v("1.2.0")]).count == 1)
        #expect(try !(v("1.0.0") < v("1.0.0")))
    }
}

@Suite struct AppUpdateTests {
    private func release(
        tag: String = "v1.1.0",
        draft: Bool = false,
        prerelease: Bool = false,
        assets: [String] = ["Rapsod-1.1.0.dmg", "Rapsod-1.1.0.dmg.sha256"]
    ) throws -> GitHubRelease {
        let list = assets.map { name in
            #"{"name": "\#(name)", "browser_download_url": "https://github.com/lakafior/rapsod/releases/download/\#(tag)/\#(name)", "size": 42000000, "content_type": "application/octet-stream"}"#
        }
        let json = """
        {
          "url": "https://api.github.com/repos/lakafior/rapsod/releases/1",
          "html_url": "https://github.com/lakafior/rapsod/releases/tag/\(tag)",
          "tag_name": "\(tag)",
          "name": "Rapsod 1.1.0",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "published_at": "2026-11-26T10:00:00Z",
          "body": "## Zmiany\\n\\n- Automatyczne aktualizacje\\n",
          "author": {"login": "lakafior"},
          "assets": [\(list.joined(separator: ","))]
        }
        """
        return try GitHubRelease.decode(Data(json.utf8))
    }

    @Test func decodesGitHubResponse() throws {
        let release = try release()
        #expect(release.tagName == "v1.1.0")
        #expect(release.pageURL?.absoluteString == "https://github.com/lakafior/rapsod/releases/tag/v1.1.0")
        #expect(release.publishedAt == Date(timeIntervalSince1970: 1_795_687_200))
        #expect(release.assets.count == 2)
        #expect(release.assets[0].size == 42_000_000)
    }

    @Test func picksDiskImageAndChecksum() throws {
        let update = try AppUpdate(release: release())
        #expect(update.version.string == "1.1.0")
        #expect(update.title == "Rapsod 1.1.0")
        #expect(update.notes == "## Zmiany\n\n- Automatyczne aktualizacje")
        #expect(update.diskImage.name == "Rapsod-1.1.0.dmg")
        #expect(update.checksum.name == "Rapsod-1.1.0.dmg.sha256")
    }

    @Test func neverPicksUnnotarizedImage() throws {
        let assets = ["Rapsod-1.1.0-nienotaryzowany.dmg", "Rapsod-1.1.0-nienotaryzowany.dmg.sha256"]
        #expect(throws: AppUpdate.Problem.missingDiskImage) { try AppUpdate(release: release(assets: assets)) }
        // Obok właściwego obrazu taki plik jest pomijany, a nie „niejednoznaczny”.
        let mixed = assets + ["Rapsod-1.1.0.dmg", "Rapsod-1.1.0.dmg.sha256"]
        #expect(try AppUpdate(release: release(assets: mixed)).diskImage.name == "Rapsod-1.1.0.dmg")
    }

    @Test func prefersExactNameAndRejectsAmbiguity() throws {
        let exact = ["Rapsod-1.0.9.dmg", "Rapsod-1.1.0.dmg", "Rapsod-1.1.0.dmg.sha256"]
        #expect(try AppUpdate(release: release(assets: exact)).diskImage.name == "Rapsod-1.1.0.dmg")
        let ambiguous = ["Rapsod-a.dmg", "Rapsod-b.dmg", "SHA256SUMS"]
        #expect(throws: AppUpdate.Problem.ambiguousDiskImage(["Rapsod-a.dmg", "Rapsod-b.dmg"])) {
            try AppUpdate(release: release(assets: ambiguous))
        }
        let single = ["Rapsod-1.1.0-arm64.dmg", "SHA256SUMS"]
        let update = try AppUpdate(release: release(assets: single))
        #expect(update.diskImage.name == "Rapsod-1.1.0-arm64.dmg")
        #expect(update.checksum.name == "SHA256SUMS")
    }

    @Test func requiresChecksum() throws {
        #expect(throws: AppUpdate.Problem.missingChecksum("Rapsod-1.1.0.dmg")) {
            try AppUpdate(release: release(assets: ["Rapsod-1.1.0.dmg"]))
        }
        #expect(throws: AppUpdate.Problem.missingDiskImage) {
            try AppUpdate(release: release(assets: ["Rapsod-1.1.0.zip", "Inna-1.1.0.dmg"]))
        }
    }

    @Test func rejectsDraftsPrereleasesAndBadTags() throws {
        #expect(throws: AppUpdate.Problem.draftOrPrerelease) { try AppUpdate(release: release(draft: true)) }
        #expect(throws: AppUpdate.Problem.draftOrPrerelease) { try AppUpdate(release: release(prerelease: true)) }
        #expect(throws: AppUpdate.Problem.invalidTag("nightly")) { try AppUpdate(release: release(tag: "nightly")) }
        #expect(throws: AppUpdate.Problem.invalidTag("v1.2.0-rc1")) { try AppUpdate(release: release(tag: "v1.2.0-rc1")) }
    }
}

@Suite struct ChecksumFileTests {
    private let hash = "0f343b0931126a20f133d67c2b018a3b5fbb8e5d4e0b3f6a1c1a2b3c4d5e6f70"

    @Test func readsShasumOutput() {
        #expect(ChecksumFile.sha256(for: "Rapsod-1.1.0.dmg", in: "\(hash)  Rapsod-1.1.0.dmg\n") == hash)
        // Tryb binarny (`*`), wielkie litery i ścieżka w nazwie.
        let upper = hash.uppercased()
        #expect(ChecksumFile.sha256(for: "Rapsod-1.1.0.dmg", in: "\(upper) *build/release/Rapsod-1.1.0.dmg") == hash)
    }

    @Test func picksMatchingLineFromList() {
        let other = String(repeating: "a", count: 64)
        let text = "# sumy\n\(other)  Rapsod-1.0.0.dmg\n\(hash)  Rapsod-1.1.0.dmg\n"
        #expect(ChecksumFile.sha256(for: "Rapsod-1.1.0.dmg", in: text) == hash)
        #expect(ChecksumFile.sha256(for: "Rapsod-2.0.0.dmg", in: text) == nil)
    }

    @Test func acceptsSingleBareHashOnly() {
        #expect(ChecksumFile.sha256(for: "x.dmg", in: "\(hash)\n") == hash)
        #expect(ChecksumFile.sha256(for: "x.dmg", in: "\(hash)\n\(hash)\n") == nil)
        #expect(ChecksumFile.sha256(for: "x.dmg", in: "nie-suma  x.dmg") == nil)
        #expect(ChecksumFile.sha256(for: "x.dmg", in: "\(hash.dropLast())  x.dmg") == nil)
    }
}

@Suite struct UpdatePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let current = AppVersion("1.0.0")!
    private let newer = AppVersion("1.1.0")!

    @Test func checksOncePerDay() {
        #expect(UpdatePolicy.isCheckDue(lastCheck: nil, now: now))
        #expect(!UpdatePolicy.isCheckDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(UpdatePolicy.isCheckDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
        #expect(UpdatePolicy.isCheckDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }

    @Test func verdicts() {
        func verdict(_ update: AppVersion, user: Bool = false, skipped: String? = nil, remind: Date? = nil) -> UpdatePolicy.Verdict {
            UpdatePolicy.verdict(for: update, current: current, userInitiated: user, skippedVersion: skipped, remindAfter: remind, now: now)
        }
        #expect(verdict(AppVersion("1.0")!) == .upToDate)
        #expect(verdict(AppVersion("0.9")!, user: true) == .upToDate)
        #expect(verdict(newer) == .present)
        #expect(verdict(newer, skipped: "1.1.0") == .quiet)
        #expect(verdict(newer, skipped: "1.0.5") == .present)
        #expect(verdict(AppVersion("1.2.0")!, skipped: "1.1.0") == .present)
        #expect(verdict(newer, remind: now.addingTimeInterval(60)) == .quiet)
        #expect(verdict(newer, remind: now.addingTimeInterval(-60)) == .present)
        // Ręczne „Sprawdź aktualizacje…” pokazuje także pominiętą wersję.
        #expect(verdict(newer, user: true, skipped: "1.1.0", remind: now.addingTimeInterval(60)) == .present)
    }
}

@Suite struct SwapScriptTests {
    private func makeApp(_ url: URL, marker: String) throws {
        let contents = url.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: contents.appending(path: "marker"))
    }

    private func marker(_ app: URL) -> String? {
        try? String(contentsOf: app.appending(path: "Contents/marker"), encoding: .utf8)
    }

    /// Uruchamia skrypt jak aplikacja, ale bez `open` i dla procesu, który już się zakończył.
    private func run(app: URL, staged: URL, folder: URL) throws -> String {
        let finished = Process()
        finished.executableURL = URL(filePath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        let log = folder.appending(path: "swap.log")
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = SwapScript.arguments(pid: finished.processIdentifier, app: app, staged: staged, backup: SwapScript.backupURL(for: app), log: log)
        shell.environment = ["RAPSOD_SWAP_NO_RELAUNCH": "1", "PATH": "/usr/bin:/bin"]
        try shell.run()
        shell.waitUntilExit()
        return (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "swap-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func namesStayNextToApp() {
        let app = URL(filePath: "/Applications/Rapsod.app", directoryHint: .isDirectory)
        #expect(SwapScript.stagedURL(for: app).path == "/Applications/.Rapsod-aktualizacja.app")
        #expect(SwapScript.backupURL(for: app).path == "/Applications/.Rapsod-poprzednia.app")
    }

    @Test func swapsBundleAfterExit() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Spacja i apostrof w ścieżce: argumenty nie mogą się rozjechać.
        let app = folder.appending(path: "Moje aplikacje/Rap'sod.app", directoryHint: .isDirectory)
        let staged = SwapScript.stagedURL(for: app)
        try makeApp(app, marker: "stara")
        try makeApp(staged, marker: "nowa")

        let log = try run(app: app, staged: staged, folder: folder)
        #expect(marker(app) == "nowa", "\(log)")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(!FileManager.default.fileExists(atPath: SwapScript.backupURL(for: app).path))
        #expect(log.contains("podmiana: gotowe"))
    }

    @Test func relaunchArgumentsFollowLog() {
        let app = URL(filePath: "/A/Rapsod.app")
        let args = SwapScript.arguments(pid: 7, app: app, staged: URL(filePath: "/A/s.app"), backup: URL(filePath: "/A/b.app"), log: URL(filePath: "/l"), relaunchArguments: ["-ABSDataRoot", "/tmp/x y"])
        #expect(Array(args.suffix(7)) == ["7", "/A/Rapsod.app", "/A/s.app", "/A/b.app", "/l", "-ABSDataRoot", "/tmp/x y"])
        #expect(SwapScript.text.contains("shift 5"))
    }

    @Test func keepsOldAppWithoutStagedCopy() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appending(path: "Rapsod.app", directoryHint: .isDirectory)
        try makeApp(app, marker: "stara")

        let log = try run(app: app, staged: SwapScript.stagedURL(for: app), folder: folder)
        #expect(marker(app) == "stara")
        #expect(log.contains("brak kopii"))
    }
}
