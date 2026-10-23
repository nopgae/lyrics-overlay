import Foundation

/// Splits a lyric line that's too long for the menu bar into pages shown one after
/// another while the line is sung, instead of cutting it off with "…".
public enum LyricPager {
    /// Pages of at most `maxLength` characters, broken at spaces where possible
    /// (CJK lines without spaces are split by character count).
    public static func pages(_ text: String, maxLength: Int) -> [String] {
        guard maxLength > 0, text.count > maxLength else { return [text] }
        var pages: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count <= maxLength {
                current = candidate
                continue
            }
            if !current.isEmpty { pages.append(current) }
            // A single word longer than a page gets hard-split.
            var rest = Substring(word)
            while rest.count > maxLength {
                pages.append(String(rest.prefix(maxLength)))
                rest = rest.dropFirst(maxLength)
            }
            current = String(rest)
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }

    /// Which page to show `elapsed` seconds into a line lasting `duration`, and when
    /// (seconds into the line) the next page starts — nil on the last page.
    public static func page(at elapsed: TimeInterval, duration: TimeInterval, count: Int)
        -> (index: Int, nextPageAt: TimeInterval?)
    {
        guard count > 1, duration > 0 else { return (0, nil) }
        let each = duration / Double(count)
        let index = min(count - 1, max(0, Int(elapsed / each)))
        return (index, index < count - 1 ? Double(index + 1) * each : nil)
    }
}
