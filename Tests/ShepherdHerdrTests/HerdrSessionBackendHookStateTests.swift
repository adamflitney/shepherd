import Foundation
import Testing
@testable import ShepherdCore
@testable import ShepherdHerdr

private let snapshotFixtureAbc = Data(#"""
{"id":"req1","result":{"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"focused_workspace_id":null,"focused_tab_id":null,"focused_pane_id":null,"workspaces":[{"workspace_id":"w4","number":1,"label":"proj","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"w4:t1","agent_status":"blocked"}],"tabs":[],"panes":[{"pane_id":"w4:p1","workspace_id":"w4","tab_id":"w4:t1","agent":"claude","agent_status":"blocked","agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"abc"},"cwd":"/tmp","foreground_cwd":"/tmp","title":"x","terminal_title":"x","terminal_title_stripped":"x","focused":true}],"layouts":[],"agents":[]}}}
"""#.utf8)

private func withTempStateDir(_ body: (URL) async throws -> Void) async rethrows {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shepherd-backend-hookstate-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir)
}

@Test func herdrBackendSnapshotReconcilesWithHookState() async throws {
    try await withTempStateDir { dir in
        try #"{"schema":1,"session_id":"abc","updated_at":"2026-09-17T14:11:41Z","state":"needs-permission","detail":{"tool_name":"Edit"}}"#
            .write(to: dir.appendingPathComponent("abc.json"), atomically: true, encoding: .utf8)

        let backend = HerdrSessionBackend(
            requestClient: RequestClient(transport: InMemoryLineTransport(responses: [snapshotFixtureAbc])),
            eventTransport: InMemoryEventTransport(),
            hookStateStore: HookStateStore(
                directory: dir,
                now: { ISO8601DateFormatter().date(from: "2026-09-17T14:11:41Z")!.addingTimeInterval(1) }
            )
        )

        let snapshot = try await backend.snapshot()

        #expect(snapshot.sessions.first?.attention.blocker == .needsPermission)
        #expect(snapshot.sessions.first?.attention.summary == "Edit")
    }
}
