import Testing
import Foundation
@testable import ShepherdCore
@testable import ShepherdUI

private func matched(title: String, repoSlug: String = "owner/repo", number: Int = 1) -> MatchedReviewPR {
    let pr = ReviewPR(repoSlug: repoSlug, number: number, title: title, url: "https://example.com", headRefName: "feature", isBot: false, updatedAt: Date())
    return MatchedReviewPR(pr: pr, localPath: "/tmp/repo")
}

@Test func filterReviewPRListReturnsAllInExistingOrderWhenQueryIsEmpty() {
    let matches = [matched(title: "first", number: 1), matched(title: "second", number: 2)]
    #expect(filterReviewPRList(matches, query: "").map(\.pr.number) == [1, 2])
}

@Test func filterReviewPRListMatchesByTitle() {
    let matches = [matched(title: "Fix the flaky test", number: 1), matched(title: "Unrelated", number: 2)]
    #expect(filterReviewPRList(matches, query: "flaky").map(\.pr.number) == [1])
}

@Test func filterReviewPRListMatchesByRepoSlug() {
    let matches = [matched(title: "A change", repoSlug: "owner/club-api", number: 1), matched(title: "Another", repoSlug: "owner/unrelated", number: 2)]
    #expect(filterReviewPRList(matches, query: "club").map(\.pr.number) == [1])
}
