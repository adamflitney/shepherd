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

@Test func aFinishedRunDoesNotNotifyUnlessAskedTo() {
    let (toFire, _) = notificationsToFire(
        for: [session("a", .idle)], lastNotifiedKind: [:], previousKinds: [SessionID(rawValue: "a"): .working]
    )
    #expect(toFire.isEmpty)
}

@Test func aFinishedRunNotifiesWhenWorkingBecomesIdleAndTheCallerOptsIn() {
    let (toFire, updated) = notificationsToFire(
        for: [session("a", .idle)], lastNotifiedKind: [:],
        previousKinds: [SessionID(rawValue: "a"): .working], notifyOnFinishedWork: true
    )
    #expect(toFire == [PendingNotification(sessionID: SessionID(rawValue: "a"), kind: .idle)])
    #expect(updated.isEmpty)   // edge-triggered: nothing to remember
}

@Test func aSessionThatWasAlreadyIdleIsNotAFinishedRun() {
    let (toFire, _) = notificationsToFire(
        for: [session("a", .idle)], lastNotifiedKind: [:],
        previousKinds: [SessionID(rawValue: "a"): .idle], notifyOnFinishedWork: true
    )
    #expect(toFire.isEmpty)
}

@Test func aNewlySeenIdleSessionIsNotAFinishedRun() {
    #expect(notificationsToFire(for: [session("a", .idle)], lastNotifiedKind: [:], notifyOnFinishedWork: true).toFire.isEmpty)
}

@Test func workingToBlockedIsTheBlockedRuleNotAFinishedRun() {
    let (toFire, _) = notificationsToFire(
        for: [session("a", .blocked)], lastNotifiedKind: [:],
        previousKinds: [SessionID(rawValue: "a"): .working], notifyOnFinishedWork: true
    )
    #expect(toFire == [PendingNotification(sessionID: SessionID(rawValue: "a"), kind: .blocked)])
}
