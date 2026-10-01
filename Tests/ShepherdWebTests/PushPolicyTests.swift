import Foundation
import ShepherdCore
import Testing
@testable import ShepherdWeb

private func session(_ id: String, _ kind: AttentionState.Kind) -> Session {
    Session(id: SessionID(rawValue: id), title: id, agent: .claude, attention: AttentionState(kind: kind))
}

@Test func aSessionGoingFromWorkingToIdleCountsAsFinished() {
    let finished = sessionsThatFinishedWorking(
        previousKinds: [SessionID(rawValue: "a"): .working],
        sessions: [session("a", .idle)]
    )
    #expect(finished.map(\.id.rawValue) == ["a"])
}

@Test func aSessionThatWasAlreadyIdleIsNotFinished() {
    let finished = sessionsThatFinishedWorking(
        previousKinds: [SessionID(rawValue: "a"): .idle],
        sessions: [session("a", .idle)]
    )
    #expect(finished.isEmpty)
}

@Test func aNewlySeenIdleSessionIsNotFinished() {
    #expect(sessionsThatFinishedWorking(previousKinds: [:], sessions: [session("a", .idle)]).isEmpty)
}

@Test func workingToBlockedIsLeftToTheBlockedPolicyNotFinished() {
    let finished = sessionsThatFinishedWorking(
        previousKinds: [SessionID(rawValue: "a"): .working],
        sessions: [session("a", .blocked)]
    )
    #expect(finished.isEmpty)
}
