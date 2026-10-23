import XCTest
@testable import LyricsCore

final class LRCParserTests: XCTestCase {
    func testParsesTimestampsAndSkipsTags() {
        let lines = LRCParser.parse("[ar:Someone]\n[00:12.50]Hello\n[01:02:25]World\n\n[00:05.00][00:30.00]Chorus")
        XCTAssertEqual(lines.map(\.text), ["Chorus", "Hello", "Chorus", "World"])
        XCTAssertEqual(lines.map(\.time), [5, 12.5, 30, 62.25])
    }
}

final class LRCFileTests: XCTestCase {
    func testLoadsCP949KoreanFile() throws {
        let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lrc")
        defer { try? FileManager.default.removeItem(at: url) }
        try XCTUnwrap("[00:01.00]안녕하세요\n[00:03.50]가사".data(using: cp949)).write(to: url)
        XCTAssertEqual(LRCParser.load(contentsOf: url)?.map(\.text), ["안녕하세요", "가사"])
    }

    func testLoadsUTF8File() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lrc")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("[00:02.00]Hello 世界".utf8).write(to: url)
        XCTAssertEqual(LRCParser.load(contentsOf: url)?.first?.text, "Hello 世界")
    }
}

final class SyncEngineTests: XCTestCase {
    let lines = [LyricLine(time: 10, text: "a"), LyricLine(time: 20, text: "b"), LyricLine(time: 30, text: "c")]

    func testIndex() {
        XCTAssertNil(SyncEngine.index(at: 5, in: lines))
        XCTAssertEqual(SyncEngine.index(at: 10, in: lines), 0)
        XCTAssertEqual(SyncEngine.index(at: 29.9, in: lines), 1)
        XCTAssertEqual(SyncEngine.index(at: 99, in: lines), 2)
        XCTAssertNil(SyncEngine.index(at: 1, in: []))
    }

    func testNextTime() {
        XCTAssertEqual(SyncEngine.nextTime(after: nil, in: lines), 10)
        XCTAssertEqual(SyncEngine.nextTime(after: 1, in: lines), 30)
        XCTAssertNil(SyncEngine.nextTime(after: 2, in: lines))
    }
}

final class LyricPagerTests: XCTestCase {
    func testShortLineIsOnePage() {
        XCTAssertEqual(LyricPager.pages("Hello world", maxLength: 40), ["Hello world"])
    }

    func testSplitsAtSpaces() {
        let pages = LyricPager.pages("I'm in love with the shape of you, we push and pull like a magnet do", maxLength: 30)
        XCTAssertEqual(pages, ["I'm in love with the shape of", "you, we push and pull like a", "magnet do"])
        XCTAssertTrue(pages.allSatisfy { $0.count <= 30 })
    }

    func testHardSplitsTextWithoutSpaces() {
        XCTAssertEqual(LyricPager.pages("あいうえおかきくけこさしすせそ", maxLength: 6), ["あいうえおか", "きくけこさし", "すせそ"])
    }

    func testPageTiming() {
        XCTAssertEqual(LyricPager.page(at: 0.5, duration: 4, count: 2).index, 0)
        XCTAssertEqual(LyricPager.page(at: 0.5, duration: 4, count: 2).nextPageAt, 2)
        XCTAssertEqual(LyricPager.page(at: 2.1, duration: 4, count: 2).index, 1)
        XCTAssertNil(LyricPager.page(at: 2.1, duration: 4, count: 2).nextPageAt)
        XCTAssertEqual(LyricPager.page(at: 99, duration: 4, count: 3).index, 2)
    }
}

final class TitleCleanerTests: XCTestCase {
    func testTitle() {
        XCTAssertEqual(TitleCleaner.title("Dynamite (Official MV)"), "Dynamite")
        XCTAssertEqual(TitleCleaner.title("Song [Official Music Video]"), "Song")
        XCTAssertEqual(TitleCleaner.title("Hype Boy (feat. X)"), "Hype Boy")
        XCTAssertEqual(TitleCleaner.title("Normal Song"), "Normal Song")
        XCTAssertEqual(TitleCleaner.title("(Official Video)"), "(Official Video)")
        XCTAssertEqual(TitleCleaner.artist("NewJeans - Topic"), "NewJeans")
    }
}

final class LyricsFetcherTests: XCTestCase {
    func testDurationTolerance() {
        XCTAssertFalse(LyricsFetcher.durationOK(200, 179))
        XCTAssertTrue(LyricsFetcher.durationOK(181, 179))
        XCTAssertTrue(LyricsFetcher.durationOK(0, 179))
        XCTAssertTrue(LyricsFetcher.durationOK(200, 0))
    }

    func testEstimatedTimingSpreadsOverTrack() {
        let lines = LyricsFetcher.estimateTiming(["a", "b", "c"], duration: 120)
        XCTAssertEqual(lines.map(\.time), [15, 45, 75])
    }

    /// Network failures must not be cached as "not found".
    func testOfflineMissIsNotCached() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingProtocol.self]
        let fetcher = LyricsFetcher(session: URLSession(configuration: config))
        let q = TrackQuery(title: "Hype Boy", artist: "NewJeans", duration: 179)
        let first = await fetcher.search(q)
        XCTAssertNil(first)
        FailingProtocol.calls = 0
        _ = await fetcher.search(q)
        XCTAssertGreaterThan(FailingProtocol.calls, 0, "second search should hit the network again")
    }

    /// Found lyrics survive a new fetcher (= app relaunch) without touching the network.
    func testDiskCacheServesFoundLyricsOffline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let q = TrackQuery(title: "Song", artist: "Artist", duration: 100)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CannedLRCLIBProtocol.self]
        let online = LyricsFetcher(session: URLSession(configuration: config), cacheDirectory: dir)
        let first = await online.search(q)
        XCTAssertEqual(first?.lines.first?.text, "Hello")

        let offlineConfig = URLSessionConfiguration.ephemeral
        offlineConfig.protocolClasses = [FailingProtocol.self]
        FailingProtocol.calls = 0
        let relaunched = LyricsFetcher(session: URLSession(configuration: offlineConfig), cacheDirectory: dir)
        let second = await relaunched.search(q)
        XCTAssertEqual(second, first)
        XCTAssertEqual(FailingProtocol.calls, 0)

        await relaunched.forget(q)
        let afterForget = await relaunched.search(q)
        XCTAssertNil(afterForget, "forgotten lyrics must not come back from disk")
    }

    /// Live LRCLIB check; skipped unless LIVE=1.
    func testLiveLRCLIB() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE"] == "1")
        let r = await LyricsFetcher().search(TrackQuery(title: "Dynamite (Official MV)", artist: "BTS", duration: 199))
        XCTAssertEqual(r?.source, "LRCLIB")
        XCTAssertEqual(r?.synced, true)
        XCTAssertGreaterThan(r?.lines.count ?? 0, 20)
    }
}

/// Answers every LRCLIB request with one synced hit.
final class CannedLRCLIBProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let item = #"{"duration":100,"syncedLyrics":"[00:01.00]Hello\n[00:03.00]World","plainLyrics":"Hello\nWorld"}"#
        let body = request.url?.path == "/api/search" ? "[\(item)]" : item
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class FailingProtocol: URLProtocol {
    nonisolated(unsafe) static var calls = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
