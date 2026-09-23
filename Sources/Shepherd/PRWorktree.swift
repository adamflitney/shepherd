import Foundation

/// Creates (or reuses) an isolated git worktree for a PR's branch under
/// `~/.shepherd/worktrees/`, so reviewing it never disturbs whatever's
/// already checked out in the existing clone. Shares the clone's own
/// object store - no second clone, just a fetch + `git worktree add`.
enum PRWorktree {
    struct WorktreeError: Error { let message: String }

    static func ensureWorktree(repoPath: String, repoSlug: String, prNumber: Int) throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".shepherd/worktrees")
        let dirName = repoSlug.replacingOccurrences(of: "/", with: "-") + "-pr-\(prNumber)"
        let worktreePath = root.appendingPathComponent(dirName)

        // Already set up from a previous review of this PR - reuse as-is
        // rather than re-fetching every time the Review tab is opened.
        if FileManager.default.fileExists(atPath: worktreePath.path) {
            return worktreePath
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Best-effort cleanup if a worktree directory was deleted by hand
        // without `git worktree remove` - not fatal if it finds nothing.
        try? runGit(["-C", repoPath, "worktree", "prune"])

        let localBranch = "pr-\(prNumber)"
        // Leading `+` force-updates the local branch even if a prior fetch
        // for this same PR already created it and it's since moved.
        try runGit(["-C", repoPath, "fetch", "origin", "+pull/\(prNumber)/head:\(localBranch)"])
        try runGit(["-C", repoPath, "worktree", "add", worktreePath.path, localBranch])
        return worktreePath
    }

    private static func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError(message: (message?.isEmpty == false ? message : nil) ?? "git \(arguments.joined(separator: " ")) failed")
        }
    }
}
