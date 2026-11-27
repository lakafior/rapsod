// Okładki do biblioteki demonstracyjnej (zrzuty w README): rysowane CoreGraphics i CoreText,
// bez żadnych pobranych grafik. Użycie:
//   swift scripts/demo/covers.swift scripts/demo/catalog.json <folder wyjściowy>
// Zapisuje <folder>/book-<n>.jpg i <folder>/podcast-<n>.jpg (1000×1000, n od 0, kolejność z katalogu).
import AppKit
import CoreText
import Foundation

struct Entry: Decodable {
    let title: String
    let author: String
    let series: String?
    let seq: Int?
    let style: String
    let palette: [String]
}

struct Catalog: Decodable {
    let books: [Entry]
    let podcasts: [Entry]
}

let args = CommandLine.arguments
guard args.count == 3 else { fatalError("użycie: covers.swift <catalog.json> <folder>") }
let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: URL(filePath: args[1])))
let out = URL(filePath: args[2], directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let side: CGFloat = 1000

func color(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
    var value: UInt64 = 0
    Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
    return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                   blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

func luminance(_ hex: String) -> CGFloat {
    let c = color(hex).components ?? [0, 0, 0]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
}

/// Prosty, powtarzalny generator liczb (ziarno z tytułu), żeby okładki nie zmieniały się między przebiegami.
struct Seeded {
    var state: UInt64
    init(_ text: String) { state = text.unicodeScalars.reduce(1469598103934665603) { ($0 ^ UInt64($1.value)) &* 1099511628211 } }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) % 10_000) / 10_000
    }
}

let titleFonts = ["Didot-Bold", "Baskerville-Bold", "Futura-Bold", "AvenirNext-Heavy", "Georgia-Bold", "GillSans-SemiBold", "Optima-ExtraBlack", "HelveticaNeue-Bold", "Rockwell-Bold", "Palatino-Bold"]
let authorFonts = ["AvenirNext-DemiBold", "GillSans", "Futura-Medium", "HelveticaNeue-Medium", "Optima-Regular"]

func attributed(_ text: String, font: String, size: CGFloat, color: CGColor, kern: CGFloat = 0, align: CTTextAlignment = .left) -> NSAttributedString {
    var alignment = align
    let style = withUnsafeBytes(of: &alignment) { pointer -> CTParagraphStyle in
        var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer.baseAddress!)
        return CTParagraphStyleCreate(&setting, 1)
    }
    let ctFont = CTFontCreateWithName(font as CFString, size, nil)
    return NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        NSAttributedString.Key(kCTKernAttributeName as String): kern,
        NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
    ])
}

/// Tekst w prostokącie (układ CoreGraphics: początek w lewym dolnym rogu). Zmniejsza czcionkę, aż się zmieści.
@discardableResult
func draw(_ text: String, in rect: CGRect, font: String, size: CGFloat, color: CGColor, kern: CGFloat = 0, align: CTTextAlignment = .left, top: Bool = true, _ ctx: CGContext) -> CGFloat {
    var size = size
    while true {
        let string = attributed(text, font: font, size: size, color: color, kern: kern, align: align)
        let setter = CTFramesetterCreateWithAttributedString(string)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
        // Bez dzielenia słów: najdłuższe słowo musi się zmieścić w jednym wierszu.
        let longest = text.split(separator: " ").map { word -> CGFloat in
            let line = CTLineCreateWithAttributedString(attributed(String(word), font: font, size: size, color: color, kern: kern))
            return CTLineGetTypographicBounds(line, nil, nil, nil)
        }.max() ?? 0
        if (fit.height <= rect.height && longest <= rect.width) || size < 20 {
            let y = top ? rect.maxY - fit.height : rect.minY
            let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: rect.minX, y: y, width: rect.width, height: fit.height + 2), transform: nil), nil)
            CTFrameDraw(frame, ctx)
            return fit.height
        }
        size -= 4
    }
}

func render(_ entry: Entry, index: Int, podcast: Bool) throws -> Data {
    let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    var rng = Seeded(entry.title)
    let p = entry.palette
    let bg = p[0], accent = p[1], light = p.count > 2 ? p[2] : "#FFFFFF"
    let full = CGRect(x: 0, y: 0, width: side, height: side)
    let titleFont = titleFonts[Int(rng.next() * CGFloat(titleFonts.count))]
    let authorFont = authorFonts[Int(rng.next() * CGFloat(authorFonts.count))]
    let onDark = luminance(light) > 0.6 ? light : "#FFFFFF"
    var textColor = color(luminance(bg) < 0.5 ? onDark : "#1A1A1A")
    var titleRect = CGRect(x: 80, y: 560, width: 840, height: 360)
    var authorRect = CGRect(x: 80, y: 70, width: 840, height: 60)
    var titleSize: CGFloat = 104

    ctx.setFillColor(color(bg))
    ctx.fill(full)

    switch entry.style {
    case "bands":
        let count = 5 + Int(rng.next() * 4)
        for i in 0..<count {
            let h = side * 0.5 / CGFloat(count)
            ctx.setFillColor(color(i.isMultiple(of: 2) ? accent : light, 0.25 + 0.6 * CGFloat(i) / CGFloat(count)))
            ctx.fill(CGRect(x: 0, y: 160 + CGFloat(i) * h, width: side, height: h * 0.72))
        }
        titleRect = CGRect(x: 80, y: 640, width: 840, height: 300)
    case "sun":
        let sky = CGGradient(colorsSpace: nil, colors: [color(bg), color(accent, 0.55)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: side), end: CGPoint(x: 0, y: 250), options: [])
        let r: CGFloat = 150 + rng.next() * 50
        ctx.setFillColor(color(light, 0.92))
        ctx.fillEllipse(in: CGRect(x: side / 2 - r + (rng.next() - 0.5) * 200, y: 330 - r * 0.6, width: 2 * r, height: 2 * r))
        ctx.setFillColor(color(accent))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: 330))
        for i in 0..<4 {
            ctx.setFillColor(color(light, 0.35))
            ctx.fill(CGRect(x: 120 + CGFloat(i) * 60, y: 290 - CGFloat(i) * 46, width: side - 240 - CGFloat(i) * 120, height: 8))
        }
        titleRect = CGRect(x: 80, y: 640, width: 840, height: 290)
        authorRect = CGRect(x: 80, y: 70, width: 840, height: 60)
    case "initial":
        let letter = String(entry.title.prefix(1)).uppercased()
        ctx.saveGState()
        ctx.setAlpha(0.9)
        draw(letter, in: CGRect(x: 40, y: 180, width: 920, height: 760), font: "Didot-Bold", size: 820, color: color(accent), align: .center, top: true, ctx)
        ctx.restoreGState()
        ctx.setFillColor(color(light))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: 330))
        textColor = color(luminance(light) < 0.5 ? "#FFFFFF" : "#1A1A1A")
        titleRect = CGRect(x: 70, y: 140, width: 860, height: 170)
        authorRect = CGRect(x: 70, y: 60, width: 860, height: 60)
        titleSize = 84
    case "stripes":
        ctx.saveGState()
        ctx.setStrokeColor(color(accent))
        ctx.setLineWidth(44)
        for i in stride(from: -side, to: side * 2, by: 130) {
            ctx.move(to: CGPoint(x: i, y: 0))
            ctx.addLine(to: CGPoint(x: i + side, y: side))
        }
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setFillColor(color(light))
        ctx.fill(CGRect(x: 60, y: 480, width: 880, height: 440))
        ctx.setFillColor(color(accent))
        ctx.fill(CGRect(x: 60, y: 480, width: 18, height: 440))
        textColor = color("#141414")
        titleRect = CGRect(x: 110, y: 590, width: 800, height: 300)
        authorRect = CGRect(x: 110, y: 510, width: 800, height: 50)
    case "rings":
        let center = CGPoint(x: side * (0.3 + rng.next() * 0.4), y: side * (0.25 + rng.next() * 0.2))
        for i in (0..<9).reversed() {
            let r = 70 + CGFloat(i) * 75
            ctx.setStrokeColor(color(i.isMultiple(of: 2) ? accent : light, 0.8 - CGFloat(i) * 0.07))
            ctx.setLineWidth(i.isMultiple(of: 3) ? 14 : 4)
            ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        }
        ctx.setFillColor(color(accent))
        ctx.fillEllipse(in: CGRect(x: center.x - 46, y: center.y - 46, width: 92, height: 92))
        titleRect = CGRect(x: 80, y: 620, width: 840, height: 310)
    case "peaks":
        let layers = 4
        for l in 0..<layers {
            let base = 120 + CGFloat(l) * 70
            ctx.setFillColor(color(l.isMultiple(of: 2) ? accent : light, 0.35 + CGFloat(l) * 0.17))
            ctx.move(to: CGPoint(x: 0, y: 0))
            var x: CGFloat = 0
            ctx.addLine(to: CGPoint(x: 0, y: base + rng.next() * 120))
            while x < side {
                x += 120 + rng.next() * 180
                ctx.addLine(to: CGPoint(x: x - 60, y: base + 160 + rng.next() * 240 - CGFloat(l) * 50))
                ctx.addLine(to: CGPoint(x: x, y: base + rng.next() * 80))
            }
            ctx.addLine(to: CGPoint(x: side, y: 0))
            ctx.closePath()
            ctx.fillPath()
        }
        ctx.setFillColor(color(light, 0.9))
        ctx.fillEllipse(in: CGRect(x: 700, y: 560, width: 110, height: 110))
        titleRect = CGRect(x: 80, y: 690, width: 600, height: 250)
        authorRect = CGRect(x: 80, y: 630, width: 600, height: 50)
        titleSize = 92
    case "grid":
        let cols = 5
        let cell = (side - 160) / CGFloat(cols)
        for row in 0..<3 {
            for col in 0..<cols {
                let rect = CGRect(x: 80 + CGFloat(col) * cell + 10, y: 140 + CGFloat(row) * cell + 10, width: cell - 20, height: cell - 20)
                let pick = rng.next()
                ctx.setFillColor(color(pick < 0.45 ? accent : light, pick < 0.45 ? 1 : 0.18 + pick * 0.3))
                if pick > 0.7 { ctx.fillEllipse(in: rect) } else { ctx.fill(rect) }
            }
        }
        titleRect = CGRect(x: 80, y: 690, width: 840, height: 250)
        authorRect = CGRect(x: 80, y: 60, width: 840, height: 60)
    default: // wave
        for l in 0..<6 {
            ctx.setFillColor(color(l.isMultiple(of: 2) ? accent : light, 0.25 + CGFloat(l) * 0.12))
            let base = 520 - CGFloat(l) * 75
            let phase = rng.next() * .pi * 2
            ctx.move(to: CGPoint(x: 0, y: 0))
            for x in stride(from: 0, through: side, by: 10) {
                ctx.addLine(to: CGPoint(x: x, y: base + sin(x / 130 + phase) * (26 + CGFloat(l) * 6)))
            }
            ctx.addLine(to: CGPoint(x: side, y: 0))
            ctx.closePath()
            ctx.fillPath()
        }
        titleRect = CGRect(x: 80, y: 660, width: 840, height: 270)
        authorRect = CGRect(x: 80, y: 600, width: 840, height: 50)
    }

    if entry.series != nil, entry.style != "initial" { titleRect.size.width = min(titleRect.width, side - 200 - titleRect.minX) }
    draw(entry.title, in: titleRect, font: titleFont, size: titleSize, color: textColor, ctx)
    let authorBackground = entry.style == "initial" ? light : (entry.style == "stripes" ? "#FFFFFF" : (entry.style == "sun" ? accent : bg))
    let authorColor = color(luminance(authorBackground) < 0.5 ? "#FFFFFF" : "#1A1A1A", 0.9)
    draw(entry.author.uppercased(), in: authorRect, font: authorFont, size: 34, color: authorColor, kern: 4, ctx)
    if let series = entry.series, let seq = entry.seq, entry.style != "initial" {
        // Mały znaczek serii w prawym górnym rogu.
        let badge = CGRect(x: side - 170, y: side - 150, width: 110, height: 110)
        ctx.setFillColor(color(accent))
        ctx.fillEllipse(in: badge)
        draw("\(seq)", in: badge.insetBy(dx: 10, dy: 22), font: "AvenirNext-Heavy", size: 56, color: color(luminance(accent) < 0.5 ? "#FFFFFF" : "#1A1A1A"), align: .center, ctx)
        _ = series
    }
    if podcast {
        ctx.setFillColor(color(accent))
        ctx.fill(CGRect(x: 0, y: side - 24, width: side, height: 24))
    }

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])!
}

for (index, book) in catalog.books.enumerated() {
    try render(book, index: index, podcast: false).write(to: out.appending(path: "book-\(index).jpg"))
}
for (index, podcast) in catalog.podcasts.enumerated() {
    try render(podcast, index: index, podcast: true).write(to: out.appending(path: "podcast-\(index).jpg"))
}
print("okładki: \(catalog.books.count) książek, \(catalog.podcasts.count) podcastów → \(out.path)")
