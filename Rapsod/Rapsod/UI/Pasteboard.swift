import AppKit

extension NSPasteboard {
    /// Kopiuje tekst do schowka (zastępuje jego zawartość).
    static func copy(_ text: String) {
        general.clearContents()
        general.setString(text, forType: .string)
    }
}
