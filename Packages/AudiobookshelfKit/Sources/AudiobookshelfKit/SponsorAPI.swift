// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 13b).

import Foundation

/// Usługa zgodna z API OpenAI (`POST …/chat/completions`) na kluczu użytkownika: OpenAI, Mistral,
/// Gemini (warstwa zgodna z OpenAI), OpenRouter, Groq, lokalne serwery.
public struct SponsorAPIConfiguration: Sendable, Equatable {
    /// Adres bazowy, np. `https://api.mistral.ai/v1`. Pełny adres kończący się na `/chat/completions` też działa.
    public var baseURL: URL
    public var model: String
    /// Klucz (Bearer). `nil` — usługa bez klucza (np. serwer w sieci domowej).
    public var apiKey: String?

    public init(baseURL: URL, model: String, apiKey: String?) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Adres wpisany przez użytkownika → URL. Tylko http(s) z hostem; bez schematu przyjmuje https.
    public static func parseBaseURL(_ text: String) -> URL? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// `…/chat/completions` dopisane do adresu bazowego (nie każdy dostawca ma bazę kończącą się na `/v1`).
    public var endpoint: URL {
        let path = baseURL.path()
        if path.hasSuffix("/chat/completions") || path.hasSuffix("/chat/completions/") { return baseURL }
        return baseURL.appending(path: "chat/completions")
    }

    /// Host usługi — zgoda użytkownika jest przypięta do niego.
    public var host: String { baseURL.host()?.lowercased() ?? "" }
}

/// Błąd usługi z czytelnym komunikatem (bez klucza i bez treści zapytania).
public enum SponsorAPIError: LocalizedError, Sendable, Equatable {
    case unauthorized(status: Int)
    case notFound(model: String)
    case rateLimited
    case server(status: Int)
    case badRequest(String)
    case network(String)
    case invalidFormat(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let status):
            "Usługa odrzuciła klucz API (HTTP \(status)). Sprawdź klucz w Ustawieniach → Ogólne → Fragmenty sponsorowane."
        case .notFound(let model):
            "Usługa nie zna tego adresu albo modelu „\(model)” (HTTP 404). Sprawdź adres API i nazwę modelu."
        case .rateLimited:
            "Usługa ogranicza liczbę zapytań (HTTP 429) i nie odpowiedziała mimo ponowień — spróbuję później."
        case .server(let status):
            "Usługa zwróciła błąd serwera (HTTP \(status)) mimo ponowień — spróbuję później."
        case .badRequest(let message):
            "Usługa odrzuciła zapytanie: \(message)"
        case .network(let message):
            "Brak połączenia z usługą: \(message)"
        case .invalidFormat(let reason):
            "Model odpowiada w niewłaściwym formacie (\(reason)). Spróbuj innego modelu."
        }
    }

    /// Błąd, którego ponowienie nic nie da, dopóki użytkownik nie zmieni ustawień (kolejka staje).
    public var needsSettingsChange: Bool {
        switch self {
        case .unauthorized, .notFound, .badRequest: true
        default: false
        }
    }
}

/// Odpowiedź modelu z licznikami tokenów (gdy usługa je podaje).
public struct ChatReply: Sendable, Equatable {
    public var content: String
    public var promptTokens: Int?
    public var completionTokens: Int?

    public init(content: String, promptTokens: Int? = nil, completionTokens: Int? = nil) {
        self.content = content
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

public protocol ChatCompleting: Sendable {
    func complete(system: String, user: String, maxTokens: Int) async throws -> ChatReply
}

/// Klient `chat/completions` z ponowieniami.
///
/// - 429 i 5xx, zerwane połączenie, przekroczony czas: do `attempts` prób z rosnącym odstępem
///   (`Retry-After` z odpowiedzi, gdy jest, najwyżej `maxDelay`).
/// - 400: jedna próba z minimalnym zapytaniem (bez `response_format`, `temperature`, `max_tokens`) —
///   część usług nie zna trybu JSON albo tych pól; potem błąd z komunikatem usługi.
/// - 401/403/404: od razu błąd (ponowienie nic nie da).
public actor SponsorAPIClient: ChatCompleting {
    public let configuration: SponsorAPIConfiguration
    private let session: URLSession
    private let attempts: Int
    private let baseDelay: Double
    private let maxDelay: Double
    private let sleep: @Sendable (Double) async throws -> Void
    /// Usługa odrzuciła pełne zapytanie (400) — dalej minimalne.
    private var minimal = false
    public private(set) var requests = 0

    public init(configuration: SponsorAPIConfiguration, session: URLSession = .shared, attempts: Int = 4, baseDelay: Double = 2, maxDelay: Double = 60,
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.configuration = configuration
        self.session = session
        self.attempts = max(1, attempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.sleep = sleep
    }

    public func complete(system: String, user: String, maxTokens: Int = 1000) async throws -> ChatReply {
        var attempt = 0
        var triedMinimal = minimal
        while true {
            attempt += 1
            try Task.checkCancellation()
            let request = try makeRequest(system: system, user: user, maxTokens: maxTokens)
            requests += 1
            let data: Data
            let response: HTTPURLResponse
            do {
                let (body, raw) = try await session.data(for: request)
                guard let http = raw as? HTTPURLResponse else { throw SponsorAPIError.network("odpowiedź bez nagłówków HTTP") }
                data = body
                response = http
            } catch let error as URLError where error.code != .cancelled {
                if attempt < attempts {
                    try await sleep(delay(attempt: attempt, retryAfter: nil))
                    continue
                }
                throw SponsorAPIError.network(Self.describe(error))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                throw error.code == .cancelled ? CancellationError() : SponsorAPIError.network(Self.describe(error))
            }
            switch response.statusCode {
            case 200..<300:
                return try decodeReply(data)
            case 400, 422:
                if !triedMinimal {
                    triedMinimal = true
                    minimal = true
                    attempt -= 1
                    continue
                }
                throw SponsorAPIError.badRequest(message(from: data) ?? "HTTP \(response.statusCode)")
            case 401, 403:
                throw SponsorAPIError.unauthorized(status: response.statusCode)
            case 404:
                throw SponsorAPIError.notFound(model: configuration.model)
            case 408, 409, 425, 429, 500...599:
                guard attempt < attempts else {
                    throw response.statusCode == 429 ? SponsorAPIError.rateLimited : SponsorAPIError.server(status: response.statusCode)
                }
                try await sleep(delay(attempt: attempt, retryAfter: response.value(forHTTPHeaderField: "Retry-After")))
            default:
                throw SponsorAPIError.badRequest(message(from: data) ?? "HTTP \(response.statusCode)")
            }
        }
    }

    /// „Sprawdź połączenie”: najmniejsze możliwe zapytanie (bez żadnych danych użytkownika).
    public func check() async throws -> ChatReply {
        try await complete(system: "Answer with JSON only.", user: "Reply with {\"ok\":true}", maxTokens: 20)
    }

    func makeRequest(system: String, user: String, maxTokens: Int) throws -> URLRequest {
        var request = URLRequest(url: configuration.endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = configuration.apiKey { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        if !minimal {
            body["temperature"] = 0
            body["max_tokens"] = maxTokens
            body["response_format"] = ["type": "json_object"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private func decodeReply(_ data: Data) throws -> ChatReply {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw SponsorAPIError.invalidFormat("odpowiedź usługi bez „choices”")
        }
        let content: String
        if let text = message["content"] as? String {
            content = text
        } else if let parts = message["content"] as? [[String: Any]] {
            content = parts.compactMap { $0["text"] as? String }.joined()
        } else {
            content = ""
        }
        let usage = object["usage"] as? [String: Any]
        return ChatReply(content: content, promptTokens: usage?["prompt_tokens"] as? Int, completionTokens: usage?["completion_tokens"] as? Int)
    }

    /// Komunikat z ciała błędu (`{"error":{"message":…}}`, `{"message":…}`, `{"detail":…}`), skrócony,
    /// bez klucza, gdyby usługa go powtórzyła.
    private func message(from data: Data) -> String? {
        var text: String?
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any] { text = error["message"] as? String }
            else if let error = object["error"] as? String { text = error }
            else { text = (object["message"] as? String) ?? (object["detail"] as? String) }
        }
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let key = configuration.apiKey, !key.isEmpty { text = text.replacingOccurrences(of: key, with: "•••") }
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }

    private func delay(attempt: Int, retryAfter: String?) -> Double {
        if let retryAfter, let seconds = Double(retryAfter.trimmingCharacters(in: .whitespaces)) { return min(maxDelay, max(0, seconds)) }
        return min(maxDelay, baseDelay * pow(2, Double(attempt - 1)))
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: "usługa nie odpowiedziała na czas"
        case .cannotFindHost, .dnsLookupFailed: "nie ma takiego adresu"
        case .cannotConnectToHost: "usługa nie przyjmuje połączeń"
        case .notConnectedToInternet: "brak internetu"
        case .networkConnectionLost: "połączenie zostało przerwane"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate: "nieudane połączenie szyfrowane"
        default: error.localizedDescription
        }
    }
}

/// Klasyfikacja całego odcinka okno po oknie, z punktem kontrolnym po każdym oknie (przerwanie
/// i wznowienie po ponownym uruchomieniu nie wysyła drugi raz okien już policzonych).
public struct SponsorClassifier: Sendable {
    public struct Result: Sendable {
        public var findings: [SponsorClassification.Finding]
        public var windows: Int
        public var requests: Int
        public var promptTokens: Int
        public var completionTokens: Int
    }

    public let client: any ChatCompleting
    public var windowLength: Double
    public var overlap: Double

    public init(client: any ChatCompleting, windowLength: Double = 600, overlap: Double = 120) {
        self.client = client
        self.windowLength = windowLength
        self.overlap = overlap
    }

    /// `done` — wyniki okien z poprzedniego przerwanego przebiegu (indeks okna → segmenty).
    /// `onWindow` — po każdym oknie (zapis punktu kontrolnego, postęp).
    /// Okno, które po ponowieniu nadal ma zły format, przerywa całość: częściowy wynik pominąłby reklamy
    /// tylko w części odcinka, a pusty zapis oznaczałby „model nic nie znalazł”.
    public func classify(lines: [SponsorClassification.Line], duration: Double, done: [Int: [SponsorClassification.Finding]] = [:],
                         onWindow: @Sendable (_ index: Int, _ total: Int, _ findings: [SponsorClassification.Finding]) async -> Void = { _, _, _ in }) async throws -> Result {
        let windows = SponsorClassification.windows(lines, length: windowLength, overlap: overlap)
        var result = Result(findings: [], windows: windows.count, requests: 0, promptTokens: 0, completionTokens: 0)
        for window in windows {
            try Task.checkCancellation()
            if let cached = done[window.index] {
                result.findings += cached
                continue
            }
            let user = SponsorClassification.userPrompt(window, totalDuration: duration)
            var reply = try await client.complete(system: SponsorClassification.systemPrompt, user: user, maxTokens: 1000)
            result.requests += 1
            result.promptTokens += reply.promptTokens ?? 0
            result.completionTokens += reply.completionTokens ?? 0
            var findings: [SponsorClassification.Finding]
            do {
                findings = try SponsorClassification.parse(reply.content, window: window)
            } catch let first as SponsorClassification.InvalidResponse {
                reply = try await client.complete(system: SponsorClassification.systemPrompt, user: user + "\n" + SponsorClassification.formatReminder, maxTokens: 1000)
                result.requests += 1
                result.promptTokens += reply.promptTokens ?? 0
                result.completionTokens += reply.completionTokens ?? 0
                do {
                    findings = try SponsorClassification.parse(reply.content, window: window)
                } catch {
                    throw SponsorAPIError.invalidFormat(first.reason)
                }
            }
            result.findings += findings
            await onWindow(window.index, windows.count, findings)
        }
        return result
    }
}

/// Ustawienia wykrywania z modelem (bez klucza — ten jest w pęku kluczy). Konfiguracja zapytań
/// powstaje wyłącznie stąd i tylko przy włączonym wykrywaniu, poprawnym adresie, nazwie modelu
/// i zgodzie udzielonej dla tego samego hosta — zmiana adresu na inną usługę wymaga nowej zgody.
public struct SponsorDetectionSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var baseURL: String
    public var model: String
    /// Host, dla którego użytkownik zgodził się na wysyłanie transkrypcji (`nil` — brak zgody).
    public var consentHost: String?
    public var consentDate: Date?

    public init(enabled: Bool = false, baseURL: String = "", model: String = "", consentHost: String? = nil, consentDate: Date? = nil) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.model = model
        self.consentHost = consentHost
        self.consentDate = consentDate
    }

    public var parsedBaseURL: URL? { SponsorAPIConfiguration.parseBaseURL(baseURL) }
    public var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Adres i model są wpisane (można sprawdzić połączenie i udzielić zgody).
    public var isConfigured: Bool { parsedBaseURL != nil && !trimmedModel.isEmpty }

    public var hasConsent: Bool {
        guard let host = parsedBaseURL?.host()?.lowercased(), let consentHost else { return false }
        return consentHost == host
    }

    /// Konfiguracja do zapytań z transkrypcją — `nil`, gdy cokolwiek z warunków nie jest spełnione.
    public func requestConfiguration(apiKey: String?) -> SponsorAPIConfiguration? {
        guard enabled, hasConsent, let url = parsedBaseURL, !trimmedModel.isEmpty else { return nil }
        return SponsorAPIConfiguration(baseURL: url, model: trimmedModel, apiKey: apiKey)
    }

    /// Konfiguracja do „Sprawdź połączenie” (bez transkrypcji, więc bez zgody i bez włączenia).
    public func checkConfiguration(apiKey: String?) -> SponsorAPIConfiguration? {
        guard let url = parsedBaseURL, !trimmedModel.isEmpty else { return nil }
        return SponsorAPIConfiguration(baseURL: url, model: trimmedModel, apiKey: apiKey)
    }

    /// Plik w folderze danych serwera (obok `sharing.json`), więc testowa kopia z `-ABSDataRoot` ma własny.
    public static let fileName = "sponsor-detection.json"

    public static func load(from url: URL) -> SponsorDetectionSettings {
        guard let data = try? Data(contentsOf: url) else { return .init() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Self.self, from: data)) ?? .init()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
