import ShepherdCore

/// Fuzzy-filters sessions for the quick switcher. Matches against the same
/// fields `SessionRowView` displays (workspace label, title, directory) -
/// whichever gives the best score wins, mirroring mac-sesh's
/// name-score/path-score combination in `SearchViewModel.filtered`.
public func filterSessions(_ sessions: [Session], query: String) -> [Session] {
    guard !query.isEmpty else { return sessions }

    return sessions
        .compactMap { session -> (Session, Double)? in
            let candidates = [session.group?.label, session.title, session.workingDirectory?.lastPathComponent]
                .compactMap { $0 }
            guard let best = candidates.compactMap({ fuzzyScore(query, in: $0) }).max() else { return nil }
            return (session, best)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
}
