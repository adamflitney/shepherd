import Foundation

/// Cleans up a `SessionBackend.peek` result for display: a terminal's
/// "visible" screen is padded with blank lines to fill its height, which
/// would otherwise dominate a small preview panel. This only trims leading
/// and trailing blank lines - it doesn't try to identify "the last message"
/// within the remaining text, since that would mean parsing an arbitrary
/// CLI's own rendering, which is exactly the fragility the peek feature is
/// meant to avoid (see the plan's permission-approval investigation notes).
public func trimmedPeekText(_ raw: String) -> String {
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
    var end = lines.count
    while end > 0, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
        end -= 1
    }
    var start = 0
    while start < end, lines[start].trimmingCharacters(in: .whitespaces).isEmpty {
        start += 1
    }
    guard start < end else { return "(no output)" }
    return lines[start..<end].joined(separator: "\n")
}
