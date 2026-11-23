// Makieta nowego układu ustawień AudiobookSwift (wariant B, rekomendowany).
// Samodzielna aplikacja z danymi przykładowymi — NIE należy do celu AudiobookSwift.
// Budowanie i zrzuty: ./render.sh (w tym folderze).
// Uruchomienie jednego ekranu: ./Makieta <ekran> [dark]   ekrany: users, profile, root, remote, libraries

import AppKit
import SwiftUI

// MARK: - Dane przykładowe

struct Person: Identifiable {
    let id: String
    let name: String
    let role: String
    let colors: [Color]
    var isMacAccount = false
    var phones = 0
    var listeningNow = false
    var inactive = false
}

let people: [Person] = [
    Person(id: "anna", name: "Anna", role: "Użytkownik", colors: [.orange, .pink], isMacAccount: true, phones: 2, listeningNow: true),
    Person(id: "tomek", name: "Tomek", role: "Użytkownik", colors: [.teal, .blue]),
    Person(id: "babcia", name: "Babcia Ela", role: "Użytkownik", colors: [.purple, .indigo]),
    Person(id: "gosc", name: "Gość", role: "Gość", colors: [.gray, .secondary], inactive: true),
]

enum Page: String, CaseIterable, Identifiable {
    case general = "Ogólne", users = "Użytkownicy", libraries = "Biblioteki"
    case remote = "Dostęp zdalny", notifications = "Powiadomienia", backups = "Kopie zapasowe"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .users: "person.2.crop.square.stack"
        case .libraries: "books.vertical"
        case .remote: "network"
        case .notifications: "bell.badge"
        case .backups: "clock.arrow.circlepath"
        }
    }
}

// MARK: - Okno

struct MockWindow: View {
    let screen: String

    static func height(_ screen: String) -> CGFloat {
        switch screen {
        case "profile": 1180
        case "remote": 960
        default: 700
        }
    }

    var page: Page {
        switch screen {
        case "remote": .remote
        case "libraries": .libraries
        default: .users
        }
    }

    var subtitle: String {
        switch screen {
        case "profile": "Użytkownicy › Anna"
        case "root": "Użytkownicy › Administrator serwera"
        default: page.rawValue
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: .constant(page)) {
                ForEach(Page.allCases) { p in
                    Label(p.rawValue, systemImage: p.symbol).tag(p)
                }
            }
            .frame(minWidth: 215)
            .navigationSplitViewColumnWidth(min: 215, ideal: 215, max: 280)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch screen {
                case "profile": ProfilePage()
                case "root": RootProfilePage()
                case "remote": RemotePage()
                case "libraries": LibrariesPage()
                default: UsersGrid()
                }
            }
            .navigationTitle("Ustawienia")
            .navigationSubtitle(subtitle)
            .toolbar {
                if screen == "profile" || screen == "root" {
                    ToolbarItem(placement: .navigation) {
                        Button("Użytkownicy", systemImage: "chevron.left") {}
                    }
                }
            }
        }
        .frame(width: 860, height: MockWindow.height(screen))
    }
}

// MARK: - Awatar

struct Avatar: View {
    let person: Person
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: person.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .opacity(person.inactive ? 0.45 : 1)
        .overlay(alignment: .bottomTrailing) {
            if person.isMacAccount {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: size * 0.15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(size * 0.07)
                    .background(Circle().fill(Color.accentColor))
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 3))
            }
        }
        .overlay(alignment: .topTrailing) {
            if person.listeningNow {
                Image(systemName: "headphones")
                    .font(.system(size: size * 0.13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(size * 0.06)
                    .background(Circle().fill(.green))
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 3))
            }
        }
    }

    var initials: String {
        person.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}

// MARK: - Użytkownicy: siatka profili

struct UsersGrid: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Kto słucha?")
                    .font(.largeTitle.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 150), spacing: 24)], spacing: 26) {
                    ForEach(people) { person in
                        VStack(spacing: 8) {
                            Avatar(person: person)
                            Text(person.name).font(.headline)
                            Text(caption(person))
                                .font(.caption)
                                .foregroundStyle(person.isMacAccount ? Color.accentColor : .secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    VStack(spacing: 8) {
                        Circle()
                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                            .foregroundStyle(.tertiary)
                            .frame(width: 96, height: 96)
                            .overlay(Image(systemName: "plus").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary))
                        Text("Dodaj osobę").font(.headline).foregroundStyle(.secondary)
                        Text(" ").font(.caption)
                    }
                }
                .padding(.horizontal, 28)

                GroupBox {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(.quaternary).frame(width: 38, height: 38)
                            Image(systemName: "lock.fill").foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Administrator serwera (root)").font(.body.weight(.medium))
                            Text("Konto techniczne aplikacji. Nie trafia do telefonów, nie da się go usunąć.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(4)
                }
                .padding(.horizontal, 28)

                HStack {
                    Label("Anna słucha teraz na iPhonie Anny", systemImage: "headphones")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Historia słuchania wszystkich…") {}
                        .buttonStyle(.link)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
            }
        }
    }

    func caption(_ p: Person) -> String {
        if p.isMacAccount { return "Ten Mac · \(p.phones) telefony" }
        if p.inactive { return "\(p.role) · nieaktywne" }
        return p.role
    }
}

// MARK: - Profil (konto słuchacza używane przez Maca)

struct ProfilePage: View {
    @State private var showsPassword = false
    @State private var advanced = false
    let anna = people[0]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    Avatar(person: anna, size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Anna").font(.title.weight(.semibold))
                        HStack(spacing: 6) {
                            Chip(text: "Konto tego Maca", systemImage: "laptopcomputer", tint: .accentColor)
                            Chip(text: "Użytkownik", systemImage: "person", tint: .secondary)
                        }
                        Text("Słucha teraz · „Lalka”, rozdz. 12 · iPhone Anny")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section {
                PhoneRow(name: "iPhone Anny", detail: "sparowany 3 lis 2026 · ostatnio dziś")
                PhoneRow(name: "iPad", detail: "sparowany 12 paź 2026")
                HStack {
                    Button("Kod z adresami…") {}
                        .help("Aktualizuje adresy serwera na sparowanych telefonach bez ponownego parowania")
                    Spacer()
                    Button("Podłącz telefon…", systemImage: "qrcode") {}
                        .buttonStyle(.borderedProminent)
                }
            } header: {
                Text("Telefony")
            } footer: {
                Text("Telefon dostaje własny klucz tego konta — bez hasła i bez konta root. Klucz nie wygasa; „Odłącz” cofa go od razu.")
            }

            Section("Hasło") {
                LabeledContent("Hasło") {
                    HStack {
                        Text(showsPassword ? "przykładowe-hasło-xyz" : String(repeating: "•", count: 14))
                            .font(.callout.monospaced())
                        Button(showsPassword ? "Ukryj" : "Pokaż") { showsPassword.toggle() }
                        Button("Kopiuj") {}
                        Button("Zmień…") {}
                    }
                }
                LabeledContent("Do innych aplikacji") {
                    Button("Dane logowania (adres, nazwa, hasło)…") {}
                }
            }

            Section {
                Picker("Rola", selection: .constant("user")) {
                    Text("Użytkownik").tag("user")
                    Text("Administrator").tag("admin")
                }
                .pickerStyle(.segmented)
                LabeledContent("Uprawnienia", value: "pobieranie, edycja pozycji")
                LabeledContent("Biblioteki", value: "wszystkie")
                HStack {
                    Spacer()
                    Button("Zarządzaj rolą i dostępem…") {}
                }
            } header: {
                Text("Rola i dostęp")
            } footer: {
                Text("Administrator jest potrzebny tylko do zlecania z telefonu pobierania odcinków podcastów. Daje jednak zarządzanie całym serwerem z każdego sparowanego telefonu.")
            }

            Section("Słuchanie") {
                HStack(spacing: 28) {
                    Stat(value: "142 h", label: "w tym roku")
                    Stat(value: "23", label: "ukończone")
                    Stat(value: "14 dni", label: "z rzędu")
                    Spacer()
                    Button("Statystyki i sesje…") {}
                }
            }

            Section {
                DisclosureGroup("Zaawansowane", isExpanded: $advanced) {
                    LabeledContent("Nazwa konta na serwerze", value: "anna")
                    LabeledContent("Dostęp według tagów", value: "wszystkie tagi")
                    LabeledContent("Inne klucze API tego konta", value: "brak")
                }
                Button("Usuń konto…", role: .destructive) {}
                    .foregroundStyle(.red)
            } footer: {
                Text("Usunięcie konta tego Maca zatrzyma odtwarzanie, wyloguje telefony i skasuje postęp słuchania. Aplikacja poprosi o nowe konto.")
            }
        }
        .formStyle(.grouped)
    }
}

struct Chip: View {
    let text: String
    let systemImage: String
    let tint: Color
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

struct PhoneRow: View {
    let name: String
    let detail: String
    var body: some View {
        LabeledContent {
            Button("Odłącz…", role: .destructive) {}
        } label: {
            Label {
                Text(name)
                Text(detail)
            } icon: {
                Image(systemName: "iphone").foregroundStyle(Color.accentColor)
            }
        }
    }
}

struct Stat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Profil root

struct RootProfilePage: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    ZStack {
                        Circle().fill(.quaternary).frame(width: 72, height: 72)
                        Image(systemName: "lock.fill").font(.system(size: 28)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Administrator serwera").font(.title.weight(.semibold))
                        Chip(text: "root · konto techniczne", systemImage: "key", tint: .secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Tym kontem aplikacja zarządza serwerem (użytkownicy, biblioteki, kopie). Nie służy do słuchania i nigdy nie trafia do telefonu. Nie da się go usunąć ani zmienić jego roli.")
            }

            Section("Hasło") {
                LabeledContent("Hasło", value: "zapisane w pęku kluczy tego Maca")
                LabeledContent("Stan") {
                    Label("Aplikacja jest zalogowana", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }

            Section {
                DisclosureGroup("Zaawansowane") {
                    LabeledContent("Nazwa konta", value: "root")
                    Button("Zaloguj ponownie hasłem…") {}
                }
            } footer: {
                Text("„Zaloguj ponownie” jest potrzebne tylko wtedy, gdy hasło w pęku kluczy przestało pasować (np. po przywróceniu starej kopii).")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dostęp zdalny

struct RemotePage: View {
    @State private var mode = 2
    @State private var advanced = false

    var body: some View {
        Form {
            Section {
                ReachRow(symbol: "laptopcomputer", title: "Ten Mac", detail: "zawsze", ok: true)
                ReachRow(symbol: "wifi", title: "Sieć domowa", detail: "192.168.1.20 · telefony znajdą Maca same (Bonjour)", ok: true)
                ReachRow(symbol: "globe", title: "Spoza domu", detail: "Cloudflare Tunnel · ksiazki.example.com", ok: true)
            } header: {
                Text("Skąd można słuchać")
            }

            Section {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(.orange)
                    Text("2 telefony nie znają jeszcze nowego adresu spoza domu.")
                    Spacer()
                    Button("Pokaż kod z adresami…") {}
                }
            }

            Section {
                Toggle("Udostępniaj w sieci domowej", isOn: .constant(true))
                LabeledContent("Adres") {
                    HStack {
                        Text("http://192.168.1.20:13378").font(.callout.monospaced())
                        Button("Kopiuj") {}
                    }
                }
            } header: {
                Text("Sieć domowa")
            } footer: {
                Text("W sieci domowej ruch idzie zwykłym HTTP. Wyłączenie zostawia serwer tylko dla tego Maca.")
            }

            Section {
                Picker("Sposób", selection: $mode) {
                    Text("Wyłączony").tag(0)
                    Text("Własny adres").tag(1)
                    Text("Cloudflare Tunnel").tag(2)
                }
                .pickerStyle(.segmented)
                LabeledContent("Stan") {
                    Label("Połączony", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                LabeledContent("Adres") {
                    HStack {
                        Text("https://ksiazki.example.com").font(.callout.monospaced())
                        Button("Kopiuj") {}
                    }
                }
                LabeledContent("Token tunelu") {
                    HStack {
                        Text("zapisany w pęku kluczy").foregroundStyle(.secondary)
                        Button("Zmień…") {}
                    }
                }
            } header: {
                Text("Spoza domu")
            } footer: {
                Text("Tunel zestawia aplikacja; inne tunele i VPN-y na tym Macu zostają nietknięte. Plan darmowy Cloudflare może ograniczać duże pliki audio.")
            }

            Section {
                DisclosureGroup(isExpanded: $advanced) {
                    LabeledContent("Logowanie przez OpenID (SSO)", value: "wyłączone")
                    LabeledContent("Wiadomość na stronie logowania", value: "brak")
                    LabeledContent("Klucze API", value: "1 skrypt · 2 telefony Anny")
                    LabeledContent("Publiczne kanały RSS", value: "1 otwarty")
                    LabeledContent("Log tunelu", value: "120 wpisów")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Zaawansowane")
                        Text("Logowanie SSO, klucze API, kanały RSS, log tunelu")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ReachRow: View {
    let symbol: String
    let title: String
    let detail: String
    let ok: Bool
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(ok ? .green : .secondary)
        }
    }
}

// MARK: - Biblioteki (z rozwiniętą sekcją „Zaawansowane”)

struct LibrariesPage: View {
    @State private var advanced = true

    var body: some View {
        Form {
            Section {
                LibraryRow(name: "Audiobooki", symbol: "books.vertical", detail: "1 214 pozycji · /Volumes/Dane/Audiobooki", status: "Skan zakończony — dodane: 3 (12 s)")
                LibraryRow(name: "Podcasty", symbol: "antenna.radiowaves.left.and.right", detail: "38 podcastów · ~/Podcasty", status: nil)
                HStack {
                    Spacer()
                    Button("Dodaj audiobooki…") {}
                    Button("Dodaj podcasty…") {}
                }
            } header: {
                Text("Biblioteki")
            } footer: {
                Text("Kliknij bibliotekę, żeby zmienić jej nazwę, foldery, źródło metadanych, harmonogram skanu i inne ustawienia.")
            }

            Section("Metadane") {
                Toggle(isOn: .constant(true)) {
                    Text("Polskie źródła metadanych")
                    Text("Lubimyczytać, Audioteka, Storytel i inne · działają")
                }
                LabeledContent("Własni dostawcy", value: "brak")
            }

            Section {
                DisclosureGroup(isExpanded: $advanced) {
                    Toggle("Obserwuj zmiany w folderach (wszystkie biblioteki)", isOn: .constant(true))
                    Toggle("Szukaj okładek, gdy pozycja ich nie ma", isOn: .constant(true))
                    Picker("Dostawca okładek", selection: .constant("google")) { Text("Google Books").tag("google") }
                    Toggle("Podtytuł z nazwy folderu", isOn: .constant(false))
                    Toggle("Dopasowane metadane mają pierwszeństwo", isOn: .constant(false))
                    Toggle("Zapisuj okładki i metadata.json w folderach pozycji", isOn: .constant(false))
                    LabeledContent("Pomijane przedrostki przy sortowaniu", value: "the, a")
                    LabeledContent("Pamięć podręczna okładek") {
                        Button("Wyczyść…") {}
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Zaawansowane")
                        Text("Skaner, okładki, sortowanie, pamięć podręczna — wspólne dla wszystkich bibliotek")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct LibraryRow: View {
    let name: String
    let symbol: String
    let detail: String
    let status: String?
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let status {
                    Label(status, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                }
            }
            Spacer()
            Button("Skanuj") {}
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Aplikacja

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let screen = args.count > 1 ? args[1] : "users"
        NSApp.appearance = NSAppearance(named: args.contains("dark") ? .darkAqua : .aqua)
        let host = NSHostingController(rootView: MockWindow(screen: screen))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 860, height: MockWindow.height(screen)))
        window.title = "Ustawienia"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
