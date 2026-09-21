import Foundation
import Testing
@testable import ShepherdCore
@testable import ShepherdHerdr

private let workspaceCreatedFixture = Data(#"""
{"id":"req1","result":{"type":"workspace_created","workspace":{"workspace_id":"w9","number":9,"label":"proj","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"w9:t1","agent_status":"unknown"},"root_pane":{"pane_id":"w9:p1","workspace_id":"w9","tab_id":"w9:t1","agent_status":"unknown","focused":false}}}
"""#.utf8)

private let agentStartedFixture = Data(#"""
{"id":"req2","result":{"type":"agent_started","agent":{"pane_id":"w9:p1","workspace_id":"w9","tab_id":"w9:t1","agent":"claude","agent_status":"unknown","focused":false}}}
"""#.utf8)

/// `agent.wait`'s result shape matches `agent.start`'s ({type, agent}).
private func agentWaitFixture(status: String, sessionValue: String? = nil, id: String = "req3") -> Data {
    let sessionField = sessionValue.map {
        #","agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"\#($0)"}"#
    } ?? ""
    return Data(#"""
    {"id":"\#(id)","result":{"type":"agent_info","agent":{"pane_id":"w9:p1","workspace_id":"w9","tab_id":"w9:t1","agent":"claude","agent_status":"\#(status)"\#(sessionField),"focused":false}}}
    """#.utf8)
}

private let ignoredOKFixture = Data(#"{"id":"reqN","result":{"type":"ok"}}"#.utf8)

private struct AgentStartShape: Decodable {
    let method: String
    let params: Params
    struct Params: Decodable { let args: [String] }
}

private struct AgentWaitShape: Decodable {
    let method: String
    let params: Params
    struct Params: Decodable { let target: String; let until: [String] }
}

private struct AgentSendKeysShape: Decodable {
    let method: String
    let params: Params
    struct Params: Decodable { let target: String; let keys: [String] }
}

private struct AgentPromptShape: Decodable {
    let method: String
    let params: Params
    struct Params: Decodable { let target: String; let text: String }
}

@Test func createSessionPassesNoArgsByDefaultAndWaitsForASettledStatus() async throws {
    let requestTransport = InMemoryLineTransport(responses: [
        workspaceCreatedFixture, agentStartedFixture, agentWaitFixture(status: "working", sessionValue: "new-session"),
    ])
    let backend = HerdrSessionBackend(
        requestClient: RequestClient(transport: requestTransport),
        eventTransport: InMemoryEventTransport()
    )

    let id = try await backend.createSession(CreateSessionRequest(workingDirectory: URL(fileURLWithPath: "/tmp"), agent: .claude))

    #expect(id == SessionID(rawValue: "agent:new-session"))
    let sent = await requestTransport.sentLines
    let started = try JSONDecoder().decode(AgentStartShape.self, from: sent[1])
    #expect(started.method == "agent.start")
    #expect(started.params.args == [])
    let waited = try JSONDecoder().decode(AgentWaitShape.self, from: sent[2])
    #expect(waited.method == "agent.wait")
    #expect(waited.params.target == "w9:p1")
}

@Test func createSessionWithResumeSessionIDPassesResumeArgsAndSendsNoPrompt() async throws {
    let requestTransport = InMemoryLineTransport(responses: [
        workspaceCreatedFixture, agentStartedFixture, agentWaitFixture(status: "idle", sessionValue: "resumed-session"),
    ])
    let backend = HerdrSessionBackend(
        requestClient: RequestClient(transport: requestTransport),
        eventTransport: InMemoryEventTransport()
    )

    _ = try await backend.createSession(CreateSessionRequest(
        workingDirectory: URL(fileURLWithPath: "/tmp"),
        agent: .claude,
        resumeSessionID: "abc-123"
    ))

    let sent = await requestTransport.sentLines
    let started = try JSONDecoder().decode(AgentStartShape.self, from: sent[1])
    #expect(started.params.args == ["--resume", "abc-123"])
    #expect(sent.count == 3) // no agent.prompt call
}

@Test func createSessionWithInitialPromptSendsAgentPromptAfterSettling() async throws {
    let requestTransport = InMemoryLineTransport(responses: [
        workspaceCreatedFixture, agentStartedFixture, agentWaitFixture(status: "working", sessionValue: "new-session"),
        ignoredOKFixture,
    ])
    let backend = HerdrSessionBackend(
        requestClient: RequestClient(transport: requestTransport),
        eventTransport: InMemoryEventTransport()
    )

    _ = try await backend.createSession(CreateSessionRequest(
        workingDirectory: URL(fileURLWithPath: "/tmp"),
        agent: .claude,
        initialPrompt: "look into the flaky test"
    ))

    let sent = await requestTransport.sentLines
    #expect(sent.count == 4)
    let prompted = try JSONDecoder().decode(AgentPromptShape.self, from: sent[3])
    #expect(prompted.method == "agent.prompt")
    #expect(prompted.params.target == "w9:p1")
    #expect(prompted.params.text == "look into the flaky test")
}

@Test func createSessionDismissesTheFolderTrustPromptWhenFirstBlocked() async throws {
    let requestTransport = InMemoryLineTransport(responses: [
        workspaceCreatedFixture,
        agentStartedFixture,
        agentWaitFixture(status: "blocked"), // Claude Code's folder-trust dialog
        ignoredOKFixture, // agent.send_keys
        agentWaitFixture(status: "idle", sessionValue: "new-session"), // settled after dismissal
        ignoredOKFixture, // agent.prompt
    ])
    let backend = HerdrSessionBackend(
        requestClient: RequestClient(transport: requestTransport),
        eventTransport: InMemoryEventTransport()
    )

    let id = try await backend.createSession(CreateSessionRequest(
        workingDirectory: URL(fileURLWithPath: "/tmp"),
        agent: .claude,
        initialPrompt: "hello"
    ))

    #expect(id == SessionID(rawValue: "agent:new-session"))
    let sent = await requestTransport.sentLines
    #expect(sent.count == 6)
    let sendKeys = try JSONDecoder().decode(AgentSendKeysShape.self, from: sent[3])
    #expect(sendKeys.method == "agent.send_keys")
    #expect(sendKeys.params.target == "w9:p1")
    #expect(sendKeys.params.keys == ["down", "enter"])
    let secondWait = try JSONDecoder().decode(AgentWaitShape.self, from: sent[4])
    #expect(secondWait.method == "agent.wait")
    #expect(secondWait.params.until == ["idle", "working", "done"])
}
