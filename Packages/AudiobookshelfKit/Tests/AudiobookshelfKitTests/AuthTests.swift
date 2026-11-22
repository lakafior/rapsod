// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
import AudiobookshelfKit

/// Sekret w pamięci zamiast pęku kluczy.
final class MemoryStore<Value: Codable & Sendable & Equatable>: SecretStore, @unchecked Sendable {
    var value: Value?
    init(_ value: Value? = nil) { self.value = value }
    func load() throws -> Value? { value }
    func save(_ value: Value) throws { self.value = value }
    func delete() throws { value = nil }
}

/// Odnawianie tokenów dla kilku kont naraz, z hasłem albo kluczem API.
extension Stubbed {
@Suite @MainActor struct AuthTests {
    init() { StubServer.reset() }

    @Test func apiKeyIsUsedAsBearerWithoutRenewal() async throws {
        StubServer.on("GET api/me", .status(401))
        let auth = ListeningAuth(client: StubServer.client(), secret: .apiKey("KLUCZ"))
        #expect(try await auth.token() == "KLUCZ")
        await #expect(throws: AudiobookshelfClient.APIError.self) {
            let _: AudiobookshelfClient.User = try await auth.perform { try await $0.me(token: $1) }
        }
        // Jedno zapytanie z kluczem i żadnej próby logowania ani odświeżenia.
        #expect(StubServer.requests.map { $0.request.url!.lastPathComponent } == ["me"])
        #expect(StubServer.requests.first?.request.value(forHTTPHeaderField: "Authorization") == "Bearer KLUCZ")
        auth.reset()
        #expect(try await auth.token() == "KLUCZ")
    }

    @Test func passwordAccountRefreshesAfter401AndPersistsRefreshToken() async throws {
        StubServer.on("POST login", .json(#"{"user":{"id":"u1","username":"ola","accessToken":"A1","refreshToken":"R1"}}"#))
        StubServer.on("POST auth/refresh", .json(#"{"user":{"id":"u1","username":"ola","accessToken":"A2","refreshToken":"R2"}}"#))
        StubServer.on("GET api/tasks", .status(401), .json(#"{"tasks":[]}"#))
        let store = MemoryStore<String>()
        let auth = ListeningAuth(client: StubServer.client(), secret: .password(.init(username: "ola", password: "x")), refreshTokenStore: store)

        let tasks = try await auth.perform { try await $0.tasks(token: $1) }
        #expect(tasks.isEmpty)
        #expect(try await auth.token() == "A2")
        #expect(store.value == "R2")
        let refresh = try #require(StubServer.requests.first { $0.request.url!.path().hasSuffix("auth/refresh") })
        #expect(refresh.request.value(forHTTPHeaderField: "x-refresh-token") == "R1")

        auth.reset()
        #expect(store.value == nil)
    }

    @Test func storedRefreshTokenAvoidsPasswordLogin() async throws {
        StubServer.on("POST auth/refresh", .json(#"{"user":{"id":"u1","username":"ola","accessToken":"A9","refreshToken":"R9"}}"#))
        let auth = ListeningAuth(client: StubServer.client(), refreshTokenStore: MemoryStore("R8")) {
            Issue.record("Logowanie hasłem nie powinno być potrzebne")
            throw AudiobookshelfClient.APIError.unauthorized
        }
        #expect(try await auth.token() == "A9")
    }

    @Test func twoAccountsKeepSeparateTokens() async throws {
        StubServer.on("POST login", .json(#"{"user":{"id":"u1","username":"ola","accessToken":"SLUCHACZ","refreshToken":"R1"}}"#))
        let listener = ListeningAuth(client: StubServer.client(), secret: .password(.init(username: "ola", password: "x")))
        let admin = ListeningAuth(client: StubServer.client(), secret: .apiKey("ADMIN"))
        #expect(try await listener.token() == "SLUCHACZ")
        #expect(try await admin.token() == "ADMIN")
        listener.reset()
        #expect(try await admin.token() == "ADMIN")
    }
}
}
