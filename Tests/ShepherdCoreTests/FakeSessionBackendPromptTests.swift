import Testing
@testable import ShepherdCore

@Test func fakeBackendPromptBroadcastsSessionChangedWithWorkingStatus() async throws {
    let session = Session(id: SessionID(rawValue: "agent:1"), title: "x", agent: .claude, attention: .idle())
    let backend = FakeSessionBackend(sessions: [session])
    var iterator = backend.events().makeAsyncIterator()

    try await backend.prompt(SessionID(rawValue: "agent:1"), text: "do the thing")

    guard case .sessionChanged(let updated) = await iterator.next() else {
        Issue.record("expected sessionChanged")
        return
    }
    #expect(updated.attention.kind == .working)
}

@Test func fakeBackendPromptOnAnUnknownSessionThrows() async {
    let backend = FakeSessionBackend(sessions: [])
    await #expect(throws: BackendError.unknownSession(SessionID(rawValue: "missing"))) {
        try await backend.prompt(SessionID(rawValue: "missing"), text: "hello")
    }
}
