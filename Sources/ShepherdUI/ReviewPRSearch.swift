import ShepherdCore

/// Fuzzy-filters matched PRs for the Review tab, matching against title
/// and repo slug - mirrors `filterSessions`/`filterProjects`. An empty
/// query keeps the incoming (most-recently-updated-first) order.
public func filterReviewPRList(_ matches: [MatchedReviewPR], query: String) -> [MatchedReviewPR] {
    guard !query.isEmpty else { return matches }

    return matches
        .compactMap { match -> (MatchedReviewPR, Double)? in
            let candidates = [match.pr.title, match.pr.repoSlug]
            guard let best = candidates.compactMap({ fuzzyScore(query, in: $0) }).max() else { return nil }
            return (match, best)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
}
