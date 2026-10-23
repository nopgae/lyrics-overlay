import AppKit

/// YouTube Music in a browser tab, driven by JavaScript over Apple Events.
/// Chromium browsers need View → Developer → "Allow JavaScript from Apple Events".
final class YouTubeMusicPlayer: MusicSource {
    let id = SourceID.youtubeMusic

    private struct Browser {
        var name: String
        var bundleID: String
        var jsVerb: String   // Safari: "do JavaScript", Chromium: "execute javascript"
    }

    private let browsers = [
        Browser(name: "Safari", bundleID: "com.apple.Safari", jsVerb: "do JavaScript"),
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome", jsVerb: "execute javascript"),
        Browser(name: "Brave Browser", bundleID: "com.brave.Browser", jsVerb: "execute javascript"),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", jsVerb: "execute javascript"),
        Browser(name: "Arc", bundleID: "company.thebrowser.Browser", jsVerb: "execute javascript"),
        Browser(name: "Chromium", bundleID: "org.chromium.Chromium", jsVerb: "execute javascript"),
    ]

    /// Browser that was playing last time; checked first.
    private var lastBrowser: String?

    // mediaSession metadata is what YT Music shows in Control Center; DOM is the fallback.
    private static let stateJS = """
    (function(){var v=document.querySelector('video');if(!v)return '';\
    var m=navigator.mediaSession&&navigator.mediaSession.metadata;\
    var t=document.querySelector('.title.ytmusic-player-bar');\
    var a=document.querySelector('.byline.ytmusic-player-bar a');\
    var art='';if(m&&m.artwork&&m.artwork.length){art=m.artwork[m.artwork.length-1].src;}\
    return JSON.stringify({title:(m&&m.title)||(t?t.textContent.trim():''),\
    artist:(m&&m.artist)||(a?a.textContent.trim():''),album:(m&&m.album)||'',artwork:art,\
    currentTime:v.currentTime,duration:v.duration||0,paused:v.paused});})()
    """

    private struct State: Decodable {
        var title: String
        var artist: String
        var album: String
        var artwork: String
        var currentTime: Double
        var duration: Double
        var paused: Bool
    }

    func snapshot() async -> PlaybackSnapshot? {
        // Fast path: the browser that was playing last time
        if let last = lastBrowser, let b = browsers.first(where: { $0.name == last }),
           let s = await query(b), !s.isPaused {
            return s
        }
        // Full scan — a playing tab wins over a paused one
        var pausedHit: (String, PlaybackSnapshot)?
        for b in browsers {
            guard let s = await query(b) else { continue }
            if !s.isPaused {
                lastBrowser = b.name
                return s
            }
            if pausedHit == nil { pausedHit = (b.name, s) }
        }
        lastBrowser = pausedHit?.0
        return pausedHit?.1
    }

    private func query(_ b: Browser) async -> PlaybackSnapshot? {
        guard isRunning(b.bundleID) else { return nil }
        let start = Date()
        guard let raw = await runJS(Self.stateJS, in: b), !raw.isEmpty,
              let state = try? JSONDecoder().decode(State.self, from: Data(raw.utf8)),
              !state.title.isEmpty else { return nil }
        return PlaybackSnapshot(
            source: id,
            title: state.title,
            artist: state.artist,
            album: state.album,
            position: state.currentTime,
            duration: state.duration,
            isPaused: state.paused,
            fetchedAt: start.addingTimeInterval(Date().timeIntervalSince(start) / 2),
            artworkURL: URL(string: state.artwork)
        )
    }

    /// Runs `js` in the first music.youtube.com tab of `b` and returns its string result.
    private func runJS(_ js: String, in b: Browser, cache: Bool = true) async -> String? {
        let script = """
        if application \(appleScriptLiteral(b.name)) is not running then return ""
        tell application \(appleScriptLiteral(b.name))
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "music.youtube.com" then
                        return (\(b.jsVerb) \(appleScriptLiteral(js)) in t) as string
                    end if
                end repeat
            end repeat
        end tell
        return ""
        """
        return await AppleScriptRunner.shared.run(script, cache: cache)?.stringValue
    }

    private func control(_ js: String) async {
        guard let b = browsers.first(where: { $0.name == lastBrowser }) else { return }
        _ = await runJS(js, in: b, cache: false)
    }

    func artwork(for snapshot: PlaybackSnapshot) async -> NSImage? {
        await downloadArtwork(snapshot.artworkURL)
    }

    func playPause() async {
        await control("(function(){var v=document.querySelector('video');if(v){v.paused?v.play():v.pause();}return '';})()")
    }
    func next() async {
        await control("(function(){var b=document.querySelector('.next-button');if(b)b.click();return '';})()")
    }
    func previous() async {
        await control("(function(){var b=document.querySelector('.previous-button');if(b)b.click();return '';})()")
    }
    func seek(to seconds: TimeInterval) async {
        await control("(function(){var v=document.querySelector('video');if(v)v.currentTime=\(seconds);return '';})()")
    }
}
