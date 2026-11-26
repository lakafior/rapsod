import AppKit

/// „O programie” jako standardowy panel systemu (HIG: About window, etap 14f): ikona, nazwa,
/// wersja z numerem kompilacji i prawa autorskie z Info.plist, a w części „Credits” wersja
/// serwera audiobookshelf, odnośniki i noty dołączonych komponentów (THIRD-PARTY-NOTICES.txt).
@MainActor
enum AboutPanel {
    static func show(serverVersion: String?) {
        DockIcon.shared.windowWillOpen()
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits(serverVersion: serverVersion)])
    }

    static func credits(serverVersion: String?) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor]
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSMutableAttributedString()

        func line(_ string: String, link: URL? = nil) {
            var lineAttributes = attributes
            lineAttributes[.paragraphStyle] = paragraph
            if let link { lineAttributes[.link] = link }
            text.append(NSAttributedString(string: string + "\n", attributes: lineAttributes))
        }

        line("Serwer audiobookshelf \(serverVersion ?? "—")")
        line("audiobookshelf.org", link: URL(string: "https://www.audiobookshelf.org"))
        if let source = HelpLinks.source { line("Kod źródłowy", link: source) }
        if let licenses = ServerEnvironment.licensesDirectory() { line("Teksty licencji", link: licenses) }

        if let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt"),
           let notices = try? String(contentsOf: url, encoding: .utf8) {
            text.append(NSAttributedString(string: "\n" + notices, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return text
    }
}
