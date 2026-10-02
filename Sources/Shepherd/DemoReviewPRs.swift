import Foundation
import ShepherdCore

/// Sanitized Review-tab data for `--fake`, so README screenshots never
/// show real PRs.
enum DemoReviewPRs {
    static let askAnswer = "A git worktree is an extra working directory attached to the same repository, so you can have a second branch checked out at the same time without cloning or stashing."

    private static func pr(
        _ repo: String, _ number: Int, _ title: String, hoursAgo: Double, decision: String = "",
        checks: CheckSummary? = CheckSummary(passing: 8, total: 8, hasFailure: false),
        bot: Bool = false, mine: Bool = false, draft: Bool = false, cloned: Bool = true
    ) -> MatchedReviewPR {
        MatchedReviewPR(
            pr: ReviewPR(
                repoSlug: "acme/\(repo)", number: number, title: title,
                url: "https://github.com/acme/\(repo)/pull/\(number)", headRefName: "feature",
                isBot: bot, updatedAt: Date().addingTimeInterval(-hoursAgo * 3600),
                reviewDecision: decision, checkSummary: checks, isMine: mine, isDraft: draft
            ),
            localPath: cloned ? "/Users/devuser/Dev/\(repo)" : nil
        )
    }

    static let all: [MatchedReviewPR] = [
        pr("payments-api", 412, "feat: support partial refunds", hoursAgo: 2),
        pr("web-app", 198, "fix: debounce the filter input", hoursAgo: 5, decision: "APPROVED"),
        pr("platform-config", 57, "feat!: enable strict null checks", hoursAgo: 8, checks: CheckSummary(passing: 5, total: 6, hasFailure: true), cloned: false),
        pr("payments-api", 409, "fix: retry failed webhooks", hoursAgo: 20, decision: "CHANGES_REQUESTED"),
        pr("web-app", 195, "chore(deps): bump vite to 5.4.8", hoursAgo: 30, bot: true),
        pr("media-pipeline", 88, "feat: add an AV1 preset", hoursAgo: 52, cloned: false),
        pr("web-app", 201, "feat: add a welcome checklist", hoursAgo: 3, decision: "REVIEW_REQUIRED", mine: true),
        pr("payments-api", 415, "refactor: split ledger posting", hoursAgo: 26, mine: true, draft: true),
        pr("media-pipeline", 91, "fix: stop duplicate retry jobs", hoursAgo: 10, decision: "APPROVED", mine: true),
    ]
}
