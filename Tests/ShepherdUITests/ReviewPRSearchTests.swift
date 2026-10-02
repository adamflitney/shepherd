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

@Test func ignoredPRsOnlyAppearBehindThePercentPrefix() {
    let shown = MatchedReviewPR(pr: ReviewPR(repoSlug: "o/a", number: 1, title: "Alpha", url: "", headRefName: "x", isBot: false, updatedAt: Date()), localPath: nil)
    let hidden = MatchedReviewPR(pr: ReviewPR(repoSlug: "o/b", number: 2, title: "Beta", url: "", headRefName: "x", isBot: false, updatedAt: Date()), localPath: nil, isIgnored: true)
    #expect(filterReviewPRList([shown, hidden], query: "").map(\.id) == [shown.id])
    #expect(filterReviewPRList([shown, hidden], query: "%").map(\.id) == [hidden.id])
    #expect(filterReviewPRList([shown, hidden], query: "*bet").map(\.id) == [hidden.id])
    #expect(filterReviewPRList([shown, hidden], query: "%alpha").isEmpty)
}

@Test func atPrefixShowsOnlyMyOwnPRsAndNoPrefixHidesThem() {
    func make(_ n: Int, mine: Bool) -> MatchedReviewPR {
        MatchedReviewPR(pr: ReviewPR(repoSlug: "o/r", number: n, title: "PR \(n)", url: "", headRefName: "x", isBot: false, updatedAt: Date(), isMine: mine), localPath: nil)
    }
    let theirs = make(1, mine: false), mine = make(2, mine: true)
    #expect(filterReviewPRList([theirs, mine], query: "").map(\.id) == [theirs.id])
    #expect(filterReviewPRList([theirs, mine], query: "@").map(\.id) == [mine.id])
}
