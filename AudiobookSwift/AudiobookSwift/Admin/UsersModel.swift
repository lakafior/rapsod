import AudiobookshelfKit
import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AudiobookSwift", category: "Admin")

/// Konta na serwerze (podstrona „Użytkownicy”), na tokenie root. Wzorzec: `UserController.js`
/// i `AccountModal.vue` upstreamu. Konto root jest tylko do odczytu (jego hasło trzyma pęk kluczy
/// aplikacji), a konto do słuchania używane przez aplikację ma zablokowany typ i aktywność;
/// jego nowa nazwa i hasło od razu trafiają do pęku kluczy (`ServerAccount`).
@MainActor
@Observable
final class UsersModel {
    private let account: ServerAccount

    private(set) var users: [AudiobookshelfClient.ManagedUser] = []
    private(set) var tags: [String] = []
    private(set) var isLoading = false
    private(set) var deleting: String?
    var error: String?
    var notice: String?

    init(account: ServerAccount) {
        self.account = account
    }

    var libraries: [AudiobookshelfClient.Library] { account.libraries }

    /// Statystyki słuchania wybranego konta (etap 9i; `GET /api/users/:id/listening-stats`).
    func listeningStats(_ user: AudiobookshelfClient.ManagedUser) async throws -> AudiobookshelfClient.ListeningStats {
        let id = user.id
        return try await account.withAdminToken { try await $0.listeningStats(userID: id, token: $1) }
    }

    /// Czy to konto do słuchania, którego używa aplikacja (Mac i telefon).
    func isListener(_ user: AudiobookshelfClient.ManagedUser) -> Bool {
        guard let name = account.listeningUsername else { return false }
        return user.username.caseInsensitiveCompare(name) == .orderedSame
    }

    func load() async {
        guard account.state == .ready else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await account.withAdminToken { try await $0.users(token: $1) }
            users = list.sorted { lhs, rhs in
                if lhs.isRoot != rhs.isRoot { return lhs.isRoot }
                return lhs.username.localizedCaseInsensitiveCompare(rhs.username) == .orderedAscending
            }
            tags = try await account.withAdminToken { try await $0.allTags(token: $1) }
            try? await account.refreshLibraries()
        } catch {
            self.error = ItemManager.message(for: error, action: "Nie udało się wczytać użytkowników")
        }
    }

    /// Szkic konta w arkuszu edycji.
    struct Draft: Equatable {
        var id: String?
        var username = ""
        /// Puste przy edycji = bez zmiany. Nie trafia do logów.
        var password = ""
        var type = "user"
        var isActive = true
        var permissions = AudiobookshelfClient.Permissions.defaults(for: "user")
        var libraries: Set<String> = []
        var tags: Set<String> = []

        var isNew: Bool { id == nil }

        init() {}

        init(_ user: AudiobookshelfClient.ManagedUser) {
            id = user.id
            username = user.username
            type = user.type
            isActive = user.isActive
            permissions = user.permissions
            libraries = Set(user.librariesAccessible)
            tags = Set(user.itemTagsSelected)
        }

        /// Nowy typ konta przestawia uprawnienia na domyślne dla niego, ale zostawia wybór bibliotek i tagów.
        mutating func setType(_ newType: String) {
            let keep = permissions
            type = newType
            permissions = .defaults(for: newType)
            permissions.accessAllLibraries = keep.accessAllLibraries
            permissions.accessAllTags = keep.accessAllTags
            permissions.selectedTagsNotAccessible = keep.selectedTagsNotAccessible
        }
    }

    /// Zapisuje szkic; zwraca `nil`, gdy się udało, albo komunikat błędu do arkusza.
    func save(_ draft: Draft) async -> String? {
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return "Podaj nazwę użytkownika." }
        if draft.isNew, draft.password.isEmpty { return "Nowe konto potrzebuje hasła." }
        guard ["admin", "user", "guest"].contains(draft.type) else { return "Nieznany typ konta." }
        // Serwer tego nie sprawdza, a konto bez żadnej biblioteki czy tagu nic by nie widziało (jak w `AccountModal.vue`).
        if !draft.permissions.accessAllLibraries, draft.libraries.isEmpty { return "Wybierz co najmniej jedną bibliotekę albo zaznacz dostęp do wszystkich." }
        if !draft.permissions.accessAllTags, draft.tags.isEmpty { return "Wybierz co najmniej jeden tag albo zaznacz dostęp do wszystkich." }

        let original = draft.id.flatMap { id in users.first { $0.id == id } }
        if original?.isRoot == true { return "Konto root zmienia się tylko w pęku kluczy aplikacji." }
        let isListener = original.map(isListener) ?? false

        var changes = AudiobookshelfClient.UserChanges(
            permissions: draft.permissions,
            librariesAccessible: draft.permissions.accessAllLibraries ? [] : draft.libraries.sorted(),
            itemTagsSelected: draft.permissions.accessAllTags ? [] : draft.tags.sorted()
        )
        // Przy dostępie do wszystkich tagów odwrócenie wyboru nic nie znaczy (jak `accessAllTagsToggled`).
        if draft.permissions.accessAllTags { changes.permissions.selectedTagsNotAccessible = false }
        let password = draft.password.isEmpty ? nil : draft.password

        do {
            if let original {
                if username != original.username { changes.username = username }
                changes.password = password
                // Konto aplikacji: typ i aktywność są zablokowane (decyzja z etapu 9c).
                if !isListener {
                    if draft.type != original.type { changes.type = draft.type }
                    if draft.isActive != original.isActive { changes.isActive = draft.isActive }
                }
                let updated = try await account.withAdminToken { try await $0.updateUser(id: original.id, changes, token: $1) }
                replace(updated)
                logger.notice("Zmieniono konto użytkownika")
                if isListener {
                    if changes.username != nil || password != nil {
                        account.listenerCredentialsChanged(username: changes.username, password: password)
                    }
                    if updated.permissions != original.permissions
                        || updated.librariesAccessible != original.librariesAccessible
                        || updated.itemTagsSelected != original.itemTagsSelected {
                        account.listenerPermissionsChanged()
                    }
                    notice = password != nil || changes.username != nil
                        ? "Zmieniono konto „\(updated.username)”. Aplikacja na Macu zapamiętała nowe dane; w telefonie zaloguj się ponownie (dane są w Ustawieniach → Udostępnianie)."
                        : "Zmieniono konto „\(updated.username)”."
                } else {
                    notice = "Zmieniono konto „\(updated.username)”."
                }
            } else {
                changes.username = username
                changes.password = draft.password
                changes.type = draft.type
                changes.isActive = draft.isActive
                let created = try await account.withAdminToken { try await $0.createUser(changes, token: $1) }
                users.append(created)
                logger.notice("Założono konto użytkownika z ustawień")
                notice = "Założono konto „\(created.username)”."
            }
            return nil
        } catch AudiobookshelfClient.APIError.http(status: 400, let body) where body.localizedCaseInsensitiveContains("taken") {
            return "Nazwa „\(username)” jest już zajęta."
        } catch {
            return ItemManager.message(for: error, action: "Nie udało się zapisać konta")
        }
    }

    func delete(_ user: AudiobookshelfClient.ManagedUser) async {
        guard !user.isRoot, deleting == nil else { return }
        let wasListener = isListener(user)
        deleting = user.id
        error = nil
        notice = nil
        defer { deleting = nil }
        do {
            try await account.withAdminToken { try await $0.deleteUser(id: user.id, token: $1) }
            users.removeAll { $0.id == user.id }
            if wasListener {
                account.listenerDeleted()
                notice = "Usunięto konto „\(user.username)”. Aplikacja potrzebuje teraz nowego konta do słuchania — utwórz je na podstronie „Konta”."
            } else {
                notice = "Usunięto konto „\(user.username)”."
            }
        } catch {
            self.error = ItemManager.message(for: error, action: "Nie udało się usunąć konta „\(user.username)”")
        }
    }

    private func replace(_ user: AudiobookshelfClient.ManagedUser) {
        if let index = users.firstIndex(where: { $0.id == user.id }) {
            users[index] = user
        }
    }
}
