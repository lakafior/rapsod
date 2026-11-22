import SwiftUI

/// Prosty układ zawijający elementy do kolejnych wierszy.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = Self.size(of: view, maxWidth: width)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    /// Element dłuższy niż wiersz (np. bardzo długa nazwa wydawcy) dostaje szerokość wiersza i się zawija.
    private static func size(of view: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let natural = view.sizeThatFits(.unspecified)
        // Pomiar z szerokością 0 (minimalny rozmiar w `Grid`) nie może zwężać kolumny.
        guard maxWidth.isFinite, maxWidth > 80, natural.width > maxWidth else { return natural }
        return view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = Self.size(of: view, maxWidth: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
