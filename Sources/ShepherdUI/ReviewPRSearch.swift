import Foundation
import ShepherdCore

/// The Review tab's three views, picked by a leading character in the
/// filter: nothing = PRs waiting on you, `@` = your own PRs, `%` or `*` =
/// ignored ones. The rest of the query still filters within the view.
public enum ReviewView: Equatable, Sendable {
    case toReview, mine, ignored
}

public func reviewView(forQuery query: String) -> (view: ReviewView, text: String) {
    func rest() -> String { String(query.dropFirst()).trimmingCharacters(in: .whitespaces) }
    switch query.first {
    case "@": return (.mine, rest())
    case "%", "*": return (.ignored, rest())
    default: return (.toReview, query)
    }
}

/// Fuzzy-filters matched PRs for the Review tab, matching against title
/// and repo slug - mirrors `filterSessions`/`filterProjects`. An empty
/// query keeps the incoming (most-recently-updated-first) order.
public func filterReviewPRList(_ matches: [MatchedReviewPR], query: String) -> [MatchedReviewPR] {
    let (view, text) = reviewView(forQuery: query)
    let pool = matches.filter { match in
        switch view {
        case .toReview: !match.isIgnored && !match.pr.isMine
        case .mine: !match.isIgnored && match.pr.isMine
        case .ignored: match.isIgnored
        }
    }
    guard !text.isEmpty else { return pool }

    return pool
        .compactMap { match -> (MatchedReviewPR, Double)? in
            let candidates = [match.pr.title, match.pr.repoSlug]
            guard let best = candidates.compactMap({ fuzzyScore(text, in: $0) }).max() else { return nil }
            return (match, best)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
}
