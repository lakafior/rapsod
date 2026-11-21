import Foundation

/// Punkty API czytnika (etap 9g). Postęp czytania zapisuje konto słuchacza — tak samo jak
/// postęp słuchania; żadnych nowych uprawnień. Kształty z upstreamu v2.38.0:
/// `MeController.createUpdateMediaProgress` i `MediaProgress.applyProgressUpdate`.
extension AudiobookshelfClient {
    /// Zapisuje miejsce w e-booku (`PATCH /api/me/progress/:id`). Serwer zmienia tylko podane
    /// pola, więc pozycja w audiobooku zostaje nietknięta. `progress` pomijamy, gdy go nie znamy
    /// (EPUB, zanim epub.js policzy lokacje) — dokładnie jak web UI.
    func updateEbookProgress(itemID: String, location: String, progress: Double?, token: String) async throws {
        struct Body: Encodable {
            let ebookLocation: String
            let ebookProgress: Double?
        }
        let body = Body(ebookLocation: location, ebookProgress: progress.map { min(1, max(0, $0)) })
        _ = try await send("PATCH", "api/me/progress/\(itemID)", body: body, token: token)
    }
}
