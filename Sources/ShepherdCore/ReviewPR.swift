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

    public init(repoSlug: String, number: Int, title: String, url: String, headRefName: String, isBot: Bool, updatedAt: Date) {
        self.repoSlug = repoSlug
        self.number = number
        self.title = title
        self.url = url
        self.headRefName = headRefName
        self.isBot = isBot
        self.updatedAt = updatedAt
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
    struct Author: Decodable {
        let isBot: Bool
        enum CodingKeys: String, CodingKey { case isBot = "is_bot" }
    }
}

/// Decodes `gh pr view <number> --repo <slug> --json headRefName,author`.
/// `author.is_bot` is snake_case in `gh`'s own output here, unlike the
/// search endpoint's camelCase - confirmed live, not a typo.
public func decodeReviewPRDetail(from json: Data) throws -> (headRefName: String, isBot: Bool) {
    let wire: GHPRDetailWire
    do {
        wire = try JSONDecoder().decode(GHPRDetailWire.self, from: json)
    } catch {
        throw ReviewDecodeError.malformed
    }
    return (headRefName: wire.headRefName, isBot: wire.author.isBot)
}
