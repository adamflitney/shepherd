import Foundation

/// Ported verbatim from mac-sesh's `FuzzySearch.swift` - the scoring
/// heuristics are already tuned and tested there; no reason to redesign them.
///
/// Returns a match score if all characters of `query` appear in `candidate` in
/// order, or nil if there is no match. Higher scores mean a better match.
///
/// Scoring rewards:
/// - Consecutive character runs (strong signal: "api" in "yolo-club-api")
/// - Word-boundary starts (after `-`, `_`, `/`, or start of string)
/// - Shorter total candidate length (tighter match density)
///
/// Penalties:
/// - Later first-match position (prefer matches near the start)
public func fuzzyScore(_ query: String, in candidate: String) -> Double? {
    guard !query.isEmpty else { return 0 }

    let q = query.lowercased()
    let c = candidate.lowercased()

    // Walk candidate collecting matching positions for each query character in order.
    var qi = q.startIndex
    var matchOffsets: [Int] = []

    for (offset, ch) in c.enumerated() {
        guard qi < q.endIndex else { break }
        if ch == q[qi] {
            matchOffsets.append(offset)
            qi = q.index(after: qi)
        }
    }

    guard qi == q.endIndex else { return nil }  // not all chars matched

    var score = 0.0
    let separators: Set<Character> = ["-", "_", " ", "/", "."]

    let isFullRun = matchOffsets.last! - matchOffsets.first! == matchOffsets.count - 1

    if isFullRun {
        // All query chars form a single consecutive substring — big bonus
        score += 30.0
    } else {
        // Reward any consecutive sub-runs within the match
        var run = 1
        for i in 1..<matchOffsets.count {
            if matchOffsets[i] == matchOffsets[i - 1] + 1 {
                run += 1
                score += Double(run) * 2.0
            } else {
                run = 1
            }
        }
    }

    // Word-boundary bonus applies only to the first matched character (the run's anchor).
    // Rewarding every scattered char at a boundary would over-score "a-project-inc" for query "api".
    let firstOffset = matchOffsets[0]
    let firstPos = c.index(c.startIndex, offsetBy: firstOffset)
    if firstPos == c.startIndex {
        score += 15.0
    } else {
        let prev = c.index(before: firstPos)
        if separators.contains(c[prev]) { score += 15.0 }
    }

    // Length bonus: prefer shorter candidates (tighter match density)
    score += 20.0 / Double(c.count)

    // Position penalty: prefer matches that start early
    score -= Double(matchOffsets[0]) * 0.2

    return score
}
