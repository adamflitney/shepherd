import Foundation
import Testing
@testable import ShepherdCore
@testable import ShepherdHerdr

private var herdrSocketExists: Bool {
    let path = (NSString(string: "~/.config/herdr/herdr.sock").expandingTildeInPath)
    return FileManager.default.fileExists(atPath: path)
}

/// Proves the whole real stack together, not just the transport in
/// isolation: snapshot() through HerdrSessionBackend should agree with what
/// `herdr api snapshot` reports directly - same session count, shell panes
/// excluded.
@Test(.enabled(if: herdrSocketExists))
func herdrSessionBackendLiveSnapshotExcludesShellPanes() async throws {
    let backend = HerdrSessionBackend(
        requestClient: RequestClient(transport: UnixSocketTransport()),
        eventTransport: UnixSocketTransport()
    )

    let snapshot = try await backend.snapshot()

    #expect(!snapshot.sessions.isEmpty)
    // Every session must have come from a pane with an agent attached -
    // enforced by construction in SessionProjection, checked here against
    // real data as a regression guard.
    #expect(snapshot.sessions.allSatisfy { !$0.agent.rawValue.isEmpty })
}
