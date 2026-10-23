import Foundation
import os

let log = Logger(subsystem: "com.nopgae.lyrics-overlay", category: "app")

/// Runs AppleScript in-process (so permissions belong to this app, not osascript).
/// NSAppleScript isn't thread-safe: every call goes through one serial queue, and
/// compiled scripts are cached by source so polling doesn't recompile each time.
final class AppleScriptRunner: @unchecked Sendable {
    static let shared = AppleScriptRunner()

    private let queue = DispatchQueue(label: "com.nopgae.lyrics-overlay.applescript")
    private var compiled: [String: NSAppleScript] = [:]

    /// `cache: false` for scripts that embed a value (a seek position) and so never repeat.
    func run(_ source: String, cache: Bool = true) async -> NSAppleEventDescriptor? {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.runOnQueue(source, cache: cache)) }
        }
    }

    private func runOnQueue(_ source: String, cache: Bool) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let s = NSAppleScript(source: source), s.compileAndReturnError(&error) else {
                log.error("AppleScript compile failed: \(String(describing: error), privacy: .public)")
                return nil
            }
            if cache { compiled[source] = s }
            script = s
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            log.debug("AppleScript error: \(String(describing: error), privacy: .public)")
            return nil
        }
        return result
    }
}

extension NSAppleEventDescriptor {
    /// 1-based list item as string / double (AppleScript lists are 1-indexed).
    func string(_ i: Int) -> String { atIndex(i)?.stringValue ?? "" }
    func double(_ i: Int) -> Double { atIndex(i)?.doubleValue ?? 0 }
}

/// AppleScript string literal: escapes backslashes and double quotes.
func appleScriptLiteral(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
