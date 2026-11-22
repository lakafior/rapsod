import Foundation

/// Miejsce na jeden sekret konta (hasło, refresh token, klucz API). Pakiet nie wie, gdzie
/// aplikacja trzyma sekrety: na Macu to `CredentialStore` (pęk kluczy z ochroną danych),
/// na iOS — własna implementacja aplikacji. `load()` zwraca `nil` wyłącznie, gdy wpisu nie ma;
/// odmowa dostępu i inne błędy są zgłaszane.
public protocol SecretStore<Value>: Sendable {
    associatedtype Value: Codable & Sendable & Equatable
    func load() throws -> Value?
    func save(_ value: Value) throws
    func delete() throws
}

/// Czym konto loguje się na serwer.
public enum AccountSecret: Codable, Sendable, Equatable {
    /// Nazwa i hasło: `/login` z refresh tokenem, odnawianym przez `/auth/refresh`.
    case password(AudiobookshelfClient.Credentials)
    /// Klucz API (upstream `ApiKeyController`, od v2.26): token Bearer bez odświeżania;
    /// tworzy go administrator dla wybranego konta, może mieć datę wygaśnięcia.
    case apiKey(String)
}
