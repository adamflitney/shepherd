import Testing
@testable import ShepherdCore
@testable import ShepherdUI

private func session(_ id: String, _ kind: AttentionState.Kind) -> Session {
    Session(id: SessionID(rawValue: id), title: id, agent: .claude, attention: AttentionState(kind: kind))
}

@Test func menuBarStatusIsUnknownWithZeroCountWhenNoSessions() {
    let status = menuBarStatus(for: [])
    #expect(status.worstKind == .unknown)
    #expect(status.count == 0)
}

@Test func menuBarStatusReflectsTheMostUrgentKindPresent() {
    let status = menuBarStatus(for: [session("a", .idle), session("b", .blocked), session("c", .working)])
    #expect(status.worstKind == .blocked)
    #expect(status.count == 1)
}

@Test func menuBarStatusCountsAllSessionsAtTheWorstKind() {
    let status = menuBarStatus(for: [session("a", .blocked), session("b", .blocked), session("c", .idle)])
    #expect(status.worstKind == .blocked)
    #expect(status.count == 2)
}
