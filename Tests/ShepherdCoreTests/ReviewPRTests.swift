import Foundation
import Testing
@testable import ShepherdCore

private func pr(
    repoSlug: String = "owner/repo",
    number: Int = 1,
    title: String = "Some PR",
    isBot: Bool = false,
    updatedAt: Date = Date()
) -> ReviewPR {
    ReviewPR(repoSlug: repoSlug, number: number, title: title, url: "https://github.com/\(repoSlug)/pull/\(number)", headRefName: "feature", isBot: isBot, updatedAt: updatedAt)
}

// MARK: - repoSlug(fromRemoteURL:)

@Test func repoSlugParsesTheSSHForm() {
    #expect(repoSlug(fromRemoteURL: "git@github.com:owner/repo.git") == "owner/repo")
}

@Test func repoSlugParsesTheSSHFormWithoutADotGitSuffix() {
    #expect(repoSlug(fromRemoteURL: "git@github.com:owner/repo") == "owner/repo")
}

@Test func repoSlugParsesTheHTTPSForm() {
    #expect(repoSlug(fromRemoteURL: "https://github.com/owner/repo.git") == "owner/repo")
}

@Test func repoSlugParsesTheHTTPSFormWithoutADotGitSuffix() {
    #expect(repoSlug(fromRemoteURL: "https://github.com/owner/repo") == "owner/repo")
}

@Test func repoSlugReturnsNilForANonGitHubRemote() {
    #expect(repoSlug(fromRemoteURL: "https://gitlab.com/owner/repo.git") == nil)
}

// MARK: - matchingLocalRepo

@Test func matchingLocalRepoFindsACaseInsensitiveMatch() {
    let repos = [LocalRepo(path: "/tmp/repo", repoSlug: "Owner/Repo")]
    #expect(matchingLocalRepo(forSlug: "owner/repo", in: repos)?.path == "/tmp/repo")
}

@Test func matchingLocalRepoReturnsNilWhenNoneMatch() {
    #expect(matchingLocalRepo(forSlug: "owner/repo", in: []) == nil)
}

// MARK: - filterReviewPRs

@Test func filterReviewPRsExcludesBotsByDefault() {
    let prs = [pr(number: 1, isBot: true), pr(number: 2, isBot: false)]
    let filtered = filterReviewPRs(prs, ignored: [], options: ReviewFilterOptions())
    #expect(filtered.map(\.number) == [2])
}

@Test func filterReviewPRsIncludesBotsWhenOptedIn() {
    let prs = [pr(number: 1, isBot: true), pr(number: 2, isBot: false)]
    let filtered = filterReviewPRs(prs, ignored: [], options: ReviewFilterOptions(includeBots: true))
    #expect(filtered.map(\.number) == [1, 2])
}

@Test func filterReviewPRsExcludesIgnoredPRs() {
    let target = pr(repoSlug: "owner/repo", number: 5)
    let filtered = filterReviewPRs([target], ignored: [target.id], options: ReviewFilterOptions())
    #expect(filtered.isEmpty)
}

@Test func filterReviewPRsKeepsEverythingWhenNoStalenessLimitIsSet() {
    let old = pr(number: 1, updatedAt: Date(timeIntervalSinceNow: -1_000_000))
    let filtered = filterReviewPRs([old], ignored: [], options: ReviewFilterOptions(hideOlderThanDays: nil))
    #expect(filtered.map(\.number) == [1])
}

@Test func filterReviewPRsHidesPRsOlderThanTheConfiguredThreshold() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let recent = pr(number: 1, updatedAt: now.addingTimeInterval(-1 * 86_400))
    let stale = pr(number: 2, updatedAt: now.addingTimeInterval(-40 * 86_400))
    let filtered = filterReviewPRs([recent, stale], ignored: [], options: ReviewFilterOptions(hideOlderThanDays: 30), now: now)
    #expect(filtered.map(\.number) == [1])
}

// MARK: - decodeReviewSearchResults

@Test func decodeReviewSearchResultsReadsAllFields() throws {
    let json = Data(#"""
    [{"isDraft":false,"number":96,"repository":{"name":"repo","nameWithOwner":"owner/repo"},"title":"Fix the thing","updatedAt":"2026-09-21T06:29:22Z","url":"https://github.com/owner/repo/pull/96"}]
    """#.utf8)

    let results = try decodeReviewSearchResults(from: json)

    #expect(results.count == 1)
    #expect(results[0].repoSlug == "owner/repo")
    #expect(results[0].number == 96)
    #expect(results[0].title == "Fix the thing")
    #expect(results[0].url == "https://github.com/owner/repo/pull/96")
}

@Test func decodeReviewSearchResultsThrowsOnMalformedJSON() {
    #expect(throws: Error.self) {
        try decodeReviewSearchResults(from: Data("not json".utf8))
    }
}

// MARK: - decodeReviewPRDetail

@Test func decodeReviewPRDetailReadsHeadRefAndBotFlag() throws {
    let json = Data(#"""
    {"author":{"is_bot":true,"login":"app/github-actions"},"baseRefName":"main","headRefName":"chore/refresh","isDraft":false,"number":96}
    """#.utf8)

    let detail = try decodeReviewPRDetail(from: json)

    #expect(detail.headRefName == "chore/refresh")
    #expect(detail.isBot == true)
}

@Test func decodeReviewPRDetailThrowsOnMalformedJSON() {
    #expect(throws: Error.self) {
        try decodeReviewPRDetail(from: Data("not json".utf8))
    }
}
