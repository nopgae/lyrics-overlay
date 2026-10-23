// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LyricsOverlay",
    platforms: [.macOS(.v14)],
    targets: [
        // Lyrics parsing, sync and fetching with no AppKit dependency, so it can be unit tested.
        .target(name: "LyricsCore", path: "Sources/LyricsCore"),
        .executableTarget(name: "LyricsOverlay", dependencies: ["LyricsCore"], path: "Sources/LyricsOverlay"),
        .testTarget(name: "LyricsCoreTests", dependencies: ["LyricsCore"], path: "Tests/LyricsCoreTests"),
    ]
)
