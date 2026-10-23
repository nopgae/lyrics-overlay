import XCTest
@testable import LyricsCore

final class LRCParserTests: XCTestCase {
    func testParsesTimestampsAndSkipsTags() {
        let lines = LRCParser.parse("[ar:Someone]\n[00:12.50]Hello\n[01:02:25]World\n\n[00:05.00][00:30.00]Chorus")
        XCTAssertEqual(lines.map(\.text), ["Chorus", "Hello", "Chorus", "World"])
        XCTAssertEqual(lines.map(\.time), [5, 12.5, 30, 62.25])
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

    /// Live LRCLIB check; skipped unless LIVE=1.
    func testLiveLRCLIB() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE"] == "1")
        let r = await LyricsFetcher().search(TrackQuery(title: "Dynamite (Official MV)", artist: "BTS", duration: 199))
        XCTAssertEqual(r?.source, "LRCLIB")
        XCTAssertEqual(r?.synced, true)
        XCTAssertGreaterThan(r?.lines.count ?? 0, 20)
    }
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
