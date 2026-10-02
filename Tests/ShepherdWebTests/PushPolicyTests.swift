import Foundation
import ShepherdCore
import Testing
@testable import ShepherdWebKit

private func session(_ id: String, _ kind: AttentionState.Kind, summary: String? = nil) -> Session {
    Session(id: SessionID(rawValue: id), title: id, agent: .claude, attention: AttentionState(kind: kind, summary: summary))
}

private actor Outbox {
    private(set) var sent: [PushMessage] = []
    func record(_ message: PushMessage) -> Int { sent.append(message); return 1 }
    var kinds: [String] { sent.map(\.kind) }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval
    init(idle: TimeInterval) { value = idle }
    var idle: TimeInterval { get { lock.lock(); defer { lock.unlock() }; return value } set { lock.lock(); value = newValue; lock.unlock() } }
}

private func notifier(_ outbox: Outbox, onlyWhenAway: Bool = false, clock: Clock = Clock(idle: 0)) -> PushNotifier {
    PushNotifier(onlyWhenAway: onlyWhenAway, awayAfter: 120, idleSeconds: { clock.idle }) { await outbox.record($0) }
}

@Test func aSessionBlockingSendsOnePushAndNotTwice() async {
    let outbox = Outbox()
    let n = notifier(outbox)
    await n.seed(with: [session("a", .working)])
    await n.evaluate([session("a", .blocked, summary: "Which color?")])
    await n.evaluate([session("a", .blocked, summary: "Which color?")])
    #expect(await outbox.kinds == ["blocked"])
    #expect(await outbox.sent.first?.body == "Which color?")
}

@Test func sessionsAlreadyWaitingAtStartupAreNotAnnounced() async {
    let outbox = Outbox()
    let n = notifier(outbox)
    await n.seed(with: [session("a", .blocked)])
    await n.evaluate([session("a", .blocked)])
    #expect(await outbox.sent.isEmpty)
}

@Test func aFinishedRunSendsAFinishedPush() async {
    let outbox = Outbox()
    let n = notifier(outbox)
    await n.seed(with: [session("a", .working)])
    await n.evaluate([session("a", .idle)])
    #expect(await outbox.kinds == ["idle"])
    #expect(await outbox.sent.first?.body == "Finished")
}

@Test func whileYoureAtTheMacABlockedSessionIsHeldBackNotLost() async {
    let outbox = Outbox()
    let clock = Clock(idle: 5)
    let n = notifier(outbox, onlyWhenAway: true, clock: clock)
    await n.seed(with: [session("a", .working)])
    await n.evaluate([session("a", .blocked)])
    #expect(await outbox.sent.isEmpty)

    clock.idle = 300   // walked away, still blocked
    await n.evaluate([session("a", .blocked)])
    #expect(await outbox.kinds == ["blocked"])
}

@Test func aFinishedRunWhileYoureAtTheMacIsDropped() async {
    let outbox = Outbox()
    let clock = Clock(idle: 5)
    let n = notifier(outbox, onlyWhenAway: true, clock: clock)
    await n.seed(with: [session("a", .working)])
    await n.evaluate([session("a", .idle)])
    clock.idle = 300
    await n.evaluate([session("a", .idle)])
    #expect(await outbox.sent.isEmpty)
}

@Test func awayOnlyDoesNothingExtraWhenAlreadyAway() async {
    let outbox = Outbox()
    let n = notifier(outbox, onlyWhenAway: true, clock: Clock(idle: 600))
    await n.seed(with: [session("a", .working)])
    await n.evaluate([session("a", .done)])
    #expect(await outbox.kinds == ["done"])
}

@Test func idleWithAnyAppInFrontCountsAsAway() async {
    let outbox = Outbox()
    let n = notifier(outbox, onlyWhenAway: true, clock: Clock(idle: 600))
    await n.seed(with: [session("a", .working)])
    await n.evaluate([session("a", .blocked)])
    #expect(await outbox.kinds == ["blocked"])
}

@Test func withTheSwitchOffBeingAtTheMacNeverHoldsAnAlert() async {
    let outbox = Outbox()
    let n = notifier(outbox, onlyWhenAway: false, clock: Clock(idle: 5))
    await n.seed(with: [session("a", .working)])
    await n.evaluate([session("a", .blocked)])
    #expect(await outbox.kinds == ["blocked"])
}
