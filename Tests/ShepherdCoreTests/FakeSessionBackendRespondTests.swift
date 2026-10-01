import Testing
@testable import ShepherdCore

@Test func fakeBackendRespondBroadcastsSessionChangedWithWorkingStatus() async throws {
    let session = Session(id: SessionID(rawValue: "agent:1"), title: "x", agent: .claude, attention: .idle())
    let backend = FakeSessionBackend(sessions: [session])
    var iterator = backend.events().makeAsyncIterator()

    try await backend.respond(SessionID(rawValue: "agent:1"), keys: ["1"])

    guard case .sessionChanged(let updated) = await iterator.next() else {
        Issue.record("expected sessionChanged")
        return
    }
    #expect(updated.attention.kind == .working)
    #expect(await backend.lastRespondKeys[SessionID(rawValue: "agent:1")] == ["1"])
}

@Test func fakeBackendRespondOnAnUnknownSessionThrows() async {
    let backend = FakeSessionBackend(sessions: [])
    await #expect(throws: BackendError.unknownSession(SessionID(rawValue: "missing"))) {
        try await backend.respond(SessionID(rawValue: "missing"), keys: ["1"])
    }
}
