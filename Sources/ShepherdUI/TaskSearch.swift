import Foundation
import ShepherdCore

/// The tasks the panel lists: open ones, active work first, filtered by a fuzzy match on "#id title
/// project". `#12` or `12` finds a task by number.
public func filterTasks(_ tasks: [TaskSummary], query: String, includeDone: Bool = false) -> [TaskSummary] {
    var ordered: [TaskSummary] = tasks.filter { includeDone || !$0.isDone }
    // a stable sort: tasks of the same rank keep their incoming (id) order
    let rank: [Int: Int] = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) })
    ordered.sort { a, b in
        if a.sortRank != b.sortRank { return a.sortRank < b.sortRank }
        return (rank[a.id] ?? 0) < (rank[b.id] ?? 0)
    }

    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return ordered }

    let numberText = q.hasPrefix("#") ? String(q.dropFirst()) : q
    let number = Int(numberText)

    var scored: [(task: TaskSummary, score: Double)] = []
    for task in ordered {
        if let number, task.id == number {
            scored.append((task, 1_000))
            continue
        }
        var project = ""
        if let path = task.projectPath { project = (path as NSString).lastPathComponent }
        let haystack = "#\(task.id) \(task.title) \(project)"
        var best: Double?
        for candidate in [task.title, haystack] {
            if let s = fuzzyScore(q, in: candidate), s > (best ?? -Double.infinity) { best = s }
        }
        if let best { scored.append((task, best)) }
    }
    scored.sort { $0.score > $1.score }
    return scored.map { $0.task }
}
