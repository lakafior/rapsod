import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Listening")

/// Tokeny konta do słuchania, trzymane tylko w pamięci.
///
/// Własna sesja na serwerze (osobna od web UI), bo refresh tokeny są rotowane przy każdym
/// odświeżeniu. Access token żyje godzinę, a słuchanie dłużej: po 401 token jest odświeżany
/// refresh tokenem, a gdy i to się nie uda — aplikacja loguje się ponownie hasłem z pęku kluczy.
/// Odświeżenie jest jedno naraz: dwa równoległe unieważniłyby sobie nawzajem refresh token.
@MainActor
final class ListeningAuth {
    private let client: AudiobookshelfClient
    /// Nowe logowanie (`ServerAccount.webSession(.listening)`): para tokenów z refresh tokenem.
    private let login: @MainActor () async throws -> AudiobookshelfClient.Login
    private var accessToken: String?
    private var refreshToken: String?
    private var renewal: Task<String, any Error>?
    /// Po nieudanym odnowieniu nie pytamy serwera częściej niż co tyle — `/login` i `/auth/refresh`
    /// są za ogranicznikiem prób.
    private var retryAfter = Date.distantPast

    init(client: AudiobookshelfClient, login: @escaping @MainActor () async throws -> AudiobookshelfClient.Login) {
        self.client = client
        self.login = login
    }

    var baseURL: URL { client.baseURL }

    /// Aktualny access token (loguje się przy pierwszym użyciu).
    func token() async throws -> String {
        if let accessToken { return accessToken }
        return try await renew(expired: nil)
    }

    /// Wykonuje zapytanie; po 401 odnawia token i ponawia raz.
    func perform<T: Sendable>(_ operation: (AudiobookshelfClient, String) async throws -> T) async throws -> T {
        let token = try await token()
        do {
            return try await operation(client, token)
        } catch AudiobookshelfClient.APIError.unauthorized {
            let fresh = try await renew(expired: token)
            return try await operation(client, fresh)
        }
    }

    /// Nowy token po tym, jak `expired` został odrzucony (np. przez odtwarzacz HTTP/HLS).
    func renew(expired: String?) async throws -> String {
        if let renewal { return try await renewal.value }
        // Ktoś inny już odnowił token, który był odrzucony.
        if let accessToken, accessToken != expired { return accessToken }
        guard Date.now >= retryAfter else { throw AudiobookshelfClient.APIError.unauthorized }

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
    }

    /// Zapomina tokeny (serwer zatrzymany albo zmieniło się konto).
    func reset() {
        renewal?.cancel()
        renewal = nil
        accessToken = nil
        refreshToken = nil
        retryAfter = .distantPast
    }
}
