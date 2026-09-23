import Foundation
import ShepherdCore

/// Reads each already-scanned project's `origin` remote URL, for matching
/// a PR's repo against a local clone (`matchingLocalRepo`). Thin I/O edge -
/// same tier as `GitHubReviewFetcher`.
enum LocalRepoScanner {
    static func scan(_ projects: [Project]) -> [LocalRepo] {
        projects.compactMap { project in
            guard let remote = remoteURL(at: project.path), let slug = repoSlug(fromRemoteURL: remote) else {
                return nil
            }
            return LocalRepo(path: project.path, repoSlug: slug)
        }
    }

    private static func remoteURL(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "remote", "get-url", "origin"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
