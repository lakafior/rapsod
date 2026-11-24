import AudiobookshelfKit
import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Rapsod", category: "Admin")

/// Konta na serwerze (strona „Użytkownicy” i profile osób), na tokenie root. Wzorzec:
/// `UserController.js` i `AccountModal.vue` upstreamu. Konta roota tu się nie zmienia (jego hasło
/// zmienia `ServerAccount`), a konto tego Maca (konto do słuchania) nie da się dezaktywować;
/// jego nowa nazwa i hasło od razu trafiają do pęku kluczy (`ServerAccount`).
///
/// Model żyje w `AppDelegate` (przez `AppModels`), a lista kont zostaje w pamięci, gdy serwer
/// na chwilę znika (np. restart po włączeniu sieci domowej) — profil i jego arkusze nie znikają
/// wtedy spod ręki.
@MainActor
@Observable
final class UsersModel {
    private let account: ServerAccount
    /// Czy lista była choć raz wczytana (pusta lista przed wczytaniem nie znaczy „brak kont”).
    private(set) var hasLoaded = false

    private(set) var users: [AudiobookshelfClient.ManagedUser] = []
    private(set) var tags: [String] = []
    private(set) var isLoading = false
    private(set) var deleting: String?
    var error: String?
    var notice: String?
    /// Kto słucha teraz: identyfikator konta → tytuł (otwarte sesje, `GET /api/sessions/open`).
    private(set) var listeningNow: [String: String] = [:]

    init(account: ServerAccount) {
        self.account = account
    }

    var libraries: [AudiobookshelfClient.Library] { account.libraries }

    /// Statystyki słuchania wybranego konta (etap 9i; `GET /api/users/:id/listening-stats`).
    func listeningStats(_ user: AudiobookshelfClient.ManagedUser) async throws -> AudiobookshelfClient.ListeningStats {
        let id = user.id
        return try await account.withAdminToken { try await $0.listeningStats(userID: id, token: $1) }
    }

    /// Czy to konto tego Maca (konto do słuchania).
    func isListener(_ user: AudiobookshelfClient.ManagedUser) -> Bool {
        account.isListener(username: user.username)
    }

    func user(id: String) -> AudiobookshelfClient.ManagedUser? {
        users.first { $0.id == id }
    }

    /// Domownicy (bez roota): najpierw konto tego Maca, potem alfabetycznie.
    var people: [AudiobookshelfClient.ManagedUser] {
        users.filter { !$0.isRoot }.sorted { lhs, rhs in
            let l = isListener(lhs), r = isListener(rhs)
            if l != r { return l }
            return lhs.username.localizedCaseInsensitiveCompare(rhs.username) == .orderedAscending
        }
    }

    var root: AudiobookshelfClient.ManagedUser? { users.first(where: \.isRoot) }

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
            hasLoaded = true
            error = nil
            tags = try await account.withAdminToken { try await $0.allTags(token: $1) }
            try? await account.refreshLibraries()
        } catch {
            self.error = ItemManager.message(for: error, action: "Nie udało się wczytać użytkowników")
        }
    }

    /// Odświeża „słucha teraz” (kafle i profile). Błąd zostawia poprzedni stan — to tylko podpowiedź.
    func refreshListeningNow() async {
        guard account.state == .ready,
              let open = try? await account.withAdminToken({ try await $0.openSessions(token: $1) }) else { return }
        var now: [String: String] = [:]
        for session in open.sorted(by: { ($0.updatedAt ?? 0) < ($1.updatedAt ?? 0) }) {
            guard let id = session.userId ?? session.user?.id else { continue }
            now[id] = session.displayTitle ?? "—"
        }
        listeningNow = now
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
        if original?.isRoot == true { return "Konto root zmienia się na stronie „Administrator serwera”." }
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
                if draft.type != original.type { changes.type = draft.type }
                // Konta tego Maca nie da się dezaktywować (aplikacja przestałaby działać).
                if !isListener, draft.isActive != original.isActive { changes.isActive = draft.isActive }
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
                        ? "Zmieniono konto „\(updated.username)”. Aplikacja na Macu zapamiętała nowe dane. Telefony z aplikacją Rapsod działają dalej (mają własne klucze); w innych aplikacjach zaloguj się ponownie."
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
                notice = "Usunięto konto „\(user.username)”. Aplikacja potrzebuje teraz nowego konta tego Maca — utwórz je kaflem „Utwórz konto tego Maca”."
            } else {
                notice = "Usunięto konto „\(user.username)”."
            }
        } catch {
            self.error = ItemManager.message(for: error, action: "Nie udało się usunąć konta „\(user.username)”")
        }
    }

    // MARK: - Pojedyncze zmiany z profilu

    /// Rola konta — jedyna droga zmiany typu (profil, arkusz podłączania telefonu). Jak dawne
    /// `setListenerAdmin`: administrator dostaje też „Edycję pozycji”, bo serwer przy zlecaniu
    /// pobrań odcinków (`download-episodes`) sprawdza i typ, i `permissions.update`; powrót do
    /// użytkownika ją zabiera. Gość dostaje domyślne uprawnienia gościa. Wybór bibliotek i tagów zostaje.
    @discardableResult
    func setRole(_ role: String, of user: AudiobookshelfClient.ManagedUser) async throws -> AudiobookshelfClient.ManagedUser {
        guard !user.isRoot, ["admin", "user", "guest"].contains(role) else { return user }
        var permissions = user.permissions
        switch role {
        case "admin":
            permissions.update = true
        case "user":
            permissions.update = false
        default:
            let keep = permissions
            permissions = .defaults(for: "guest")
            permissions.accessAllLibraries = keep.accessAllLibraries
            permissions.accessAllTags = keep.accessAllTags
            permissions.selectedTagsNotAccessible = keep.selectedTagsNotAccessible
        }
        guard user.type != role || permissions != user.permissions else { return user }
        let changes = AudiobookshelfClient.UserChanges(
            type: role,
            permissions: permissions,
            librariesAccessible: user.librariesAccessible,
            itemTagsSelected: user.itemTagsSelected
        )
        let updated = try await account.withAdminToken { try await $0.updateUser(id: user.id, changes, token: $1) }
        logger.notice("Konto ma teraz typ \(role, privacy: .public)")
        replace(updated)
        if isListener(user) { account.listenerPermissionsChanged() }
        return updated
    }

    /// Nowe hasło konta (puste = losowe). Zwraca ustawione hasło, żeby arkusz mógł je pokazać raz.
    /// Dla konta tego Maca hasło trafia od razu do pęku kluczy.
    func setPassword(_ password: String, of user: AudiobookshelfClient.ManagedUser) async throws -> String {
        guard !user.isRoot else { throw AudiobookshelfClient.APIError.unauthorized }
        let password = password.isEmpty ? PasswordGenerator.generate() : password
        var changes = AudiobookshelfClient.UserChanges(
            permissions: user.permissions,
            librariesAccessible: user.librariesAccessible,
            itemTagsSelected: user.itemTagsSelected
        )
        changes.password = password
        let updated = try await account.withAdminToken { try await $0.updateUser(id: user.id, changes, token: $1) }
        logger.notice("Zmieniono hasło konta")
        replace(updated)
        if isListener(user) { account.listenerCredentialsChanged(username: nil, password: password) }
        return password
    }

    /// Zmienia nazwę konta. Dla konta tego Maca nowa nazwa trafia od razu do pęku kluczy;
    /// telefony z aplikacją Rapsod działają dalej (klucz jest związany z identyfikatorem konta).
    func rename(_ user: AudiobookshelfClient.ManagedUser, to newName: String) async -> String? {
        var draft = Draft(user)
        draft.username = newName
        return await save(draft)
    }

    /// Aktywność konta (nie dla konta tego Maca ani roota).
    func setActive(_ isActive: Bool, of user: AudiobookshelfClient.ManagedUser) async -> String? {
        guard !user.isRoot, !isListener(user) else { return nil }
        var draft = Draft(user)
        draft.isActive = isActive
        return await save(draft)
    }

    private func replace(_ user: AudiobookshelfClient.ManagedUser) {
        if let index = users.firstIndex(where: { $0.id == user.id }) {
            users[index] = user
        }
    }
}
