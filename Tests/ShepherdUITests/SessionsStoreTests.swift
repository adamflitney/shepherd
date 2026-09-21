import Foundation
import Testing
@testable import ShepherdCore
@testable import ShepherdUI

private func session(_ id: String, _ kind: AttentionState.Kind = .idle) -> Session {
    Session(id: SessionID(rawValue: id), title: id, agent: .claude, attention: AttentionState(kind: kind))
}

@MainActor
@Test func sessionsStoreHydratesFromBackendSnapshotOnStart() async {
    let backend = FakeSessionBackend(sessions: [session("agent:1")])
    let store = SessionsStore(backend: backend)

    await store.start()

    #expect(store.sections.flatMap(\.sessions).map(\.id.rawValue) == ["agent:1"])
    #expect(store.connection == .connected)
    #expect(store.isStale == false)
}

@MainActor
@Test func sessionsStoreHandleUpsertsChangedSession() async {
    let store = SessionsStore(backend: FakeSessionBackend(sessions: []))
    await store.handle(.snapshot(SessionsSnapshot(sessions: [session("agent:1", .idle)])))

    await store.handle(.sessionChanged(session("agent:1", .blocked)))

    #expect(store.sections.flatMap(\.sessions).first?.attention.kind == .blocked)
}

@MainActor
@Test func sessionsStoreHandleRemovesSession() async {
    let store = SessionsStore(backend: FakeSessionBackend(sessions: []))
    await store.handle(.snapshot(SessionsSnapshot(sessions: [session("agent:1")])))

    await store.handle(.sessionRemoved(SessionID(rawValue: "agent:1")))

    #expect(store.sections.flatMap(\.sessions).isEmpty)
}

@MainActor
@Test func sessionsStoreDisconnectMarksStaleWithoutMutatingSessionAttention() async {
    let store = SessionsStore(backend: FakeSessionBackend(sessions: []))
    await store.handle(.snapshot(SessionsSnapshot(sessions: [session("agent:1", .idle)])))

    await store.handle(.connection(.unavailable(reason: "herdr not running")))

    #expect(store.isStale == true)
    #expect(store.connection == .unavailable(reason: "herdr not running"))
    // The session itself keeps reporting its last-known kind - disconnected is
    // a separate axis from AttentionState.Kind.unknown, not a mutation of it.
    #expect(store.sections.flatMap(\.sessions).first?.attention.kind == .idle)
}

@MainActor
@Test func sessionsStoreReconnectSnapshotClearsStale() async {
    let store = SessionsStore(backend: FakeSessionBackend(sessions: []))
    await store.handle(.connection(.unavailable(reason: "x")))
    #expect(store.isStale == true)

    await store.handle(.snapshot(SessionsSnapshot(sessions: [])))

    #expect(store.isStale == false)
}

@MainActor
@Test func sessionsStoreFocusChangedUpdatesIsFocusedFlags() async {
    let store = SessionsStore(backend: FakeSessionBackend(sessions: []))
    await store.handle(.snapshot(SessionsSnapshot(sessions: [session("agent:1"), session("agent:2")])))

    await store.handle(.focusChanged(SessionID(rawValue: "agent:2")))

    let byID = Dictionary(uniqueKeysWithValues: store.sections.flatMap(\.sessions).map { ($0.id, $0) })
    #expect(byID[SessionID(rawValue: "agent:2")]?.isFocused == true)
    #expect(byID[SessionID(rawValue: "agent:1")]?.isFocused == false)
}

@MainActor
@Test func sessionsStoreObservesLiveEventsFromTheBackendAfterStart() async throws {
    let backend = FakeSessionBackend(sessions: [session("agent:1", .idle)])
    let store = SessionsStore(backend: backend)
    await store.start()

    await backend.setAttention(AttentionState(kind: .blocked), for: SessionID(rawValue: "agent:1"))

    // The event travels through the backend's AsyncStream and the store's own
    // listening task, so give it a short bounded window rather than asserting
    // on the very next line.
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
        if store.sections.flatMap(\.sessions).first?.attention.kind == .blocked { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }

    #expect(store.sections.flatMap(\.sessions).first?.attention.kind == .blocked)
    store.stop()
}
