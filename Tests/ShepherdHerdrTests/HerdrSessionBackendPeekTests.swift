import Foundation
import Testing
@testable import ShepherdCore
@testable import ShepherdHerdr

private let snapshotFixture = Data(#"""
{"id":"req1","result":{"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"focused_workspace_id":null,"focused_tab_id":null,"focused_pane_id":null,"workspaces":[{"workspace_id":"w4","number":1,"label":"proj","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"w4:t1","agent_status":"idle"}],"tabs":[],"panes":[{"pane_id":"w4:p1","workspace_id":"w4","tab_id":"w4:t1","agent":"claude","agent_status":"idle","agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"abc"},"cwd":"/tmp","foreground_cwd":"/tmp","title":"x","terminal_title":"x","terminal_title_stripped":"x","focused":true}],"layouts":[],"agents":[]}}}
"""#.utf8)

@Test func herdrBackendPeekReadsTheVisiblePaneTextForTheRoutedPaneID() async throws {
    let requestTransport = InMemoryLineTransport(responses: [
        snapshotFixture,
        Data(#"{"id":"req2","result":{"pane_id":"w4:p1","workspace_id":"w4","tab_id":"w4:t1","source":"visible","format":"text","text":"last line of output","revision":1,"truncated":false}}"#.utf8),
    ])
    let backend = HerdrSessionBackend(
        requestClient: RequestClient(transport: requestTransport),
        eventTransport: InMemoryEventTransport()
    )
    _ = try await backend.snapshot() // populates the route table

    let text = try await backend.peek(SessionID(rawValue: "agent:abc"))

    #expect(text == "last line of output")

    struct Shape: Decodable { let method: String; let params: Params }
    struct Params: Decodable { let paneID: String; let source: String
        enum CodingKeys: String, CodingKey { case paneID = "pane_id", source }
    }
    let sent = await requestTransport.sentLines
    let decoded = try JSONDecoder().decode(Shape.self, from: sent[1])
    #expect(decoded.method == "pane.read")
    #expect(decoded.params.paneID == "w4:p1")
    #expect(decoded.params.source == "visible")
}

@Test func herdrBackendPeekOnAnUnroutedSessionThrowsUnknownSession() async {
    let backend = HerdrSessionBackend(
        requestClient: RequestClient(transport: InMemoryLineTransport()),
        eventTransport: InMemoryEventTransport()
    )
    await #expect(throws: BackendError.unknownSession(SessionID(rawValue: "agent:ghost"))) {
        try await backend.peek(SessionID(rawValue: "agent:ghost"))
    }
}
