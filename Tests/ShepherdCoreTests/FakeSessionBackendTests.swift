import Foundation
import Testing
@testable import ShepherdCore

private func makeSession(id: String, kind: AttentionState.Kind = .idle) -> Session {
    Session(
        id: SessionID(rawValue: id),
        title: id,
        agent: .claude,
        attention: AttentionState(kind: kind),
        capabilities: [.focus, .close]
    )
}

@Test func fakeBackendSnapshotReturnsSeededSessions() async throws {
    let backend = FakeSessionBackend(sessions: [makeSession(id: "agent:1"), makeSession(id: "agent:2")])
    let snapshot = try await backend.snapshot()
    #expect(Set(snapshot.sessions.map(\.id)) == [SessionID(rawValue: "agent:1"), SessionID(rawValue: "agent:2")])
}

@Test func fakeBackendSetAttentionUpdatesSessionAndBroadcastsChange() async throws {
    let backend = FakeSessionBackend(sessions: [makeSession(id: "agent:1")])
    var iterator = backend.events().makeAsyncIterator()

    await backend.setAttention(AttentionState(kind: .blocked), for: SessionID(rawValue: "agent:1"))

    guard case .sessionChanged(let session) = await iterator.next() else {
        Issue.record("expected a sessionChanged event")
        return
    }
    #expect(session.attention.kind == .blocked)

    let snapshot = try await backend.snapshot()
    #expect(snapshot.sessions.first?.attention.kind == .blocked)
}

@Test func fakeBackendSimulateDisconnectBroadcastsUnavailable() async {
    let backend = FakeSessionBackend(sessions: [])
    var iterator = backend.events().makeAsyncIterator()

    await backend.simulateDisconnect(reason: "herdr not running")

    #expect(await iterator.next() == .connection(.unavailable(reason: "herdr not running")))
}

@Test func fakeBackendFocusMarksSessionFocusedAndUnfocusesOthers() async throws {
    let backend = FakeSessionBackend(sessions: [makeSession(id: "agent:1"), makeSession(id: "agent:2")])

    try await backend.focus(SessionID(rawValue: "agent:2"))

    let snapshot = try await backend.snapshot()
    let byID = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0) })
    #expect(byID[SessionID(rawValue: "agent:2")]?.isFocused == true)
    #expect(byID[SessionID(rawValue: "agent:1")]?.isFocused == false)
    #expect(snapshot.focusedSessionID == SessionID(rawValue: "agent:2"))
}

@Test func fakeBackendFocusUnknownSessionThrows() async {
    let backend = FakeSessionBackend(sessions: [])
    await #expect(throws: BackendError.unknownSession(SessionID(rawValue: "missing"))) {
        try await backend.focus(SessionID(rawValue: "missing"))
    }
}

@Test func fakeBackendCreateSessionAddsAndBroadcastsIt() async throws {
    let backend = FakeSessionBackend(sessions: [])
    var iterator = backend.events().makeAsyncIterator()

    let request = CreateSessionRequest(workingDirectory: URL(fileURLWithPath: "/tmp/project"), agent: .claude)
    let newID = try await backend.createSession(request)

    guard case .sessionChanged(let session) = await iterator.next() else {
        Issue.record("expected a sessionChanged event for the new session")
        return
    }
    #expect(session.id == newID)
    #expect(session.workingDirectory == URL(fileURLWithPath: "/tmp/project"))

    let snapshot = try await backend.snapshot()
    #expect(snapshot.sessions.map(\.id).contains(newID))
}

@Test func fakeBackendPeekReturnsTheConfiguredText() async throws {
    let backend = FakeSessionBackend(sessions: [makeSession(id: "agent:1")])
    await backend.setPeekText("agent's last message", for: SessionID(rawValue: "agent:1"))

    let text = try await backend.peek(SessionID(rawValue: "agent:1"))

    #expect(text == "agent's last message")
}

@Test func fakeBackendPeekOnAnUnknownSessionThrows() async {
    let backend = FakeSessionBackend(sessions: [])
    await #expect(throws: BackendError.unknownSession(SessionID(rawValue: "missing"))) {
        try await backend.peek(SessionID(rawValue: "missing"))
    }
}

@Test func fakeBackendCloseRemovesSessionAndBroadcastsRemoval() async throws {
    let backend = FakeSessionBackend(sessions: [makeSession(id: "agent:1")])
    var iterator = backend.events().makeAsyncIterator()

    try await backend.close(SessionID(rawValue: "agent:1"))

    #expect(await iterator.next() == .sessionRemoved(SessionID(rawValue: "agent:1")))
    let snapshot = try await backend.snapshot()
    #expect(snapshot.sessions.isEmpty)
}
