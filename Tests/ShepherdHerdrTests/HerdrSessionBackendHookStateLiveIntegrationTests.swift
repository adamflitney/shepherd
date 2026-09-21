import Foundation
import Testing
@testable import ShepherdCore
@testable import ShepherdHerdr

private var herdrSocketExists: Bool {
    let path = (NSString(string: "~/.config/herdr/herdr.sock").expandingTildeInPath)
    return FileManager.default.fileExists(atPath: path)
}

/// Live confirmation of the exact "trusts Herdr working over a stale hook
/// file" case ported from shepherd-legacy's reconcileState test suite: this
/// very session's own hook file lags a few tool calls behind (it still says
/// "asked-a-question" from before this test was written), while Herdr
/// reports "working" in realtime because tool calls are actively running.
/// Reconciliation must side with Herdr.
@Test(.enabled(if: herdrSocketExists))
func herdrBackendLiveReconciliationTrustsWorkingOverAStaleHookFile() async throws {
    let backend = HerdrSessionBackend(
        requestClient: RequestClient(transport: UnixSocketTransport()),
        eventTransport: UnixSocketTransport()
    )

    let snapshot = try await backend.snapshot()
    let thisSession = snapshot.sessions.first {
        $0.id == SessionID(rawValue: "agent:b730b9e4-fc61-4302-9d83-bd90cb9bfe3a")
    }

    #expect(thisSession?.attention.kind == .working)
    #expect(thisSession?.attention.blocker == nil)
}
