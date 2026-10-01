import Foundation
import ShepherdCore
import Testing
@testable import ShepherdWeb

private final class RecordingAssertion: PowerAssertion, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return log }
    func hold() { lock.lock(); log.append("hold"); lock.unlock() }
    func release() { lock.lock(); log.append("release"); lock.unlock() }
}

private func session(_ kind: AttentionState.Kind) -> Session {
    Session(id: SessionID(rawValue: "s"), title: "s", agent: .claude, attention: AttentionState(kind: kind))
}

@Test func holdsWhileAnySessionIsWorking() async {
    let assertion = RecordingAssertion()
    let controller = KeepAwakeController(assertion: assertion, grace: .milliseconds(20))
    await controller.update(sessions: [session(.idle), session(.working)])
    try? await Task.sleep(for: .milliseconds(60))
    #expect(assertion.events == ["hold"])
}

@Test func releasesOnlyAfterTheGracePeriodOnceNothingIsWorking() async {
    let assertion = RecordingAssertion()
    let controller = KeepAwakeController(assertion: assertion, grace: .milliseconds(80))
    await controller.update(sessions: [session(.working)])
    await controller.update(sessions: [session(.idle)])
    #expect(assertion.events == ["hold"])
    try? await Task.sleep(for: .milliseconds(200))
    #expect(assertion.events == ["hold", "release"])
}

@Test func workStartingAgainWithinTheGraceCancelsTheRelease() async {
    let assertion = RecordingAssertion()
    let controller = KeepAwakeController(assertion: assertion, grace: .milliseconds(80))
    await controller.update(sessions: [session(.working)])
    await controller.update(sessions: [session(.done)])
    await controller.update(sessions: [session(.working)])
    try? await Task.sleep(for: .milliseconds(200))
    #expect(!assertion.events.contains("release"))
}

@Test func aBlockedSessionKeepsTheMacAwakeSoItCanBeAnsweredFromThePhone() async {
    let assertion = RecordingAssertion()
    let controller = KeepAwakeController(assertion: assertion, grace: .milliseconds(10))
    await controller.update(sessions: [session(.blocked)])
    try? await Task.sleep(for: .milliseconds(60))
    #expect(assertion.events == ["hold"])
}

@Test func idleAndDoneSessionsDoNotKeepTheMacAwake() async {
    let assertion = RecordingAssertion()
    let controller = KeepAwakeController(assertion: assertion, grace: .milliseconds(10))
    await controller.update(sessions: [session(.idle), session(.done)])
    try? await Task.sleep(for: .milliseconds(80))
    #expect(!assertion.events.contains("hold"))
}
