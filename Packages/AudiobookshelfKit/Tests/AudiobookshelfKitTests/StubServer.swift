// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
import AudiobookshelfKit

/// Zaślepka serwera dla `URLSession`: zapisuje zapytania i odpowiada z tabeli.
/// Testy z jej użyciem są w grupie `Stubbed` i idą po kolei, bo stan jest wspólny.
final class StubServer: URLProtocol, @unchecked Sendable {
    struct Response {
        var status = 200
        var body = Data("{}".utf8)
    }

    struct Recorded {
        let request: URLRequest
        let body: Data?
    }

    nonisolated(unsafe) static var routes: [String: [Response]] = [:]
    nonisolated(unsafe) static var recorded: [Recorded] = []
    /// Trasy odpowiadające zależnie od zapytania (np. numeru strony).
    nonisolated(unsafe) static var handlers: [String: @Sendable (URLRequest) -> Response] = [:]
    private static let lock = NSLock()

    static func reset() {
        lock.withLock {
            routes = [:]
            recorded = []
            handlers = [:]
        }
    }

    /// Zapomina zapisane zapytania, trasy zostają.
    static func clearRequests() {
        lock.withLock { recorded = [] }
    }

    /// Kolejne odpowiedzi dla `METODA ścieżka` (ostatnia się powtarza).
    static func on(_ key: String, _ responses: Response...) {
        lock.withLock { routes[key] = responses }
    }

    /// Odpowiedź liczona z zapytania dla `METODA ścieżka`.
    static func handle(_ key: String, _ handler: @escaping @Sendable (URLRequest) -> Response) {
        lock.withLock { handlers[key] = handler }
    }

    static var requests: [Recorded] { lock.withLock { recorded } }

    static func client() -> AudiobookshelfClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return AudiobookshelfClient(baseURL: URL(string: "http://abs.test/audiobookshelf")!, session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url!.path().replacingOccurrences(of: "/audiobookshelf/", with: "")
        let key = "\(request.httpMethod ?? "GET") \(path)"
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let response: Response = Self.lock.withLock {
            Self.recorded.append(Recorded(request: request, body: body))
            if let handler = Self.handlers[key] { return handler(request) }
            guard var list = Self.routes[key], !list.isEmpty else { return Response(status: 404, body: Data("brak trasy \(key)".utf8)) }
            let first = list.removeFirst()
            Self.routes[key] = list.isEmpty ? [first] : list
            return first
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension StubServer.Response {
    static func json(_ text: String, status: Int = 200) -> Self { Self(status: status, body: Data(text.utf8)) }
    static func status(_ code: Int) -> Self { Self(status: code, body: Data()) }
}

/// Grupa testów korzystających z `StubServer` — po kolei, także między podgrupami.
@Suite(.serialized) enum Stubbed {}
