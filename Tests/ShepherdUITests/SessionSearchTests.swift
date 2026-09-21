import Foundation
import Testing
@testable import ShepherdCore
@testable import ShepherdUI

private func session(
    _ id: String,
    title: String,
    groupLabel: String? = nil,
    directory: String? = nil
) -> Session {
    var s = Session(id: SessionID(rawValue: id), title: title, agent: .claude, attention: AttentionState(kind: .idle))
    if let groupLabel { s.group = SessionGroup(id: "g-\(id)", label: groupLabel) }
    if let directory { s.workingDirectory = URL(fileURLWithPath: directory) }
    return s
}

@Test func filterSessionsReturnsAllInOriginalOrderWhenQueryIsEmpty() {
    let sessions = [session("a", title: "Alpha"), session("b", title: "Beta")]
    #expect(filterSessions(sessions, query: "").map(\.id.rawValue) == ["a", "b"])
}

@Test func filterSessionsDropsNonMatches() {
    let sessions = [
        session("a", title: "yolo-club-api", groupLabel: "yolo-club-api"),
        session("b", title: "unrelated"),
    ]
    #expect(filterSessions(sessions, query: "club").map(\.id.rawValue) == ["a"])
}

@Test func filterSessionsMatchesAgainstGroupLabelTitleOrDirectory() {
    let byGroup = session("a", title: "irrelevant", groupLabel: "authz-config")
    let byTitle = session("b", title: "Third party security plan")
    let byDirectory = session("c", title: "irrelevant", directory: "/Users/devuser/Dev/yolo-club-api")

    #expect(filterSessions([byGroup], query: "authz").map(\.id.rawValue) == ["a"])
    #expect(filterSessions([byTitle], query: "security").map(\.id.rawValue) == ["b"])
    #expect(filterSessions([byDirectory], query: "yolo").map(\.id.rawValue) == ["c"])
}

@Test func filterSessionsOrdersByBestFuzzyScoreDescending() {
    // "club" is an exact match on the group label of "b" but only a loose
    // scattered match on "a"'s title - "b" should rank first.
    let weakMatch = session("a", title: "c-l-u-b spread across a longer title")
    let strongMatch = session("b", title: "irrelevant", groupLabel: "club")

    let result = filterSessions([weakMatch, strongMatch], query: "club")

    #expect(result.map(\.id.rawValue) == ["b", "a"])
}
