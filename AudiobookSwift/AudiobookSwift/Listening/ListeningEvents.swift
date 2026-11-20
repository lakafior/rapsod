import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Listening")

/// Zdarzenia serwera na żywo — to samo połączenie Socket.IO, którego używa web UI
/// (`server/SocketAuthority.js`). Dzięki niemu okno „Biblioteka” widzi bez odświeżania postęp
/// z telefonu (`user_item_progress_updated`), zmiany z REST (`user_updated`) i nowe pozycje
/// po skanie (`item_added`, `items_added`…).
///
/// Minimalny klient Engine.IO 4 przez WebSocket: `0` otwarcie, `40` wejście do przestrzeni `/`,
/// `42["auth", token]`, `2`/`3` ping-pong, `42["zdarzenie", dane]`. Działa tylko przy otwartym
/// oknie; zerwane połączenie wraca po kilku sekundach, a po powrocie okno odświeża dane.
/// Token idzie wyłącznie w treści komunikatu `auth`, nigdy w adresie ani w logu.
@MainActor
final class ListeningEvents {
    enum Event {
        case progress(AudiobookshelfClient.MediaProgress)
        case user(AudiobookshelfClient.MeState)
        case itemsChanged(Set<String>)
        case reconnected
    }

    private let url: URL
    /// Token do `auth`; z argumentem — token, który serwer właśnie odrzucił.
    private let token: (String?) async throws -> String
    private let handler: (Event) -> Void
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private let session = URLSession(configuration: .ephemeral)

    init(baseURL: URL, token: @escaping (String?) async throws -> String, handler: @escaping (Event) -> Void) {
        var components = URLComponents(url: baseURL.appending(path: "socket.io/"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "EIO", value: "4"), URLQueryItem(name: "transport", value: "websocket")]
        url = components.url!
        self.token = token
        self.handler = handler
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var attempt = 0
            var rejected: String?
            while !Task.isCancelled {
                guard let self else { return }
                let outcome = await self.connect(rejected: rejected, isReconnect: attempt > 0)
                if Task.isCancelled { return }
                switch outcome {
                case .closed: rejected = nil
                case .rejected(let token): rejected = token
                }
                attempt += 1
                try? await Task.sleep(for: .seconds(min(30, 2 * attempt)))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session.invalidateAndCancel()
    }

    private enum Outcome {
        case closed
        case rejected(String)
    }

    private func connect(rejected: String?, isReconnect: Bool) async -> Outcome {
        let token: String
        do {
            token = try await self.token(rejected)
        } catch {
            return .closed
        }
        let socket = session.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        do {
            while !Task.isCancelled {
                guard case .string(let text) = try await socket.receive() else { continue }
                switch text.first {
                case "0":
                    try await socket.send(.string("40"))
                case "2":
                    try await socket.send(.string("3"))
                case "4":
                    let packet = text.dropFirst()
                    if packet.first == "0" {
                        try await socket.send(.string(Self.event("auth", token)))
                    } else if packet.first == "2" {
                        if let (name, payload) = Self.parse(packet.dropFirst()) {
                            if name == "auth_failed" { return .rejected(token) }
                            if name == "init" {
                                if isReconnect { handler(.reconnected) }
                                continue
                            }
                            dispatch(name, payload)
                        }
                    }
                default:
                    break
                }
            }
        } catch {
            if !Task.isCancelled { logger.notice("Zdarzenia serwera: połączenie przerwane (\(error.localizedDescription, privacy: .public))") }
        }
        return .closed
    }

    private func dispatch(_ name: String, _ payload: Any?) {
        let decoder = JSONDecoder()
        func data(_ value: Any?) -> Data? {
            guard let value, JSONSerialization.isValidJSONObject(value) else { return nil }
            return try? JSONSerialization.data(withJSONObject: value)
        }
        switch name {
        case "user_item_progress_updated":
            struct Payload: Decodable { let data: AudiobookshelfClient.MediaProgress? }
            if let data = data(payload), let progress = try? decoder.decode(Payload.self, from: data).data {
                handler(.progress(progress))
            }
        case "user_updated":
            if let data = data(payload), let me = try? decoder.decode(AudiobookshelfClient.MeState.self, from: data) {
                handler(.user(me))
            }
        case "item_added", "item_updated", "item_removed", "items_added", "items_updated":
            let items = (payload as? [[String: Any]]) ?? [(payload as? [String: Any]) ?? [:]]
            let libraries = Set(items.compactMap { $0["libraryId"] as? String })
            if !libraries.isEmpty { handler(.itemsChanged(libraries)) }
        default:
            break
        }
    }

    /// `["nazwa", dane]` → (nazwa, dane).
    private static func parse(_ text: Substring) -> (String, Any?)? {
        guard let start = text.firstIndex(of: "["),
              let array = try? JSONSerialization.jsonObject(with: Data(text[start...].utf8), options: [.fragmentsAllowed]) as? [Any],
              let name = array.first as? String
        else { return nil }
        return (name, array.count > 1 ? array[1] : nil)
    }

    private static func event(_ name: String, _ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [name, value])
        return "42" + String(decoding: data, as: UTF8.self)
    }
}
