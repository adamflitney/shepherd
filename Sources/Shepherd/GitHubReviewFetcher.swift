import Foundation
import ShepherdCore

/// Shells out to the `gh` CLI for the Review tab - same tier as
/// `ClaudeCLIRunner`/`HookInstaller`; the JSON decoding this hands off to
/// is pure and fully tested in `ShepherdCore`'s `ReviewPR.swift`.
enum GitHubReviewFetcher {
    struct FetchError: Error { let message: String }

    /// A GUI app's PATH typically doesn't include wherever `gh` actually
    /// lives - same reasoning as `ClaudeCLIRunner.resolvedClaudePath`.
    private static let resolvedGHPath: String? = resolveOnPath("gh")

    /// All PRs you're a requested reviewer on, unfiltered (bots included) -
    /// `filterReviewPRs` is the caller's job, so this stays a plain fetch.
    /// `gh search prs` has no `headRefName` field at all (confirmed live),
    /// so each result needs a second `gh pr view` call - run concurrently
    /// so a review queue of a dozen-plus PRs doesn't load one at a time.
    static func fetchReviewPRs() async throws -> [ReviewPR] {
        guard let ghPath = resolvedGHPath else {
            throw FetchError(message: "Couldn't find the gh CLI on PATH.")
        }

        // `gh search prs` defaults to a 30-result limit - confirmed live
        // that a real review queue can exceed that, silently truncating
        // the list with no error. 100 comfortably covers a normal queue.
        let searchOutput = try await run(ghPath, [
            "search", "prs", "--review-requested=@me", "--state", "open", "-L", "100",
            "--json", "number,title,repository,url,updatedAt",
        ])
        let results = try decodeReviewSearchResults(from: searchOutput)

        return try await withThrowingTaskGroup(of: ReviewPR.self) { group in
            for result in results {
                group.addTask {
                    let detailOutput = try await run(ghPath, [
                        "pr", "view", "\(result.number)", "--repo", result.repoSlug,
                        "--json", "headRefName,author,reviewDecision,statusCheckRollup",
                    ])
                    let detail = try decodeReviewPRDetail(from: detailOutput)
                    return ReviewPR(
                        repoSlug: result.repoSlug,
                        number: result.number,
                        title: result.title,
                        url: result.url,
                        headRefName: detail.headRefName,
                        isBot: detail.isBot,
                        updatedAt: result.updatedAt,
                        reviewDecision: detail.reviewDecision,
                        checkSummary: detail.checkSummary
                    )
                }
            }
            var prs: [ReviewPR] = []
            for try await pr in group { prs.append(pr) }
            return prs
        }
    }

    private static func run(_ executablePath: String, _ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { proc in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: FetchError(message: "gh \(arguments.joined(separator: " ")) failed"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: FetchError(message: "Couldn't launch gh: \(error)"))
            }
        }
    }
}

private func resolveOnPath(_ tool: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-l", "-c", "command -v \(tool)"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
}
