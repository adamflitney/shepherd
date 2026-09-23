import Foundation

/// A PR you're a requested reviewer on, decoded from `gh`'s output - see
/// `decodeReviewSearchResults`/`decodeReviewPRDetail`. Pure data; fetching
/// it is `GitHubReviewFetcher`'s job in the `Shepherd` target, same tier as
/// `ClaudeCLIRunner`.
public struct ReviewPR: Identifiable, Equatable, Sendable {
    /// Stable across fetches - also what `IgnoredPRStore` persists.
    public var id: String { "\(repoSlug)#\(number)" }

    public var repoSlug: String
    public var number: Int
    public var title: String
    public var url: String
    public var headRefName: String
    public var isBot: Bool
    public var updatedAt: Date
    /// GitHub's raw `reviewDecision` - `""`/`"REVIEW_REQUIRED"`/`"APPROVED"`/
    /// `"CHANGES_REQUESTED"` (confirmed live). Kept as the raw string rather
    /// than a strict enum so an unrecognised future value degrades via
    /// `reviewStatusLabel` instead of failing to decode.
    public var reviewDecision: String
    public var checkSummary: CheckSummary?

    public init(
        repoSlug: String, number: Int, title: String, url: String, headRefName: String,
        isBot: Bool, updatedAt: Date, reviewDecision: String = "", checkSummary: CheckSummary? = nil
    ) {
        self.repoSlug = repoSlug
        self.number = number
        self.title = title
        self.url = url
        self.headRefName = headRefName
        self.isBot = isBot
        self.updatedAt = updatedAt
        self.reviewDecision = reviewDecision
        self.checkSummary = checkSummary
    }
}

/// A compact rollup of a PR's status checks - `passing`/`total` mirrors
/// what GitHub's own PR list shows (e.g. "11/11"); `hasFailure` decides
/// whether that count reads as a failure rather than still-pending.
public struct CheckSummary: Equatable, Sendable {
    public var passing: Int
    public var total: Int
    public var hasFailure: Bool

    public init(passing: Int, total: Int, hasFailure: Bool) {
        self.passing = passing
        self.total = total
        self.hasFailure = hasFailure
    }
}

/// One check-rollup entry, tolerant of GitHub's two shapes (a modern
/// `CheckRun`'s `status`/`conclusion`, or a legacy `StatusContext`'s
/// `state`) - see `summarizeChecks`.
public struct CheckRollupEntry: Equatable, Sendable {
    public var status: String?
    public var conclusion: String?
    public var state: String?

    public init(status: String?, conclusion: String?, state: String?) {
        self.status = status
        self.conclusion = conclusion
        self.state = state
    }
}

/// `nil` for a PR with no checks at all (nothing to summarize), rather
/// than a zero/zero summary that would misleadingly read as "all passing."
/// `SKIPPED`/`NEUTRAL` count as passing, matching GitHub's own denominator
/// in its PR list (confirmed live: a PR with 8 `SUCCESS` + 3 `SKIPPED`
/// checks shows "11/11" there, not "8/11") - both are non-blocking
/// outcomes, not failures or still-pending work.
public func summarizeChecks(_ entries: [CheckRollupEntry]) -> CheckSummary? {
    guard !entries.isEmpty else { return nil }
    let outcomes = entries.map { ($0.conclusion ?? $0.state ?? "").uppercased() }
    let passingOutcomes: Set<String> = ["SUCCESS", "NEUTRAL", "SKIPPED"]
    let failingOutcomes: Set<String> = ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"]
    let passing = outcomes.filter { passingOutcomes.contains($0) }.count
    let hasFailure = outcomes.contains { failingOutcomes.contains($0) }
    return CheckSummary(passing: passing, total: entries.count, hasFailure: hasFailure)
}

/// A short label matching GitHub's own PR-list wording for `reviewDecision`.
public func reviewStatusLabel(_ reviewDecision: String) -> String {
    switch reviewDecision {
    case "APPROVED": "Approved"
    case "CHANGES_REQUESTED": "Changes requested"
    default: "Awaiting approval" // REVIEW_REQUIRED, "", or anything unrecognised
    }
}

/// One of shepherd's own locally-scanned git projects, with its GitHub
/// `owner/repo` slug resolved from `origin`'s remote URL (I/O - reading the
/// remote is `LocalRepoScanner`'s job, this is just the result).
public struct LocalRepo: Equatable, Sendable {
    public var path: String
    public var repoSlug: String

    public init(path: String, repoSlug: String) {
        self.path = path
        self.repoSlug = repoSlug
    }
}

/// A PR matched to a repo shepherd already has cloned locally - the only
/// kind Phase 1 can start a review session for (cloning a missing repo is
/// Phase 2).
public struct MatchedReviewPR: Identifiable, Equatable, Sendable {
    public var pr: ReviewPR
    public var localPath: String
    public var id: String { pr.id }

    public init(pr: ReviewPR, localPath: String) {
        self.pr = pr
        self.localPath = localPath
    }
}

/// Parses a git remote URL - SSH (`git@github.com:owner/repo.git`) or
/// HTTPS (`https://github.com/owner/repo.git`), with or without the
/// trailing `.git` - into an `"owner/repo"` slug for matching against a
/// PR's `repository.nameWithOwner`. `nil` for anything not on github.com.
public func repoSlug(fromRemoteURL url: String) -> String? {
    var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }

    if trimmed.hasPrefix("git@github.com:") {
        let slug = trimmed.dropFirst("git@github.com:".count)
        return slug.isEmpty ? nil : String(slug)
    }
    if let range = trimmed.range(of: "github.com/") {
        let slug = trimmed[range.upperBound...]
        return slug.isEmpty ? nil : String(slug)
    }
    return nil
}

/// Case-insensitive match, since GitHub repo slugs aren't case-sensitive
/// in practice but a remote URL and `gh`'s own casing don't always agree.
public func matchingLocalRepo(forSlug slug: String, in repos: [LocalRepo]) -> LocalRepo? {
    repos.first { $0.repoSlug.caseInsensitiveCompare(slug) == .orderedSame }
}

/// What the Review tab actually shows: bot-authored PRs excluded by
/// default, explicitly-ignored PRs always excluded, and (opt-in, off by
/// default so nothing real vanishes silently) PRs untouched for longer
/// than `hideOlderThanDays`.
public struct ReviewFilterOptions: Equatable, Sendable {
    public var includeBots: Bool
    public var hideOlderThanDays: Int?

    public init(includeBots: Bool = false, hideOlderThanDays: Int? = nil) {
        self.includeBots = includeBots
        self.hideOlderThanDays = hideOlderThanDays
    }
}

public func filterReviewPRs(
    _ prs: [ReviewPR],
    ignored: Set<String>,
    options: ReviewFilterOptions,
    now: Date = Date()
) -> [ReviewPR] {
    prs.filter { pr in
        if !options.includeBots && pr.isBot { return false }
        if ignored.contains(pr.id) { return false }
        if let days = options.hideOlderThanDays {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            if pr.updatedAt < cutoff { return false }
        }
        return true
    }
}

// MARK: - Decoding `gh`'s output

public enum ReviewDecodeError: Error {
    case malformed
}

private struct GHSearchResultWire: Decodable {
    let number: Int
    let title: String
    let url: String
    let updatedAt: String
    let repository: Repository
    struct Repository: Decodable {
        let nameWithOwner: String
    }
}

/// Decodes `gh search prs --review-requested=@me --json number,title,repository,url,updatedAt`.
/// Doesn't include `headRefName` - that field isn't available from this
/// endpoint at all (confirmed live), hence the separate `gh pr view` call
/// per result decoded by `decodeReviewPRDetail`.
public func decodeReviewSearchResults(from json: Data) throws -> [(repoSlug: String, number: Int, title: String, url: String, updatedAt: Date)] {
    let wire: [GHSearchResultWire]
    do {
        wire = try JSONDecoder().decode([GHSearchResultWire].self, from: json)
    } catch {
        throw ReviewDecodeError.malformed
    }
    let formatter = ISO8601DateFormatter()
    return try wire.map { entry in
        guard let updatedAt = formatter.date(from: entry.updatedAt) else { throw ReviewDecodeError.malformed }
        return (repoSlug: entry.repository.nameWithOwner, number: entry.number, title: entry.title, url: entry.url, updatedAt: updatedAt)
    }
}

private struct GHPRDetailWire: Decodable {
    let headRefName: String
    let author: Author
    let reviewDecision: String?
    let statusCheckRollup: [CheckRollupEntryWire]?
    struct Author: Decodable {
        let isBot: Bool
        enum CodingKeys: String, CodingKey { case isBot = "is_bot" }
    }
    struct CheckRollupEntryWire: Decodable {
        let status: String?
        let conclusion: String?
        let state: String?
    }
}

/// Decodes `gh pr view <number> --repo <slug> --json headRefName,author,reviewDecision,statusCheckRollup`.
/// `author.is_bot` is snake_case in `gh`'s own output here, unlike the
/// search endpoint's camelCase - confirmed live, not a typo.
public func decodeReviewPRDetail(from json: Data) throws -> (headRefName: String, isBot: Bool, reviewDecision: String, checkSummary: CheckSummary?) {
    let wire: GHPRDetailWire
    do {
        wire = try JSONDecoder().decode(GHPRDetailWire.self, from: json)
    } catch {
        throw ReviewDecodeError.malformed
    }
    let entries = (wire.statusCheckRollup ?? []).map {
        CheckRollupEntry(status: $0.status, conclusion: $0.conclusion, state: $0.state)
    }
    return (
        headRefName: wire.headRefName,
        isBot: wire.author.isBot,
        reviewDecision: wire.reviewDecision ?? "",
        checkSummary: summarizeChecks(entries)
    )
}
