import Foundation
import Testing
@testable import ShepherdCore
@testable import ShepherdUI

private func session(_ id: String, _ kind: AttentionState.Kind, title: String? = nil) -> Session {
    Session(id: SessionID(rawValue: id), title: title ?? id, agent: .claude, attention: AttentionState(kind: kind))
}

@Test func sortSessionsOrdersByUrgencyBlockedFirst() {
    let sessions = [
        session("a", .idle),
        session("b", .blocked),
        session("c", .working),
        session("d", .done),
        session("e", .unknown),
    ]

    let sorted = sortSessions(sessions).map(\.id.rawValue)

    #expect(sorted == ["b", "d", "c", "e", "a"])
}

@Test func sortSessionsTieBreaksByTitleWithinTheSameUrgency() {
    let sessions = [
        session("1", .working, title: "zebra"),
        session("2", .working, title: "apple"),
    ]

    let sorted = sortSessions(sessions).map(\.title)

    #expect(sorted == ["apple", "zebra"])
}

@Test func groupSessionsOrdersByGroupOrdinalWithUngroupedLastWhenUrgencyTies() {
    // All sessions are the same kind (idle), so ordinal is the only
    // remaining tiebreaker - this test only proves the fallback ordering.
    let groupA = SessionGroup(id: "wA", label: "project-a", ordinal: 2)
    let groupB = SessionGroup(id: "wB", label: "project-b", ordinal: 1)

    var grouped = session("1", .idle)
    grouped.group = groupA
    var grouped2 = session("2", .idle)
    grouped2.group = groupB
    let ungrouped = session("3", .idle)

    let sections = groupSessions([grouped, grouped2, ungrouped])

    #expect(sections.map(\.group?.id) == ["wB", "wA", nil])
    #expect(sections.map { $0.sessions.map(\.id.rawValue) } == [["2"], ["1"], ["3"]])
}

@Test func groupSessionsFloatsAGroupWithAnUrgentSessionAboveAnEarlierIdleOnlyGroup() {
    // Regression test: a workspace with only idle sessions must not sit
    // above a workspace containing a blocked session just because its
    // Herdr workspace number happens to be lower - group order should
    // reflect the most urgent session within it, ordinal only breaking ties.
    let idleGroup = SessionGroup(id: "w1", label: "idle-project", ordinal: 1)
    let blockedGroup = SessionGroup(id: "w5", label: "blocked-project", ordinal: 5)

    var idleSession = session("1", .idle)
    idleSession.group = idleGroup
    var blockedSession = session("2", .blocked)
    blockedSession.group = blockedGroup

    let sections = groupSessions([idleSession, blockedSession])

    #expect(sections.map(\.group?.id) == ["w5", "w1"])
}

@Test func groupSessionsWorstUrgencyWinsOverOrdinalEvenWhenTheUrgentSessionIsntFirstInItsGroup() {
    let earlyGroup = SessionGroup(id: "w1", label: "early", ordinal: 1)
    let lateGroup = SessionGroup(id: "w2", label: "late", ordinal: 2)

    var earlyIdle = session("1", .idle)
    earlyIdle.group = earlyGroup
    var lateIdle = session("2", .idle)
    lateIdle.group = lateGroup
    var lateBlocked = session("3", .blocked)
    lateBlocked.group = lateGroup

    let sections = groupSessions([earlyIdle, lateIdle, lateBlocked])

    #expect(sections.map(\.group?.id) == ["w2", "w1"])
}
