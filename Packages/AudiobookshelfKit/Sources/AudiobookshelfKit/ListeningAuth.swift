// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Listening")

/// Tokeny jednego konta na serwerze (słuchacza albo administracyjnego).
///
/// Każde konto ma własny obiekt — klient może trzymać kilka naraz (np. konto słuchacza
/// i administracyjne na iOS); nic tu nie jest globalne.
///
/// Własna sesja na serwerze (osobna od web UI), bo refresh tokeny są rotowane przy każdym
/// odświeżeniu. Access token żyje godzinę, a słuchanie dłużej: po 401 token jest odświeżany
/// refresh tokenem, a gdy i to się nie uda — aplikacja loguje się ponownie (na Macu hasłem
/// z pęku kluczy). Odświeżenie jest jedno naraz: dwa równoległe unieważniłyby sobie nawzajem
/// refresh token.
///
/// Z kluczem API (`init(client:apiKey:)`) nie ma odświeżania: klucz jest tokenem Bearer,
/// a jego odrzucenie (wyłączony, wygasły) kończy się błędem `unauthorized`.
///
/// Tokeny są domyślnie tylko w pamięci. `refreshTokenStore` (np. pęk kluczy na iOS) pozwala
/// zachować refresh token między uruchomieniami; aplikacja na Maca go nie podaje.
@MainActor
public final class ListeningAuth {
    private let client: AudiobookshelfClient
    /// Nowe logowanie (`ServerAccount.webSession(.listening)`): para tokenów z refresh tokenem.
    /// `nil` przy kluczu API.
    private let login: (@MainActor () async throws -> AudiobookshelfClient.Login)?
    private let refreshTokenStore: (any SecretStore<String>)?
    private var accessToken: String?
    private var refreshToken: String?
    private var renewal: Task<String, any Error>?
    /// Po nieudanym odnowieniu nie pytamy serwera częściej niż co tyle — `/login` i `/auth/refresh`
    /// są za ogranicznikiem prób.
    private var retryAfter = Date.distantPast

    public init(
        client: AudiobookshelfClient,
        refreshTokenStore: (any SecretStore<String>)? = nil,
        login: @escaping @MainActor () async throws -> AudiobookshelfClient.Login
    ) {
        self.client = client
        self.login = login
        self.refreshTokenStore = refreshTokenStore
        // Błąd odczytu traktujemy jak brak tokenu: zostaje logowanie.
        refreshToken = (try? refreshTokenStore?.load()) ?? nil
    }

    /// Konto z kluczem API (`Ustawienia → Klucze API` serwera): bez hasła i bez odświeżania.
    public init(client: AudiobookshelfClient, apiKey: String) {
        self.client = client
        login = nil
        refreshTokenStore = nil
        accessToken = apiKey
    }

    /// Konto opisane sekretem: hasłem (logowanie z refresh tokenem) albo kluczem API.
    public convenience init(client: AudiobookshelfClient, secret: AccountSecret, refreshTokenStore: (any SecretStore<String>)? = nil) {
        switch secret {
        case .password(let credentials):
            self.init(client: client, refreshTokenStore: refreshTokenStore) {
                try await client.login(credentials, returnRefreshToken: true)
            }
        case .apiKey(let key):
            self.init(client: client, apiKey: key)
        }
    }

    public var baseURL: URL { client.baseURL }

    /// Aktualny access token (loguje się przy pierwszym użyciu).
    public func token() async throws -> String {
        if let accessToken { return accessToken }
        return try await renew(expired: nil)
    }

    /// Wykonuje zapytanie; po 401 odnawia token i ponawia raz.
    public func perform<T: Sendable>(_ operation: (AudiobookshelfClient, String) async throws -> T) async throws -> T {
        let token = try await token()
        do {
            return try await operation(client, token)
        } catch AudiobookshelfClient.APIError.unauthorized {
            let fresh = try await renew(expired: token)
            return try await operation(client, fresh)
        }
    }

    /// Nowy token po tym, jak `expired` został odrzucony (np. przez odtwarzacz HTTP/HLS).
    public func renew(expired: String?) async throws -> String {
        if let renewal { return try await renewal.value }
        // Ktoś inny już odnowił token, który był odrzucony.
        if let accessToken, accessToken != expired { return accessToken }
        guard let login, Date.now >= retryAfter else { throw AudiobookshelfClient.APIError.unauthorized }

        let task = Task { @MainActor [client, login, refreshToken] () throws -> String in
            if let refreshToken {
                do {
                    let tokens = try await client.refresh(refreshToken: refreshToken)
                    self.store(tokens)
                    return tokens.accessToken
                } catch {
                    logger.notice("Odświeżenie tokenu nie powiodło się, loguję ponownie: \(error.localizedDescription, privacy: .public)")
                }
            }
            let tokens = try await login()
            self.store(tokens)
            return tokens.accessToken
        }
        renewal = task
        defer { renewal = nil }
        do {
            return try await task.value
        } catch {
            retryAfter = .now.addingTimeInterval(30)
            throw error
        }
    }

    private func store(_ tokens: AudiobookshelfClient.Login) {
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken
        retryAfter = .distantPast
        guard let refreshTokenStore else { return }
        do {
            if let refreshToken = tokens.refreshToken {
                try refreshTokenStore.save(refreshToken)
            } else {
                try refreshTokenStore.delete()
            }
        } catch {
            logger.error("Zapis refresh tokenu: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Zapomina tokeny (serwer zatrzymany albo zmieniło się konto), także zapisany refresh token.
    /// Klucz API zostaje — to dane konta, nie sesja.
    public func reset() {
        renewal?.cancel()
        renewal = nil
        guard login != nil else { return }
        accessToken = nil
        refreshToken = nil
        retryAfter = .distantPast
        try? refreshTokenStore?.delete()
    }
}
