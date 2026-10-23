import Foundation

public struct LyricLine: Codable, Equatable, Sendable {
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

    /// Reads an .lrc file, trying UTF-8 first and then the legacy encodings
    /// Korean/Chinese/Japanese LRC files are commonly saved in.
    public static func load(contentsOf url: URL) -> [LyricLine]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let legacy: [CFStringEncodings] = [.dosKorean, .GB_18030_2000, .shiftJIS]
        let encodings = [String.Encoding.utf8]
            + legacy.map { String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding($0.rawValue))) }
            + [.isoLatin1]
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) {
                let lines = parse(text)
                return lines.isEmpty ? nil : lines
            }
        }
        return nil
    }
}
