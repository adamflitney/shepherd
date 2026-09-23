import Foundation
import Testing
@testable import ShepherdCore
@testable import ShepherdHerdr

private let idleSnapshotAbc = Data(#"""
{"id":"req1","result":{"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"focused_workspace_id":null,"focused_tab_id":null,"focused_pane_id":null,"workspaces":[{"workspace_id":"w4","number":1,"label":"proj","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"w4:t1","agent_status":"idle"}],"tabs":[],"panes":[{"pane_id":"w4:p1","workspace_id":"w4","tab_id":"w4:t1","agent":"claude","agent_status":"idle","agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"abc"},"cwd":"/tmp","foreground_cwd":"/tmp","title":"x","terminal_title":"x","terminal_title_stripped":"x","focused":true}],"layouts":[],"agents":[]}}}
"""#.utf8)

private func withTempAttentionFile(_ body: (URL) async throws -> Void) async rethrows {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("shepherd-backend-attention-since-test-\(UUID().uuidString)")
        .appendingPathComponent("attention-since.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try await body(url)
}

/// End-to-end proof that a fresh `HerdrSessionBackend` (i.e. right after an
/// app restart, with no in-process history at all) still reports the
/// persisted recency instead of resetting every unchanged session's
/// `since` to the moment of the restart - the actual bug a user hit after
/// several restarts in one day collapsed every idle session's recency to
/// the same timestamp.
@Test func herdrBackendSnapshotSeedsSinceFromDiskOnAFreshInstance() async throws {
    try await withTempAttentionFile { url in
        let persistedSince = Date(timeIntervalSince1970: 1_000)
        AttentionSinceStore(fileURL: url).save([
            SessionID(rawValue: "agent:abc"): PersistedSessionAttention(kind: "idle", since: persistedSince),
        ])

        let backend = HerdrSessionBackend(
            requestClient: RequestClient(transport: InMemoryLineTransport(responses: [idleSnapshotAbc])),
            eventTransport: InMemoryEventTransport(),
            attentionSinceStore: AttentionSinceStore(fileURL: url)
        )

        let snapshot = try await backend.snapshot()

        #expect(snapshot.sessions.first?.attention.since == persistedSince)
    }
}

@Test func herdrBackendSnapshotPersistsSinceForTheNextLaunch() async throws {
    try await withTempAttentionFile { url in
        let store = AttentionSinceStore(fileURL: url)
        let backend = HerdrSessionBackend(
            requestClient: RequestClient(transport: InMemoryLineTransport(responses: [idleSnapshotAbc])),
            eventTransport: InMemoryEventTransport(),
            attentionSinceStore: store
        )

        _ = try await backend.snapshot()

        let persisted = store.load()
        #expect(persisted[SessionID(rawValue: "agent:abc")]?.kind == "idle")
    }
}
