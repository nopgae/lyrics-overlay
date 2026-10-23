// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LyricsOverlay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LyricsOverlay", targets: ["LyricsOverlay"]),
        // Loaded into /usr/bin/perl to read the system Now Playing (see the .m file).
        .library(name: "NowPlayingHelper", type: .dynamic, targets: ["NowPlayingHelper"]),
    ],
    targets: [
        // Lyrics parsing, sync and fetching with no AppKit dependency, so it can be unit tested.
        .target(name: "LyricsCore", path: "Sources/LyricsCore"),
        .target(
            name: "NowPlayingHelper",
            path: "Sources/NowPlayingHelper",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(name: "LyricsOverlay", dependencies: ["LyricsCore"], path: "Sources/LyricsOverlay"),
        .testTarget(name: "LyricsCoreTests", dependencies: ["LyricsCore"], path: "Tests/LyricsCoreTests"),
    ]
)
