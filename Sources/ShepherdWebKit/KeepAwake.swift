import Foundation
import IOKit.pwr_mgt
import ShepherdCore

protocol PowerAssertion: Sendable {
    func hold()
    func release()
}

/// Real macOS idle-sleep prevention. The display may still sleep; only the
/// system is kept awake, so agents keep running with the screen off.
final class SystemSleepAssertion: PowerAssertion, @unchecked Sendable {
    private let lock = NSLock()
    private var id = IOPMAssertionID(0)
    private var held = false

    func hold() {
        lock.lock(); defer { lock.unlock() }
        guard !held else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Shepherd: agent sessions are working" as CFString,
            &id
        )
        held = result == kIOReturnSuccess
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        guard held else { return }
        IOPMAssertionRelease(id)
        held = false
    }
}

/// Holds the assertion while any session is working or blocked, and lets go
/// `grace` after the last one stops - so the gap between one agent finishing
/// and another starting (or a status flicker) doesn't bounce the Mac's sleep
/// state. Agents run on this Mac, so a sleeping Mac stalls working ones, and
/// a blocked one is waiting on an answer that can only arrive from the phone
/// if the Mac is awake to receive it. Idle/done sessions don't hold it:
/// there's nearly always some, so holding for them would mean never sleeping.
actor KeepAwakeController {
    private let assertion: PowerAssertion
    private let grace: Duration
    private var pendingRelease: Task<Void, Never>?

    init(assertion: PowerAssertion, grace: Duration = .seconds(60)) {
        self.assertion = assertion
        self.grace = grace
    }

    func update(sessions: [Session]) {
        if sessions.contains(where: { $0.attention.kind == .working || $0.attention.kind == .blocked }) {
            pendingRelease?.cancel()
            pendingRelease = nil
            assertion.hold()
        } else if pendingRelease == nil {
            pendingRelease = Task { [assertion, grace] in
                try? await Task.sleep(for: grace)
                guard !Task.isCancelled else { return }
                assertion.release()
                await self.releaseCompleted()
            }
        }
    }

    private func releaseCompleted() { pendingRelease = nil }

    /// Lets go immediately (server stopping) rather than after the grace.
    func shutdown() {
        pendingRelease?.cancel()
        pendingRelease = nil
        assertion.release()
    }
}

func runKeepAwake(backend: any SessionBackend, controller: KeepAwakeController) async {
    if let initial = try? await backend.snapshot() {
        await controller.update(sessions: initial.sessions)
    }
    for await _ in backend.events() {
        guard let snapshot = try? await backend.snapshot() else { continue }
        await controller.update(sessions: snapshot.sessions)
    }
}
