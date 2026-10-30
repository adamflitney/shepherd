import Foundation
import ShepherdTasks

/// Notices pull requests for tasks: a task whose folder is on its own branch gets that branch recorded, and once the branch
/// has a PR the task records it and moves to Review. Merging stays the user's call (a task is only ever done by them), so a
/// merged PR is logged and nothing else.
public struct TaskPRSync: Sendable {
    public typealias Runner = @Sendable (_ executable: String, _ arguments: [String], _ directory: String) -> String?

    var run: Runner
    var gitPath: String
    var ghPath: String?
    static let sharedBranches: Set<String> = ["main", "master", "develop", "trunk"]

    public init(run: @escaping Runner = TaskPRSync.process, gitPath: String = "/usr/bin/git", ghPath: String? = TaskPRSync.findGH()) {
        self.run = run
        self.gitPath = gitPath
        self.ghPath = ghPath
    }

    public func sync(_ store: TaskStore) {
        let open = store.list().filter { $0.status != .done }
        for task in open {
            guard let folder = task.projectPath, !folder.isEmpty, FileManager.default.fileExists(atPath: folder) else { continue }
            // Two open tasks in one folder share its checked-out branch, so it says nothing about either.
            let alone = open.filter { $0.projectPath == folder }.count == 1
            var branch = task.branch
            if branch == nil, alone, let current = currentBranch(in: folder), hasWork(on: current, in: folder, since: task.created) {
                branch = current
                _ = try? store.update(task.id) { $0.setBranch(current) }
            }
            guard let branch, let ghPath, let pr = pullRequest(for: branch, in: folder, gh: ghPath) else { continue }
            let movesToReview = pr.state == "OPEN" && [.inbox, .ready, .active].contains(task.status)
            let logsMerge = pr.state == "MERGED" && !task.logEntries.contains(where: { $0.contains("PR merged") })
            let logsClosed = pr.state == "CLOSED" && !task.logEntries.contains(where: { $0.contains("PR closed") })
            guard task.pr != pr.url || movesToReview || logsMerge || logsClosed else { continue }
            _ = try? store.update(task.id) { t in
                if t.pr != pr.url { t.setPR(pr.url) }
                if pr.state == "OPEN", [.inbox, .ready, .active].contains(t.status) {
                    t.setStatus(.review)
                    t.appendLog("PR opened: \(pr.url)")
                }
                if pr.state == "MERGED", !t.logEntries.contains(where: { $0.contains("PR merged") }) {
                    t.appendLog("PR merged: \(pr.url)")
                }
                if pr.state == "CLOSED", !t.logEntries.contains(where: { $0.contains("PR closed") }) {
                    t.appendLog("PR closed: \(pr.url)")
                }
            }
        }
    }

    /// A folder that happens to be on an old branch is not evidence about the task: the branch only counts when something
    /// was committed on it after the task was created.
    func hasWork(on branch: String, in folder: String, since created: String?) -> Bool {
        guard let created, let start = Self.parseStamp(created),
              let out = run(gitPath, ["log", "-1", "--format=%ct", branch], folder)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = TimeInterval(out) else { return false }
        return Date(timeIntervalSince1970: seconds) > start
    }

    static func parseStamp(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: text)
    }

    func currentBranch(in folder: String) -> String? {
        guard let out = run(gitPath, ["branch", "--show-current"], folder)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty, !Self.sharedBranches.contains(out) else { return nil }
        return out
    }

    struct PullRequest { var url: String; var state: String }

    func pullRequest(for branch: String, in folder: String, gh: String) -> PullRequest? {
        guard let out = run(gh, ["pr", "list", "--head", branch, "--state", "all", "--limit", "1", "--json", "url,state"], folder),
              let rows = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [[String: Any]],
              let row = rows.first, let url = row["url"] as? String, let state = row["state"] as? String else { return nil }
        return PullRequest(url: url, state: state)
    }

    public static func findGH() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static let process: Runner = { executable, arguments, directory in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
