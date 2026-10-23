import CryptoKit
import Foundation

public struct LyricsResult: Codable, Equatable, Sendable {
    public var lines: [LyricLine]
    public var source: String   // "LRCLIB" | "NetEase"
    public var synced: Bool     // false → timestamps are estimated from plain text

    public init(lines: [LyricLine], source: String, synced: Bool) {
        self.lines = lines
        self.source = source
        self.synced = synced
    }
}

/// A query for one track. `duration` is in seconds (0 if unknown).
public struct TrackQuery: Hashable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval

    public init(title: String, artist: String, album: String = "", duration: TimeInterval = 0) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    var cacheKey: String { "\(title.lowercased())\u{1}\(artist.lowercased())" }
}

/// Fetches time-synced lyrics: LRCLIB (exact + search in parallel) first, NetEase as
/// fallback. Plain lyrics are used only when no provider has synced ones.
public actor LyricsFetcher {
    /// A search hit whose length differs from the playing track by more than this is a
    /// different recording (remix, live, radio edit) and is rejected.
    public static let durationTolerance: TimeInterval = 3

    struct TransientError: Error {}

    private let session: URLSession
    // nil value = every provider answered "not found" (a miss worth remembering)
    private var cache: [String: LyricsResult?] = [:]
    /// Found lyrics are also kept here across launches (misses are not: the
    /// databases grow, so a miss is re-checked next launch).
    private let cacheDirectory: URL?

    public init(session: URLSession? = nil, cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 5
            config.httpAdditionalHeaders = ["User-Agent": "Lyrics Overlay (https://github.com/nopgae/lyrics-overlay)"]
            self.session = URLSession(configuration: config)
        }
    }

    public func forget(_ q: TrackQuery) {
        cache[q.cacheKey] = nil
        if let file = diskFile(q) { try? FileManager.default.removeItem(at: file) }
    }

    public func search(_ q: TrackQuery) async -> LyricsResult? {
        if let hit = cache[q.cacheKey] { return hit }
        if let file = diskFile(q), let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(LyricsResult.self, from: data) {
            cache[q.cacheKey] = saved
            return saved
        }

        var hadError = false
        var plain: [String]?

        var queries = [(q.title, TitleCleaner.artist(q.artist))]
        let cleaned = (TitleCleaner.title(q.title), TitleCleaner.artist(q.artist))
        if cleaned != queries[0] { queries.append(cleaned) }

        for (title, artist) in queries {
            do {
                let (synced, p) = try await searchLRCLIB(title: title, artist: artist, album: q.album, duration: q.duration)
                if let synced { return remember(q, LyricsResult(lines: synced, source: "LRCLIB", synced: true)) }
                plain = plain ?? p
            } catch { hadError = true }
        }
        for (title, artist) in queries {
            do {
                if let r = try await searchNetEase(title: title, artist: artist, duration: q.duration) {
                    return remember(q, r)
                }
            } catch { hadError = true }
        }
        if let plain {
            return remember(q, LyricsResult(lines: Self.estimateTiming(plain, duration: q.duration), source: "LRCLIB", synced: false))
        }
        // A network blip must not hide lyrics for the rest of the session.
        if !hadError { cache[q.cacheKey] = .some(nil) }
        return nil
    }

    private func remember(_ q: TrackQuery, _ r: LyricsResult) -> LyricsResult {
        cache[q.cacheKey] = r
        if let file = diskFile(q), let data = try? JSONEncoder().encode(r) {
            try? data.write(to: file, options: .atomic)
        }
        return r
    }

    private func diskFile(_ q: TrackQuery) -> URL? {
        guard let cacheDirectory else { return nil }
        let hash = SHA256.hash(data: Data(q.cacheKey.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(hash + ".json")
    }

    static func estimateTiming(_ plain: [String], duration: TimeInterval) -> [LyricLine] {
        let step = duration > 0 ? duration / Double(plain.count + 1) : 3
        return plain.enumerated().map { LyricLine(time: (Double($0.offset) + 0.5) * step, text: $0.element) }
    }

    static func durationOK(_ candidate: TimeInterval, _ duration: TimeInterval) -> Bool {
        duration <= 0 || candidate <= 0 || abs(candidate - duration) <= durationTolerance
    }

    // MARK: - LRCLIB

    private struct LRCLIBItem: Decodable {
        var duration: Double?
        var syncedLyrics: String?
        var plainLyrics: String?
    }

    /// Returns (synced lines, plain lines). Throws only if both endpoints failed transiently.
    private func searchLRCLIB(title: String, artist: String, album: String, duration: TimeInterval)
        async throws -> ([LyricLine]?, [String]?)
    {
        async let exact = lrclibExact(title: title, artist: artist, album: album, duration: duration)
        async let search = lrclibSearch(title: title, artist: artist, duration: duration)
        var errors = 0
        var plain: [String]?
        if case .success(let (synced, p)) = await exact {
            plain = p
            if let synced { return (synced, plain) }
        } else { errors += 1 }
        if case .success(let synced) = await search {
            if let synced { return (synced, plain) }
        } else { errors += 1 }
        if errors == 2 { throw TransientError() }
        return (nil, plain)
    }

    private func lrclibExact(title: String, artist: String, album: String, duration: TimeInterval)
        async -> Result<([LyricLine]?, [String]?), Error>
    {
        var items = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        if !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(duration)))) }
        do {
            guard let data = try await get(lrclib("/api/get", items)),
                  let item = try? JSONDecoder().decode(LRCLIBItem.self, from: data) else {
                return .success((nil, nil))
            }
            let synced = LRCParser.parse(item.syncedLyrics ?? "")
            let plain = (item.plainLyrics ?? "").components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return .success((synced.isEmpty ? nil : synced, plain.isEmpty ? nil : plain))
        } catch {
            return .failure(error)
        }
    }

    private func lrclibSearch(title: String, artist: String, duration: TimeInterval)
        async -> Result<[LyricLine]?, Error>
    {
        var items = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        do {
            guard let data = try await get(lrclib("/api/search", items)),
                  let list = try? JSONDecoder().decode([LRCLIBItem].self, from: data) else {
                return .success(nil)
            }
            for item in list where Self.durationOK(item.duration ?? 0, duration) {
                let lines = LRCParser.parse(item.syncedLyrics ?? "")
                if !lines.isEmpty { return .success(lines) }
            }
            return .success(nil)
        } catch {
            return .failure(error)
        }
    }

    private func lrclib(_ path: String, _ items: [URLQueryItem]) -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "lrclib.net"
        c.path = path
        c.queryItems = items
        return c.url!
    }

    // MARK: - NetEase

    private static let netEaseHeaders = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
        "Referer": "https://music.163.com/",
    ]
    // Credit lines NetEase embeds at the top of LRC files
    private static let netEaseMeta = ["作词", "作曲", "编曲", "制作", "出品", "录音", "混音", "母带"]

    private struct NetEaseSearch: Decodable {
        struct Result: Decodable { var songs: [Song]? }
        struct Song: Decodable { var id: Int; var duration: Double? }
        var result: Result?
    }
    private struct NetEaseLyric: Decodable {
        struct Lrc: Decodable { var lyric: String? }
        var lrc: Lrc?
    }

    private func searchNetEase(title: String, artist: String, duration: TimeInterval) async throws -> LyricsResult? {
        var req = URLRequest(url: URL(string: "https://music.163.com/api/search/get")!)
        req.httpMethod = "POST"
        Self.netEaseHeaders.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "s", value: "\(title) \(artist)".trimmingCharacters(in: .whitespaces)),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        req.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        guard let data = try await send(req),
              let found = try? JSONDecoder().decode(NetEaseSearch.self, from: data),
              let song = found.result?.songs?.first(where: { Self.durationOK(($0.duration ?? 0) / 1000, duration) })
        else { return nil }

        var lyricReq = URLRequest(url: URL(string: "https://music.163.com/api/song/lyric?id=\(song.id)&lv=1")!)
        Self.netEaseHeaders.forEach { lyricReq.setValue($0.value, forHTTPHeaderField: $0.key) }
        guard let lyricData = try await send(lyricReq),
              let lyric = try? JSONDecoder().decode(NetEaseLyric.self, from: lyricData) else { return nil }
        let lines = LRCParser.parse(lyric.lrc?.lyric ?? "")
            .filter { line in !Self.netEaseMeta.contains { line.text.hasPrefix($0) } }
        return lines.isEmpty ? nil : LyricsResult(lines: lines, source: "NetEase", synced: true)
    }

    // MARK: - HTTP

    private func get(_ url: URL) async throws -> Data? {
        try await send(URLRequest(url: url))
    }

    /// Returns the body for 2xx, nil for other definitive answers (404 …), throws on
    /// transient failures (network, timeout, 429, 5xx).
    private func send(_ req: URLRequest) async throws -> Data? {
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw TransientError()
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 || status >= 500 { throw TransientError() }
        return (200..<300).contains(status) ? data : nil
    }
}
