import AppKit

enum SourceID: String, CaseIterable, Identifiable {
    // Raw values match the preference values written by the Python version.
    case appleMusic = "music_app"
    case spotify = "spotify"
    case youtubeMusic = "youtube_music"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleMusic: "Music"
        case .spotify: "Spotify"
        case .youtubeMusic: "YouTube Music"
        }
    }

    var shortName: String { self == .youtubeMusic ? "YouTube" : displayName }

    /// Music.app and Spotify post a distributed notification on every play, pause
    /// and track change; browsers don't.
    var notifiesChanges: Bool { self != .youtubeMusic }
}

struct PlaybackSnapshot: Equatable {
    var source: SourceID
    var title: String
    var artist: String
    var album: String
    var position: TimeInterval     // seconds, as reported at `fetchedAt`
    var duration: TimeInterval     // seconds, 0 if unknown
    var isPaused: Bool
    var fetchedAt: Date
    var artworkURL: URL?

    var trackKey: String { "\(title)\u{1}\(artist)" }
}

protocol MusicSource: AnyObject {
    var id: SourceID { get }
    /// nil when the player isn't running or has nothing loaded.
    func snapshot() async -> PlaybackSnapshot?
    func artwork(for snapshot: PlaybackSnapshot) async -> NSImage?
    func playPause() async
    func next() async
    func previous() async
    func seek(to seconds: TimeInterval) async
}

func downloadArtwork(_ url: URL?) async -> NSImage? {
    guard let url, let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
    return NSImage(data: data)
}

func isRunning(_ bundleID: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
}

/// Music.app and Spotify share the same scripting vocabulary for what we need.
class ScriptablePlayer: MusicSource {
    let id: SourceID
    let bundleID: String
    /// Spotify reports duration in milliseconds, Music in seconds.
    let durationScale: Double

    init(id: SourceID, bundleID: String, durationScale: Double) {
        self.id = id
        self.bundleID = bundleID
        self.durationScale = durationScale
    }

    var tell: String { "tell application id \(appleScriptLiteral(bundleID))" }

    /// Extra track property returned as the 7th list item (artwork URL for Spotify).
    var extraProperty: String { "\"\"" }

    func snapshot() async -> PlaybackSnapshot? {
        // Checked in Swift first: scripting a closed app would launch it.
        guard isRunning(bundleID) else { return nil }
        let start = Date()
        let script = """
        if application id \(appleScriptLiteral(bundleID)) is not running then return {}
        \(tell)
            set st to player state
            if st is not playing and st is not paused then return {}
            set t to current track
            return {st as string, name of t, artist of t, album of t, player position, duration of t, \(extraProperty)}
        end tell
        """
        guard let d = await AppleScriptRunner.shared.run(script), d.numberOfItems >= 7 else { return nil }
        return PlaybackSnapshot(
            source: id,
            title: d.string(2),
            artist: d.string(3),
            album: d.string(4),
            position: d.double(5),
            duration: d.double(6) / durationScale,
            isPaused: d.string(1) == "paused",
            fetchedAt: start.addingTimeInterval(Date().timeIntervalSince(start) / 2),
            artworkURL: URL(string: d.string(7))
        )
    }

    func artwork(for snapshot: PlaybackSnapshot) async -> NSImage? {
        await downloadArtwork(snapshot.artworkURL)
    }

    func playPause() async { _ = await AppleScriptRunner.shared.run("\(tell) to playpause") }
    func next() async { _ = await AppleScriptRunner.shared.run("\(tell) to next track") }
    func previous() async { _ = await AppleScriptRunner.shared.run("\(tell) to previous track") }
    func seek(to seconds: TimeInterval) async {
        _ = await AppleScriptRunner.shared.run("\(tell) to set player position to \(seconds)")
    }
}

final class AppleMusicPlayer: ScriptablePlayer {
    init() { super.init(id: .appleMusic, bundleID: "com.apple.Music", durationScale: 1) }

    override func artwork(for snapshot: PlaybackSnapshot) async -> NSImage? {
        let d = await AppleScriptRunner.shared.run("\(tell) to get data of artwork 1 of current track")
        return d.flatMap { NSImage(data: $0.data) }
    }
}

final class SpotifyPlayer: ScriptablePlayer {
    init() { super.init(id: .spotify, bundleID: "com.spotify.client", durationScale: 1000) }
    override var extraProperty: String { "artwork url of t" }
}
