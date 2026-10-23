import Foundation

/// Strips video-title noise YouTube Music adds that lyric databases don't have.
public enum TitleCleaner {
    private static let noise = try! NSRegularExpression(
        pattern: #"\s*[\(\[](?:official\s*(?:music\s*)?(?:video|audio|mv|visualizer)|lyric(?:s)?(?:\s*video)?|m/?v|audio|visualizer|hd|4k|remaster(?:ed)?(?:\s*\d{4})?)[\)\]]"#,
        options: .caseInsensitive
    )
    private static let feat = try! NSRegularExpression(
        pattern: #"\s*[\(\[]?\s*(?:feat\.?|ft\.?|featuring)\s+[^\)\]]*[\)\]]?"#,
        options: .caseInsensitive
    )

    public static func title(_ title: String) -> String {
        var t = replace(noise, in: title)
        t = replace(feat, in: t)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " -–—"))
        return t.isEmpty ? title : t
    }

    public static func artist(_ artist: String) -> String {
        artist.replacingOccurrences(of: #"\s*-\s*Topic$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func replace(_ re: NSRegularExpression, in s: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
    }
}
