import Foundation
import Testing
@testable import ShepherdCore
@testable import ShepherdHerdr

private let snapshotFixture = Data(#"""
{"id":"req1","result":{"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"focused_workspace_id":null,"focused_tab_id":null,"focused_pane_id":null,"workspaces":[{"workspace_id":"w4","number":1,"label":"proj","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"w4:t1","agent_status":"working"}],"tabs":[],"panes":[{"pane_id":"w4:p1","workspace_id":"w4","tab_id":"w4:t1","agent":"claude","agent_status":"working","agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"abc"},"cwd":"/tmp","foreground_cwd":"/tmp","title":"x","terminal_title":"x","terminal_title_stripped":"x","focused":true}],"layouts":[],"agents":[]}}}
"""#.utf8)

private let paneUpdatedFixture = Data(#"""
{"data":{"type":"pane_updated","pane":{"pane_id":"w4:p1","workspace_id":"w4","tab_id":"w4:t1","agent":"claude","agent_status":"blocked","agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"abc"},"cwd":"/tmp","foreground_cwd":"/tmp","title":"x","terminal_title":"x","terminal_title_stripped":"x","focused":true}},"event":"pane_updated"}
"""#.utf8)

private final class RecordingActivator: TerminalActivator, @unchecked Sendable {
    private(set) var activateCount = 0
    func activate() async { activateCount += 1 }
}

@Test func herdrBackendSnapshotDecodesAndProjects() async throws {
    let requestTransport = InMemoryLineTransport(responses: [snapshotFixture])
    let backend = HerdrSessionBackend(
        requestClient: RequestClient(transport: requestTransport),
        eventTransport: InMemoryEventTransport()
    )

    let snapshot = try await backend.snapshot()

    #expect(snapshot.sessions.map(\.id) == [SessionID(rawValue: "agent:abc")])
    #expect(snapshot.sessions.first?.attention.kind == .working)
}

@Test func herdrBackendDeliversPaneObservationsAsBackendEvents() async throws {
    let requestTransport = InMemoryLineTransport(responses: [snapshotFixture])
    let eventTransport = InMemoryEventTransport()
    let backend = HerdrSessionBackend(
        requestClient: RequestClient(transport: requestTransport),
        eventTransport: eventTransport
    )
    var iterator = backend.events().makeAsyncIterator()

    await backend.startListening()
    #expect(await iterator.next() == .connection(.connecting))
    #expect(await iterator.next() == .connection(.connected))
    _ = await iterator.next() // initial snapshot event

    eventTransport.push(paneUpdatedFixture)

    guard case .sessionChanged(let session) = await iterator.next() else {
        Issue.record("expected sessionChanged")
        return
    }
    #expect(session.attention.kind == .blocked)
    await backend.stopListening()
}

@Test func herdrBackendBroadcastsUnavailableWhenTheEventConnectionDrops() async throws {
    let requestTransport = InMemoryLineTransport(responses: [snapshotFixture])
    let eventTransport = InMemoryEventTransport()
    let backend = HerdrSessionBackend(
        requestClient: RequestClient(transport: requestTransport),
        eventTransport: eventTransport,
        reconnectDelayNanoseconds: 1
    )
    var iterator = backend.events().makeAsyncIterator()

    await backend.startListening()
    _ = await iterator.next() // connecting
    _ = await iterator.next() // connected
    _ = await iterator.next() // initial snapshot

    eventTransport.dropConnection()

    #expect(await iterator.next() == .connection(.unavailable(reason: "connection dropped")))
    await backend.stopListening()
}

@Test func herdrBackendPeriodicallyResyncsAsAFallbackForMissedEvents() async throws {
    let requestTransport = InMemoryLineTransport(responses: [snapshotFixture, snapshotFixture])
    let eventTransport = InMemoryEventTransport()
    let backend = HerdrSessionBackend(
        requestClient: RequestClient(transport: requestTransport),
        eventTransport: eventTransport,
        periodicResyncDelayNanoseconds: 1
    )
    var iterator = backend.events().makeAsyncIterator()

    await backend.startListening()
    _ = await iterator.next() // connecting
    _ = await iterator.next() // connected
    _ = await iterator.next() // initial snapshot from the listen loop

    guard case .snapshot = await iterator.next() else {
        Issue.record("expected a periodic resync snapshot event, even with no live pane events at all")
        return
    }
    await backend.stopListening()
}

@Test func herdrBackendFocusCallsWorkspaceFocusAndActivatesTheTerminal() async throws {
    let requestTransport = InMemoryLineTransport(responses: [
        snapshotFixture,
        Data(#"{"id":"req2","result":{"type":"ok"}}"#.utf8),
    ])
    let activator = RecordingActivator()
    let backend = HerdrSessionBackend(
        requestClient: RequestClient(transport: requestTransport),
        eventTransport: InMemoryEventTransport(),
        terminalActivator: activator
    )
    _ = try await backend.snapshot() // populates the route table

    try await backend.focus(SessionID(rawValue: "agent:abc"))

    #expect(activator.activateCount == 1)
    let sent = await requestTransport.sentLines
    struct Shape: Decodable { let method: String }
    #expect(try JSONDecoder().decode(Shape.self, from: sent[1]).method == "workspace.focus")
}

@Test func herdrBackendFocusOnAnUnroutedSessionThrowsUnknownSession() async {
    let backend = HerdrSessionBackend(
        requestClient: RequestClient(transport: InMemoryLineTransport()),
        eventTransport: InMemoryEventTransport()
    )
    await #expect(throws: BackendError.unknownSession(SessionID(rawValue: "agent:ghost"))) {
        try await backend.focus(SessionID(rawValue: "agent:ghost"))
    }
}
