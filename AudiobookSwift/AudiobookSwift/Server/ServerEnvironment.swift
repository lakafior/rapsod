import Foundation

/// Jedyne miejsce, które wie, skąd biorą się Node, ffmpeg, kod serwera i jego dane.
///
/// Na razie Node i serwer pochodzą z katalogu `build/` repozytorium (tworzy go
/// `scripts/build-server.sh`), a ffmpeg/ffprobe z Homebrew. W etapie 6 wszystko to
/// zostanie zastąpione zasobami wbudowanymi w paczkę aplikacji — zmiana tylko tutaj.
struct ServerEnvironment: Sendable {
    // MARK: Konfiguracja sieci

    /// Adres pętli zwrotnej. Aplikacja zawsze łączy się z serwerem tędy; serwer słucha
    /// wyłącznie tutaj, dopóki użytkownik nie włączy udostępniania (`listensOnLAN`).
    static let host = "127.0.0.1"
    /// Domyślnie 13378; do testów obok działającej kopii: argument `-ABSPort 13400`.
    static let port: Int = {
        let override = UserDefaults.standard.integer(forKey: "ABSPort")
        return (1...65535).contains(override) ? override : 13378
    }()
    /// Musi zgadzać się z `ROUTER_BASE_PATH` w `scripts/build-server.sh`
    /// (klient web ma tę ścieżkę wkompilowaną).
    static let routerBasePath = "/audiobookshelf"

    // MARK: Pliki wykonywalne i kod

    let node: URL
    let serverRoot: URL
    let entryPoint: URL
    let parentWatchScript: URL
    let ffmpeg: URL
    let ffprobe: URL
    /// Opcjonalne rozszerzenie SQLite (wyszukiwanie bez znaków diakrytycznych).
    let nusqlite3: URL?

    // MARK: Dane

    let dataRoot: URL
    var configDirectory: URL { dataRoot.appending(path: "config", directoryHint: .isDirectory) }
    var metadataDirectory: URL { dataRoot.appending(path: "metadata", directoryHint: .isDirectory) }
    /// Ustawienia udostępniania (przełącznik sieci lokalnej, adres zewnętrzny).
    /// Leżą w folderze danych, więc testowy folder danych ma własne.
    static func sharingSettingsURL(dataRoot: URL) -> URL { dataRoot.appending(path: "sharing.json") }

    // MARK: Sieć lokalna

    /// Czy serwer ma słuchać na wszystkich interfejsach (udostępnianie włączone).
    /// Włączane dopiero, gdy istnieje konto root: niezainicjalizowany serwer pozwala
    /// każdemu w sieci utworzyć roota. Ruch w LAN idzie zwykłym HTTP.
    let listensOnLAN: Bool

    // MARK: Adresy

    /// Baza dla klienta API (`/status`, `/login`, `/api/...`).
    static var baseURL: URL { URL(string: "http://\(host):\(port)\(routerBasePath)")! }
    var webURL: URL { URL(string: "http://\(Self.host):\(Self.port)\(Self.routerBasePath)/")! }
    var healthURL: URL { URL(string: "http://\(Self.host):\(Self.port)\(Self.routerBasePath)/healthcheck")! }

    // MARK: Konto root

    /// Nazwa konta root zakładanego przez aplikację na czystym serwerze.
    static let rootUsername = "root"
    /// Usługa pozycji w pęku kluczy z danymi logowania roota. Konto (`account`)
    /// to ścieżka folderu danych, więc testowy folder danych nie nadpisze prawdziwego.
    static let keychainService = "net.smigi.abswift.server-root"
    /// Usługa sprzed etapu 3 (klasyczny pęk kluczy, podpis ad hoc) — tylko do migracji.
    static let legacyKeychainService = "com.audiobookswift.server-root"
    /// Konto zwykłego użytkownika: wspólne dla web UI na Macu i klienta na telefonie.
    static let userKeychainService = "net.smigi.abswift.server-user"
    var keychainAccount: String { dataRoot.path }

    // MARK: Wersja

    /// Wersja audiobookshelf z `package.json` zbudowanego serwera.
    var serverVersion: String? {
        guard let data = try? Data(contentsOf: serverRoot.appending(path: "package.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["version"] as? String
    }

    enum ResolveError: LocalizedError {
        case missingDevelopmentRoot
        case missing(what: String, path: String, hint: String)

        var errorDescription: String? {
            switch self {
            case .missingDevelopmentRoot:
                "Brak klucza ABSDevelopmentRoot w Info.plist."
            case let .missing(what, path, hint):
                "Nie znaleziono: \(what) (\(path)). \(hint)"
            }
        }
    }

    static func resolve(bundle: Bundle = .main, fileManager: FileManager = .default) throws -> ServerEnvironment {
        guard let rootPath = bundle.object(forInfoDictionaryKey: "ABSDevelopmentRoot") as? String, !rootPath.isEmpty else {
            throw ResolveError.missingDevelopmentRoot
        }
        let buildRoot = URL(filePath: rootPath, directoryHint: .isDirectory).standardizedFileURL
        let buildHint = "Uruchom scripts/build-server.sh."

        let node = buildRoot.appending(path: "node/bin/node")
        let serverRoot = buildRoot.appending(path: "abs-server", directoryHint: .isDirectory)
        let entryPoint = serverRoot.appending(path: "dist-server/index.js")
        let homebrew = URL(filePath: "/opt/homebrew/bin", directoryHint: .isDirectory)
        let ffmpeg = homebrew.appending(path: "ffmpeg")
        let ffprobe = homebrew.appending(path: "ffprobe")
        let nusqlite3 = serverRoot.appending(path: "libnusqlite3.dylib")

        guard fileManager.isExecutableFile(atPath: node.path) else {
            throw ResolveError.missing(what: "Node.js", path: node.path, hint: buildHint)
        }
        guard fileManager.fileExists(atPath: entryPoint.path) else {
            throw ResolveError.missing(what: "zbudowany serwer audiobookshelf", path: entryPoint.path, hint: buildHint)
        }
        for (name, url) in [("ffmpeg", ffmpeg), ("ffprobe", ffprobe)] where !fileManager.isExecutableFile(atPath: url.path) {
            throw ResolveError.missing(what: name, path: url.path, hint: "Zainstaluj: brew install ffmpeg.")
        }
        guard let parentWatch = bundle.url(forResource: "parent-watch", withExtension: "js") else {
            throw ResolveError.missing(what: "parent-watch.js", path: "zasoby aplikacji", hint: "Przebuduj aplikację.")
        }

        let dataRoot = try resolveDataRoot(fileManager: fileManager)

        return ServerEnvironment(
            node: node,
            serverRoot: serverRoot,
            entryPoint: entryPoint,
            parentWatchScript: parentWatch,
            ffmpeg: ffmpeg,
            ffprobe: ffprobe,
            nusqlite3: fileManager.fileExists(atPath: nusqlite3.path) ? nusqlite3 : nil,
            dataRoot: dataRoot,
            listensOnLAN: SharingSettings.load(from: sharingSettingsURL(dataRoot: dataRoot)).isEnabled
        )
    }

    /// Folder danych serwera. Domyślnie `~/Library/Application Support/AudiobookSwift`;
    /// do testów na czystym folderze można go podmienić argumentem uruchomienia
    /// `-ABSDataRoot /ścieżka` (np. `open AudiobookSwift.app --args -ABSDataRoot /tmp/abs`).
    static func resolveDataRoot(fileManager: FileManager = .default) throws -> URL {
        let root: URL
        if let override = UserDefaults.standard.string(forKey: "ABSDataRoot"), !override.isEmpty {
            root = URL(filePath: (override as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        } else {
            root = try fileManager
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "AudiobookSwift", directoryHint: .isDirectory)
        }
        // Folder musi istnieć przed normalizacją: `standardizedFileURL` usuwa prefiks
        // `/private` tylko z istniejących ścieżek, a ścieżka jest kluczem w pęku kluczy.
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL
    }

    func prepareDirectories(fileManager: FileManager = .default) throws {
        for directory in [configDirectory, metadataDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    var arguments: [String] {
        ["--require", parentWatchScript.path, entryPoint.path]
    }

    /// Środowisko budowane jawnie, bez dziedziczenia po aplikacji. Nazwy zmiennych
    /// pochodzą z `index.js` i `server/managers/BinaryManager.js` upstreamu.
    var processEnvironment: [String: String] {
        var environment: [String: String] = [
            "NODE_ENV": "production",
            "PORT": String(Self.port),
            "ROUTER_BASE_PATH": Self.routerBasePath,
            "CONFIG_PATH": configDirectory.path,
            "METADATA_PATH": metadataDirectory.path,
            "SOURCE": "audiobookswift",
            "FFMPEG_PATH": ffmpeg.path,
            "FFPROBE_PATH": ffprobe.path,
            // Bez tego upstream akceptuje wyłącznie ffmpeg 5.1 i pobiera własne binarki
            // (x86_64) do katalogu serwera albo config.
            "SKIP_BINARIES_CHECK": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        if let nusqlite3 {
            environment["NUSQLITE3_PATH"] = nusqlite3.path
        }
        // Bez `HOST` upstream słucha na wszystkich interfejsach (IPv4 i IPv6).
        if !listensOnLAN {
            environment["HOST"] = Self.host
        }
        let inherited = ProcessInfo.processInfo.environment
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "TZ"] {
            environment[key] = inherited[key]
        }
        return environment
    }
}
