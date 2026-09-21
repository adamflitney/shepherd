import Testing
@testable import ShepherdCore
@testable import ShepherdUI

private func session(_ id: String, _ kind: AttentionState.Kind) -> Session {
    Session(id: SessionID(rawValue: id), title: id, agent: .claude, attention: AttentionState(kind: kind))
}

@Test func notificationsToFireFiresOnFirstTransitionIntoBlocked() {
    let (toFire, updated) = notificationsToFire(for: [session("a", .blocked)], lastNotifiedKind: [:])
    #expect(toFire == [PendingNotification(sessionID: SessionID(rawValue: "a"), kind: .blocked)])
    #expect(updated == [SessionID(rawValue: "a"): .blocked])
}

@Test func notificationsToFireDoesNotRefireForTheSameKind() {
    let (toFire, _) = notificationsToFire(
        for: [session("a", .blocked)],
        lastNotifiedKind: [SessionID(rawValue: "a"): .blocked]
    )
    #expect(toFire.isEmpty)
}

@Test func notificationsToFireFiresAgainAfterLeavingAndReenteringBlocked() {
    // Simulates the full cycle: blocked (fires) -> working (re-arms,
    // clearing the entry) -> blocked again (fires again).
    let afterFirstBlock = notificationsToFire(for: [session("a", .blocked)], lastNotifiedKind: [:])
    #expect(afterFirstBlock.toFire.count == 1)

    let afterWorking = notificationsToFire(for: [session("a", .working)], lastNotifiedKind: afterFirstBlock.updatedState)
    #expect(afterWorking.toFire.isEmpty)
    #expect(afterWorking.updatedState.isEmpty)

    let afterSecondBlock = notificationsToFire(for: [session("a", .blocked)], lastNotifiedKind: afterWorking.updatedState)
    #expect(afterSecondBlock.toFire == [PendingNotification(sessionID: SessionID(rawValue: "a"), kind: .blocked)])
}

@Test func notificationsToFireFiresForDoneJustLikeBlocked() {
    let (toFire, _) = notificationsToFire(for: [session("a", .done)], lastNotifiedKind: [:])
    #expect(toFire == [PendingNotification(sessionID: SessionID(rawValue: "a"), kind: .done)])
}

@Test func notificationsToFireIgnoresIdleWorkingAndUnknown() {
    let (toFire, updated) = notificationsToFire(
        for: [session("a", .idle), session("b", .working), session("c", .unknown)],
        lastNotifiedKind: [:]
    )
    #expect(toFire.isEmpty)
    #expect(updated.isEmpty)
}

@Test func notificationsToFireDropsEntriesForSessionsNoLongerPresent() {
    // A closed session must not leak its watermark forever.
    let (_, updated) = notificationsToFire(for: [], lastNotifiedKind: [SessionID(rawValue: "a"): .blocked])
    #expect(updated.isEmpty)
}
