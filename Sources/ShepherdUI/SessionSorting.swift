import ShepherdCore

/// Needs-you-first urgency, distinct from `AttentionState.Kind`'s own
/// declaration order (which exists for the badge alphabet, not the list).
/// Ranked by how much a state actually needs you: `blocked` and `done` both
/// want a look (answer a question, review what finished) so they sit above
/// `working`, which is progressing on its own. `idle` always ranks last -
/// nothing is happening and nothing is waiting on you.
private let urgencyOrder: [AttentionState.Kind: Int] = [
    .blocked: 0,
    .done: 1,
    .working: 2,
    .unknown: 3,
    .idle: 4,
]

/// Lower is more urgent. Shared by `sortSessions` and `menuBarStatus` so the
/// list order and the menu-bar badge always agree on what "worst" means.
public func urgencyRank(_ kind: AttentionState.Kind) -> Int {
    urgencyOrder[kind] ?? .max
}

public func sortSessions(_ sessions: [Session]) -> [Session] {
    sessions.sorted { lhs, rhs in
        let lhsRank = urgencyRank(lhs.attention.kind)
        let rhsRank = urgencyRank(rhs.attention.kind)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}

public struct SessionSection: Equatable {
    public let group: SessionGroup?
    public let sessions: [Session]
}

/// Groups sessions by their (display-only) `SessionGroup`. Sections are
/// ordered by the most urgent session within them (matching `sortSessions`'
/// urgency, not just each session's own row position), with `ordinal` only
/// breaking ties - a group with a blocked session must float above an
/// earlier-numbered group containing only idle ones, or "needs-you-first"
/// only holds within a group and not across the visible list, which is what
/// actually matters when scanning the panel. Sessions within each group keep
/// their incoming order - callers apply `sortSessions` first if urgency
/// ordering within a group is wanted too.
public func groupSessions(_ sessions: [Session]) -> [SessionSection] {
    var order: [String?] = []
    var byGroupID: [String?: (SessionGroup?, [Session])] = [:]

    for session in sessions {
        let key = session.group?.id
        if byGroupID[key] == nil {
            order.append(key)
            byGroupID[key] = (session.group, [])
        }
        byGroupID[key]?.1.append(session)
    }

    func worstRank(_ section: SessionSection) -> Int {
        section.sessions.map { urgencyRank($0.attention.kind) }.min() ?? .max
    }

    return order
        .compactMap { byGroupID[$0] }
        .map { SessionSection(group: $0.0, sessions: $0.1) }
        .sorted { lhs, rhs in
            let lhsRank = worstRank(lhs)
            let rhsRank = worstRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            switch (lhs.group?.ordinal, rhs.group?.ordinal) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case let (l?, r?): return l < r
            }
        }
}
