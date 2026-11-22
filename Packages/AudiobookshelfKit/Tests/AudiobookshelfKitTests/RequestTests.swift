// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
import AudiobookshelfKit

/// Budowanie zapytań i zamiana statusów HTTP na błędy — przez zaślepkę `URLProtocol`.
extension Stubbed {
@Suite struct RequestTests {
    init() { StubServer.reset() }

    @Test func loginAsksForRefreshTokenInBody() async throws {
        StubServer.on("POST login", .json(#"{"user":{"id":"u1","username":"ola","accessToken":"A1","refreshToken":"R1"}}"#))
        let login = try await StubServer.client().login(.init(username: "ola", password: "tajne"), returnRefreshToken: true)
        #expect(login.accessToken == "A1")
        #expect(login.refreshToken == "R1")

        let request = try #require(StubServer.requests.first)
        #expect(request.request.value(forHTTPHeaderField: "x-return-tokens") == "true")
        #expect(request.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONDecoder().decode(AudiobookshelfClient.Credentials.self, from: try #require(request.body))
        #expect(body == .init(username: "ola", password: "tajne"))
    }

    /// Sprawdzanie adresu serwera musi mieć własny, krótki limit czasu w samym zapytaniu
    /// (limit z `URLRequest` wygrywa z limitem sesji): inaczej nieosiągalny adres lokalny
    /// trzymał telefon 30 s przed próbą tunelu.
    @Test func meUsesGivenTimeout() async throws {
        StubServer.on("GET api/me", .json(#"{"id":"u1","username":"ola","type":"user"}"#))
        let user: AudiobookshelfClient.User = try await StubServer.client().me(token: "T", timeout: 2.5)
        #expect(user.id == "u1")
        #expect(StubServer.requests.first?.request.timeoutInterval == 2.5)
    }

    @Test func itemsPageQueryAndBearerToken() async throws {
        StubServer.on("GET api/libraries/lib1/items", .json(#"{"results":[],"total":0}"#))
        let filter = AudiobookshelfClient.filter("authors", "a1")
        _ = try await StubServer.client().itemsPage(libraryID: "lib1", page: 2, limit: 50, sort: "media.metadata.title", descending: true, filter: filter, token: "T")

        let request = try #require(StubServer.requests.first?.request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer T")
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query["page"] == "2")
        #expect(query["limit"] == "50")
        #expect(query["desc"] == "1")
        #expect(query["minified"] == "1")
        // Base64 jest dodatkowo kodowany procentowo (jak w web UI), więc w zapytaniu zostaje `%3D`.
        #expect(query["filter"] == filter)
        #expect(filter == "authors.YTE%3D")
    }

    @Test func progressPatchBody() async throws {
        StubServer.on("PATCH api/me/progress/li1/ep1", .json("{}"))
        try await StubServer.client().updateProgress(itemID: "li1", episodeID: "ep1", currentTime: 50, duration: 200, token: "T")
        let body = try #require(StubServer.requests.first?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["currentTime"] as? Double == 50)
        #expect(json["progress"] as? Double == 0.25)
        #expect(json["isFinished"] == nil)
    }

    @Test func statusCodesMapToErrors() async throws {
        StubServer.on("GET status", .status(401), .status(429), .json("Coś poszło nie tak", status: 500), .json("nie-json"))
        let client = StubServer.client()
        await #expect(throws: AudiobookshelfClient.APIError.unauthorized) { try await client.status() }
        await #expect(throws: AudiobookshelfClient.APIError.rateLimited) { try await client.status() }
        await #expect(throws: AudiobookshelfClient.APIError.http(status: 500, message: "Coś poszło nie tak")) { try await client.status() }
        await #expect(throws: AudiobookshelfClient.APIError.invalidResponse) { try await client.status() }
    }
}
}

extension AudiobookshelfClient.APIError: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.errorDescription == rhs.errorDescription }
}
