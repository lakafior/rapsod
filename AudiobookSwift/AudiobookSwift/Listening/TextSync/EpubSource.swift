import Foundation

/// Rozdziały EPUB-a w kolejności czytania (`spine` z pliku OPF) i jego język — wejście do
/// synchronizacji tekstu z nagraniem. Archiwum rozpakowuje systemowy `bsdtar`, jak komiksy.
struct EpubSource: Sendable {
    let spine: [(href: String, xhtml: String)]
    /// `dc:language` z OPF, np. `pl`.
    let language: String?

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func load(_ epub: URL) async throws -> EpubSource {
        try await Task.detached(priority: .userInitiated) {
            let folder = FileManager.default.temporaryDirectory.appending(path: "AudiobookSwift-epub-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/bsdtar")
            process.arguments = ["-x", "-f", epub.path, "-C", folder.path]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let output = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(decoding: output.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure(message: "Nie udało się rozpakować e-booka" + (detail.isEmpty ? "." : ": \(detail)"))
            }
            return try parse(folder: folder)
        }.value
    }

    private static func parse(folder: URL) throws -> EpubSource {
        let container = folder.appending(path: "META-INF/container.xml")
        guard let data = try? Data(contentsOf: container),
              let opfPath = XMLAttributes.first(element: "rootfile", attribute: "full-path", in: data)
        else { throw Failure(message: "To nie jest poprawny EPUB (brak META-INF/container.xml).") }
        let opfURL = folder.appending(path: opfPath)
        guard let opfData = try? Data(contentsOf: opfURL) else { throw Failure(message: "W EPUB-ie brakuje pliku \(opfPath).") }
        let package = OPFParser(data: opfData)
        let base = (opfPath as NSString).deletingLastPathComponent
        var spine: [(href: String, xhtml: String)] = []
        for idref in package.spine {
            guard let item = package.manifest[idref] else { continue }
            let href = item.href.removingPercentEncoding ?? item.href
            let path = base.isEmpty ? href : (base as NSString).appendingPathComponent(href)
            guard let data = try? Data(contentsOf: folder.appending(path: path)) else { continue }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            spine.append((href: path, xhtml: text))
        }
        if spine.isEmpty { throw Failure(message: "EPUB nie ma rozdziałów w spisie czytania.") }
        return EpubSource(spine: spine, language: package.language)
    }
}

/// Manifest, kolejność czytania i język z pliku OPF.
private final class OPFParser: NSObject, XMLParserDelegate {
    struct Item { let href: String; let mediaType: String? }
    private(set) var manifest: [String: Item] = [:]
    private(set) var spine: [String] = []
    private(set) var language: String?
    private var inLanguage = false
    private var text = ""

    init(data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "item":
            if let id = attributes["id"], let href = attributes["href"] { manifest[id] = Item(href: href, mediaType: attributes["media-type"]) }
        case "itemref":
            if let idref = attributes["idref"] { spine.append(idref) }
        case "language":
            inLanguage = language == nil; text = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inLanguage { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "language", inLanguage {
            inLanguage = false
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { language = value }
        }
    }
}

/// Pierwszy atrybut danego elementu w dokumencie XML.
private final class XMLAttributes: NSObject, XMLParserDelegate {
    private let element: String
    private let attribute: String
    private var value: String?

    private init(element: String, attribute: String) {
        self.element = element; self.attribute = attribute
    }

    static func first(element: String, attribute: String, in data: Data) -> String? {
        let finder = XMLAttributes(element: element, attribute: attribute)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = finder
        parser.parse()
        return finder.value
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == element, value == nil, let v = attributes[attribute] { value = v; parser.abortParsing() }
    }
}
