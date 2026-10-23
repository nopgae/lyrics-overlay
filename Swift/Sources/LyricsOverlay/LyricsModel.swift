import AppKit
import LyricsCore
import Observation

/// App state: which track is playing, its lyrics, and the current line.
///
/// Music.app and Spotify post distributed notifications on every play, pause and
/// track change, which trigger an immediate poll; while one of them is active the
/// poll loop only re-polls every few seconds to catch seeks. YouTube Music has no
/// notifications and is polled every second.
@MainActor
@Observable
final class LyricsModel {
    // MARK: Published state

    private(set) var snapshot: PlaybackSnapshot?
    private(set) var artwork: NSImage?
    private(set) var lyrics: [LyricLine] = []
    private(set) var currentIndex: Int?
    private(set) var lyricsStatus = "—"
    private(set) var isFetchingLyrics = false

    // MARK: Preferences

    static let defaultLyricOffset = 0.2

    /// Seconds the lyrics are held back relative to the reported position
    /// (audio output buffers ahead of what you hear; Bluetooth/AirPlay need more).
    var lyricOffset: Double {
        didSet {
            UserDefaults.standard.set(lyricOffset, forKey: "lyricOffset")
            restartLineTimer()
        }
    }
    /// nil = auto-detect
    var sourceOverride: SourceID? {
        didSet {
            UserDefaults.standard.set(sourceOverride?.rawValue ?? "auto", forKey: "sourceOverride")
            requestPoll()
        }
    }
    var showLyricsInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showLyricsInMenuBar, forKey: "showLyricsInMenuBar") }
    }
    /// Max characters of lyric shown in the menu bar.
    var menuBarLength: Int {
        didSet { UserDefaults.standard.set(menuBarLength, forKey: "menuBarLength") }
    }

    // MARK: Derived

    var isPlaying: Bool { snapshot.map { !$0.isPaused } ?? false }
    var currentLine: String? { currentIndex.map { lyrics[$0].text } }
    var nextLine: String? {
        let next = (currentIndex ?? -1) + 1
        return next < lyrics.count ? lyrics[next].text : nil
    }

    /// Text for the status item, or nil to show just the icon.
    var menuBarTitle: String? {
        guard showLyricsInMenuBar, let snapshot else { return nil }
        if let line = currentLine, !line.isEmpty, !snapshot.isPaused {
            return line.truncated(to: menuBarLength)
        }
        let song = snapshot.artist.isEmpty ? snapshot.title : "\(snapshot.title) — \(snapshot.artist)"
        return song.truncated(to: menuBarLength)
    }

    // MARK: Private

    private let sources: [MusicSource] = [AppleMusicPlayer(), SpotifyPlayer(), YouTubeMusicPlayer()]
    private let fetcher = LyricsFetcher()

    private var isPolling = false
    private var pollAgain = false
    private var missCount = 0
    private var lastQuery: TrackQuery?
    private var fetchTask: Task<Void, Never>?
    private var lineTimer: Task<Void, Never>?
    private var pollLoop: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// Notification-driven sources only need this to pick up seeks.
    private static let resyncInterval: TimeInterval = 4

    init() {
        let d = UserDefaults.standard
        lyricOffset = d.object(forKey: "lyricOffset") as? Double ?? Self.defaultLyricOffset
        sourceOverride = d.string(forKey: "sourceOverride").flatMap(SourceID.init(rawValue:))
        showLyricsInMenuBar = d.object(forKey: "showLyricsInMenuBar") as? Bool ?? true
        menuBarLength = d.object(forKey: "menuBarLength") as? Int ?? 40
        start()
    }

    private func start() {
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            observers.append(dnc.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestPoll() }
            })
        }
        pollLoop = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollTick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Polling

    private func pollTick() {
        if let s = snapshot, s.source.notifiesChanges,
           Date().timeIntervalSince(s.fetchedAt) < Self.resyncInterval {
            return
        }
        requestPoll()
    }

    /// Starts a poll, or — if one is running — makes it go round once more, so
    /// results never land out of order.
    func requestPoll() {
        if isPolling {
            pollAgain = true
            return
        }
        isPolling = true
        Task {
            repeat {
                pollAgain = false
                apply(await pollSources())
            } while pollAgain
            isPolling = false
        }
    }

    /// A playing source beats a paused one; ties go Music → Spotify → YouTube Music.
    private func pollSources() async -> PlaybackSnapshot? {
        if let only = sourceOverride {
            return await sources.first { $0.id == only }?.snapshot()
        }
        var paused: PlaybackSnapshot?
        for source in sources {
            guard let s = await source.snapshot() else { continue }
            if !s.isPaused { return s }
            paused = paused ?? s
        }
        return paused
    }

    private func apply(_ new: PlaybackSnapshot?) {
        guard let new else {
            // Tolerate two missed polls so AppleScript/browser hiccups don't drop lyrics.
            missCount += 1
            if missCount >= 3, snapshot != nil {
                snapshot = nil
                currentIndex = nil
                lineTimer?.cancel()
            }
            return
        }
        missCount = 0
        let trackChanged = new.trackKey != snapshot?.trackKey
        snapshot = new
        if trackChanged {
            trackDidChange(new)
        }
        restartLineTimer()
    }

    private func trackDidChange(_ s: PlaybackSnapshot) {
        lyrics = []
        currentIndex = nil
        artwork = nil
        let query = TrackQuery(title: s.title, artist: s.artist, album: s.album, duration: s.duration)
        fetchLyrics(query)

        let source = sources.first { $0.id == s.source }
        let key = s.trackKey
        Task {
            let image = await source?.artwork(for: s)
            if snapshot?.trackKey == key { artwork = image }
        }
    }

    // MARK: - Lyrics

    private func fetchLyrics(_ query: TrackQuery) {
        lastQuery = query
        // Cancelling isn't enough on its own (the fetch may already be done); the
        // query check below drops results for a track that's no longer current.
        fetchTask?.cancel()
        isFetchingLyrics = true
        lyricsStatus = "Searching…"
        fetchTask = Task {
            let result = await fetcher.search(query)
            guard !Task.isCancelled, lastQuery == query else { return }
            isFetchingLyrics = false
            if let result {
                lyrics = result.lines
                lyricsStatus = "\(result.source) · \(result.lines.count) lines" + (result.synced ? "" : " · unsynced")
            } else {
                lyrics = []
                lyricsStatus = "No lyrics found"
            }
            restartLineTimer()
        }
    }

    func refetchLyrics() {
        guard let q = lastQuery else { return }
        Task {
            await fetcher.forget(q)
            lyrics = []
            currentIndex = nil
            fetchLyrics(q)
        }
    }

    // MARK: - Line timing

    /// Playback position with the lyric offset applied, extrapolated from the last poll.
    func position(at now: Date = Date()) -> TimeInterval {
        guard let s = snapshot else { return 0 }
        let elapsed = s.isPaused ? 0 : now.timeIntervalSince(s.fetchedAt)
        return max(0, s.position + elapsed - lyricOffset)
    }

    /// Sleeps until the next line starts instead of ticking on a fixed interval.
    private func restartLineTimer() {
        lineTimer?.cancel()
        currentIndex = SyncEngine.index(at: position(), in: lyrics)
        guard isPlaying, !lyrics.isEmpty else { return }
        lineTimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pos = self.position()
                let idx = SyncEngine.index(at: pos, in: self.lyrics)
                if idx != self.currentIndex { self.currentIndex = idx }
                guard let next = SyncEngine.nextTime(after: idx, in: self.lyrics) else { return }
                try? await Task.sleep(for: .seconds(max(0.02, next - pos)))
            }
        }
    }

    #if DEBUG
    func debugSet(snapshot: PlaybackSnapshot, lyrics: [LyricLine], status: String) {
        pollLoop?.cancel()
        self.snapshot = snapshot
        self.lyrics = lyrics
        lyricsStatus = status
        currentIndex = SyncEngine.index(at: position(), in: lyrics)
    }
    #endif

    // MARK: - Transport

    private var activeSource: MusicSource? {
        snapshot.flatMap { s in sources.first { $0.id == s.source } }
    }

    func playPause() { transport { await $0.playPause() } }
    func next() { transport { await $0.next() } }
    func previous() { transport { await $0.previous() } }
    func seek(to seconds: TimeInterval) { transport { await $0.seek(to: seconds) } }

    private func transport(_ action: @escaping (MusicSource) async -> Void) {
        guard let source = activeSource else { return }
        Task {
            await action(source)
            requestPoll()
        }
    }
}

extension String {
    func truncated(to length: Int) -> String {
        count > length ? String(prefix(length)) + "…" : self
    }
}
