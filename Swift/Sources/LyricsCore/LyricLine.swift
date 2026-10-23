import Foundation

public struct LyricLine: Equatable, Sendable {
    public var time: TimeInterval   // seconds from track start
    public var text: String

    public init(time: TimeInterval, text: String) {
        self.time = time
        self.text = text
    }
}

public enum LRCParser {
    // [mm:ss.xx] or [mm:ss:xx]; a line may carry several timestamps.
    private static let timestamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:[.:]\d+)?)\]"#)

    /// Parses LRC text into lines sorted by time. Metadata tags like [ar:...] are skipped.
    public static func parse(_ content: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in content.components(separatedBy: .newlines) {
            let row = raw.trimmingCharacters(in: .whitespaces)
            guard !row.isEmpty else { continue }
            let ns = row as NSString
            let matches = timestamp.matches(in: row, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                lines.append(LyricLine(time: minutes * 60 + seconds, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }
}
