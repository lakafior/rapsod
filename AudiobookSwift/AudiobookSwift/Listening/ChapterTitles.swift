import Foundation

/// Tytuły rozdziałów do pokazania.
///
/// Książki bez opisanych rozdziałów mają tytuły wzięte z nazw plików, np. „38 Polskie
/// morderczynie”: różnią się tylko numerem, a reszta powtarza tytuł książki. Taka lista
/// jest ścianą tego samego tekstu, więc zamieniamy ją na „Rozdział 1”, „Rozdział 2”…
enum ChapterTitles {
    static func display(_ titles: [String]) -> [String] {
        guard titles.count > 1 else { return titles }
        let stems = Set(titles.map(stem))
        guard stems.count == 1 else { return titles }
        return titles.indices.map { "Rozdział \($0 + 1)" }
    }

    /// Tytuł bez numeru i separatorów na początku i końcu, bez rozróżniania wielkości liter.
    private static func stem(_ title: String) -> String {
        let noise = CharacterSet.decimalDigits.union(.whitespacesAndNewlines).union(.punctuationCharacters)
        return title.trimmingCharacters(in: noise).lowercased()
    }
}
