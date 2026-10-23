import AppKit

/// Whatever macOS shows as "Now Playing" in Control Center — covers apps with no
/// scripting interface, such as YT Music.app (a WKWebView wrapper whose web player
/// reports through WebKit's media session).
///
/// MediaRemote only answers Apple-signed processes since macOS 15.4, so the reading
/// is done by libNowPlayingHelper.dylib loaded into /usr/bin/perl, which streams JSON
/// lines on change and takes commands on stdin.
final class SystemNowPlayingSource: MusicSource {
    let id = SourceID.systemNowPlaying

    /// Players with their own, richer source; ignored here so they aren't reported twice.
    static let ownedBundles: Set<String> = ["com.apple.Music", "com.spotify.client"]

    /// Called on the main queue whenever the helper reports a change.
    var onChange: (() -> Void)?

    private struct Info: Decodable {
        var empty: Bool?
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var elapsed: Double?
        var timestamp: Double?
        var rate: Double?
        var playing: Bool?
        var bundle: String?
        var app: String?
        var artwork: String?
    }

    private var latest: Info?
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var restartDelay: TimeInterval = 1

    private static let perlScript = """
    use DynaLoader;
    my $h = DynaLoader::dl_load_file($ARGV[0]) || die DynaLoader::dl_error();
    my $s = DynaLoader::dl_find_symbol($h, "np_run") || die "np_run not found";
    DynaLoader::dl_install_xsub("main::run", $s);
    run();
    """

    init() {
        start()
    }

    deinit {
        process?.terminate()
    }

    /// The helper ships in Contents/Frameworks; debug builds run it from next to the binary.
    private static var helperURL: URL? {
        let candidates = [
            Bundle.main.privateFrameworksURL?.appendingPathComponent("libNowPlayingHelper.dylib"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("libNowPlayingHelper.dylib"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func start() {
        guard let helper = Self.helperURL else {
            log.error("libNowPlayingHelper.dylib not found; system Now Playing disabled")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.perlScript, helper.path]
        let out = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardInput = input
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            DispatchQueue.main.async { self?.received(chunk) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.helperExited(status: proc.terminationStatus) }
        }
        do {
            try p.run()
            process = p
            stdin = input.fileHandleForWriting
        } catch {
            log.error("Couldn't start Now Playing helper: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func helperExited(status: Int32) {
        log.error("Now Playing helper exited (\(status)); restarting in \(self.restartDelay)s")
        process = nil
        stdin = nil
        latest = nil
        onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay) { [weak self] in self?.start() }
        restartDelay = min(restartDelay * 2, 60)
    }

    private func received(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let info = try? JSONDecoder().decode(Info.self, from: line) else { continue }
            restartDelay = 1
            latest = info.empty == true ? nil : info
            onChange?()
        }
    }

    private func send(_ command: String) {
        stdin?.write(Data((command + "\n").utf8))
    }

    // MARK: MusicSource

    func snapshot() async -> PlaybackSnapshot? {
        guard let i = latest, let title = i.title, !title.isEmpty,
              !Self.ownedBundles.contains(i.bundle ?? "") else { return nil }
        let now = Date()
        let playing = i.playing ?? false
        // Elapsed was measured at `timestamp`; extrapolate at the reported rate.
        var position = i.elapsed ?? 0
        if playing, let ts = i.timestamp {
            position += (now.timeIntervalSince1970 - ts) * (i.rate ?? 1)
        }
        return PlaybackSnapshot(
            source: id, title: title, artist: i.artist ?? "", album: i.album ?? "",
            position: position, duration: i.duration ?? 0, isPaused: !playing,
            fetchedAt: now, artworkURL: i.artwork.flatMap { URL(string: "file://" + $0) },
            appName: i.app
        )
    }

    func artwork(for snapshot: PlaybackSnapshot) async -> NSImage? {
        guard let url = snapshot.artworkURL else { return nil }
        return NSImage(contentsOfFile: url.path)
    }

    func playPause() async { send("toggle") }
    func next() async { send("next") }
    func previous() async { send("previous") }
    func seek(to seconds: TimeInterval) async { send("seek \(seconds)") }
}
