// swift-tools-version: 6.4
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
        // Odtwarzacz strumienia z serwera (etap 10c): kolejka plików, rozdziały, synchronizacja
        // postępu, „Teraz odtwarzane”. AVFoundation i MediaPlayer — osobny cel, żeby sam klient
        // API został bez nich. Na razie używa go tylko aplikacja iOS.
        .library(name: "AudiobookshelfPlayback", targets: ["AudiobookshelfPlayback"]),
    ],
    targets: [
        .target(name: "AudiobookshelfKit"),
        .target(name: "AudiobookshelfPlayback", dependencies: ["AudiobookshelfKit"]),
        .testTarget(name: "AudiobookshelfKitTests", dependencies: ["AudiobookshelfKit", "AudiobookshelfPlayback"]),
    ]
)
