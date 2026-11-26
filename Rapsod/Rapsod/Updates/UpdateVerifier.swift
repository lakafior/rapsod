import CryptoKit
import Foundation
import RapsodUpdates
import Security

/// Błąd aktualizacji z komunikatem dla użytkownika.
struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Sprawdzenia pobranej wersji (etap 14b). Wszystkie muszą przejść, inaczej instalacji nie ma:
/// suma SHA-256 z wydania, podpis obrazu dysku i aplikacji certyfikatem Developer ID tego samego
/// zespołu co uruchomiona aplikacja, ocena Gatekeepera (notaryzacja) i wersja w samym pakiecie.
enum UpdateVerifier {
    // MARK: Podpis uruchomionej aplikacji

    /// Team ID z podpisu działającej aplikacji; `nil` dla buildu bez podpisu albo podpisanego ad hoc.
    static func runningTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Wymaganie jak wyznaczone w podpisie wydania (`codesign -d -r-`): ten identyfikator,
    /// łańcuch Apple, certyfikat pośredni Developer ID, liść „Developer ID Application” i zespół.
    static func appRequirement(bundleID: String, teamID: String) -> String {
        "identifier \"\(bundleID)\" and " + developerIDRequirement(teamID: teamID)
    }

    /// To samo bez identyfikatora — dla obrazu dysku, którego identyfikator nadaje `codesign`.
    static func developerIDRequirement(teamID: String) -> String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Ważność podpisu (ściśle, z kodem zagnieżdżonym) i spełnienie wymagania.
    static func checkSignature(of url: URL, requirement text: String, nested: Bool) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError(String(localized: "Nie udało się odczytać podpisu „\(url.lastPathComponent)”."))
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError(String(localized: "Wewnętrzny błąd wymagania podpisu."))
        }
        var flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        if nested { flags.insert(SecCSFlags(rawValue: kSecCSCheckNestedCode)) }
        var errors: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(staticCode, flags, requirement, &errors)
        guard status == errSecSuccess else {
            let detail = errors?.takeRetainedValue().localizedDescription ?? SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
            throw UpdateError(String(localized: "Podpis „\(url.lastPathComponent)” nie jest podpisem Developer ID wydawcy Rapsodu: \(detail)"))
        }
    }

    // MARK: Gatekeeper

    /// Ocena Gatekeepera dla aplikacji — przechodzi tylko podpis Developer ID z notaryzacją.
    static func assessApp(_ url: URL) async throws {
        let result = try await run("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=2", url.path])
        guard result.status == 0 else {
            throw UpdateError(String(localized: "Gatekeeper odrzucił nową wersję (brak notaryzacji?): \(verdict(result.output))"))
        }
    }

    /// Ocena Gatekeepera dla obrazu dysku (tak jak w `scripts/release.sh`).
    static func assessDiskImage(_ url: URL) async throws {
        let result = try await run("/usr/sbin/spctl", ["--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", url.path])
        guard result.status == 0 else {
            throw UpdateError(String(localized: "Gatekeeper odrzucił obraz dysku (brak notaryzacji?): \(verdict(result.output))"))
        }
    }

    /// Z wyjścia `spctl` tylko werdykt („rejected”, „source=Unnotarized Developer ID”), bez ścieżki pliku.
    private static func verdict(_ output: String) -> String {
        output.split(whereSeparator: \.isNewline)
            .map { line in line.split(separator: ": ").last.map(String.init) ?? String(line) }
            .joined(separator: ", ")
    }

    // MARK: Suma kontrolna

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Obraz dysku

    /// Montuje obraz tylko do odczytu, bez okna Findera, w podanym (pustym) folderze.
    static func mount(_ image: URL, at mountPoint: URL) async throws {
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let result = try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path, image.path])
        guard result.status == 0 else {
            throw UpdateError(String(localized: "Nie udało się zamontować obrazu dysku: \(result.output)"))
        }
    }

    static func detach(_ mountPoint: URL) async {
        let result = try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path])
        if result?.status != 0 {
            _ = try? await run("/usr/bin/hdiutil", ["detach", "-force", mountPoint.path])
        }
        try? FileManager.default.removeItem(at: mountPoint)
    }

    /// Kopia pakietu z zachowaniem podpisu, atrybutów i dowiązań (jak przy przeciąganiu w Finderze).
    static func copyBundle(from source: URL, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        let result = try await run("/usr/bin/ditto", [source.path, destination.path])
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw UpdateError(String(localized: "Nie udało się skopiować nowej wersji: \(result.output)"))
        }
    }

    // MARK: Procesy

    struct ProcessResult {
        let status: Int32
        let output: String
    }

    static func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return ProcessResult(status: process.terminationStatus, output: output)
        }.value
    }
}

/// Czy aplikację da się podmienić w miejscu, z którego działa.
enum InstallLocation {
    /// Opis przeszkody albo `nil`, gdy podmiana jest możliwa.
    static func problem(for app: URL) -> String? {
        if app.path.contains("/AppTranslocation/") {
            return String(localized: "Rapsod działa z tymczasowej kopii, którą macOS tworzy dla aplikacji uruchomionych prosto z pobranego pliku. Przenieś Rapsod do folderu Aplikacje, uruchom go stamtąd i spróbuj ponownie.")
        }
        let folder = app.deletingLastPathComponent()
        if let values = try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey]), values.volumeIsReadOnly == true {
            return String(localized: "Rapsod działa z obrazu dysku albo woluminu tylko do odczytu. Przeciągnij aplikację do folderu Aplikacje, uruchom ją stamtąd i spróbuj ponownie.")
        }
        if !FileManager.default.isWritableFile(atPath: folder.path) {
            return String(localized: "Brak prawa zapisu do folderu „\(folder.path)”, więc Rapsod nie może się sam podmienić. Zaloguj się na konto administratora albo pobierz nową wersję ze strony wydania i przeciągnij ją do folderu Aplikacje.")
        }
        return nil
    }
}
