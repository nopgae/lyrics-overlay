import Foundation

public enum SyncEngine {
    /// Index of the last line whose timestamp is <= `position`, or nil before the first line.
    public static func index(at position: TimeInterval, in lines: [LyricLine]) -> Int? {
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= position { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    /// Start time of the line after `index` (or of the first line when `index` is nil).
    public static func nextTime(after index: Int?, in lines: [LyricLine]) -> TimeInterval? {
        let next = (index ?? -1) + 1
        return next < lines.count ? lines[next].time : nil
    }
}
