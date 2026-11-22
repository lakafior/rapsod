// swift-tools-version: 6.4
import PackageDescription

/// Wspólny kod aplikacji na Maca i klienta iOS (etap 10a): klient HTTP API audiobookshelf
/// z modelami, zdarzenia serwera, odnawianie tokenów i pamięć okładek. Tylko Foundation,
/// ImageIO i OSLog — bez AppKit/UIKit i bez założenia, że serwer działa na tym samym komputerze.
let package = Package(
    name: "AudiobookshelfKit",
    // Ten sam rocznik systemów co cel aplikacji na Maca (macOS 27.0, SDK 27.2): jedna
    // powierzchnia API na obu platformach, bez `#available` we wspólnym kodzie.
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [
        // Biblioteka statyczna (typ nieokreślony): nic do osadzania ani osobnego podpisywania w paczce.
        .library(name: "AudiobookshelfKit", targets: ["AudiobookshelfKit"]),
    ],
    targets: [
        .target(name: "AudiobookshelfKit"),
        .testTarget(name: "AudiobookshelfKitTests", dependencies: ["AudiobookshelfKit"]),
    ]
)
