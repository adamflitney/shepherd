import Foundation

/// An in-memory `SessionBackend`, ships in the app binary (selectable via
/// `--fake`) rather than living only in tests. That's what keeps "every
/// commit green and runnable" true during Phase 1: the app boots on this
/// with a working menu bar, panel and animated state changes before a byte
/// of Herdr socket code exists.
public actor FakeSessionBackend: SessionBackend {
    private var sessions: [SessionID: Session]
    private var groups: [SessionGroup]
    private var focusedID: SessionID?
    private var nextSyntheticID = 0
    private let hub = BackendEventHub()

    public init(sessions: [Session] = [], groups: [SessionGroup] = []) {
        self.sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        self.groups = groups
        self.focusedID = sessions.first(where: \.isFocused)?.id
    }

    public func snapshot() async throws -> SessionsSnapshot {
        SessionsSnapshot(sessions: Array(sessions.values), groups: groups, focusedSessionID: focusedID)
    }

    public nonisolated func events() -> AsyncStream<BackendEvent> {
        hub.makeStream()
    }

    public func focus(_ id: SessionID) async throws {
        guard sessions[id] != nil else { throw BackendError.unknownSession(id) }
        for key in sessions.keys {
            sessions[key]?.isFocused = (key == id)
        }
        focusedID = id
        hub.broadcast(.focusChanged(id))
    }

    public func createSession(_ request: CreateSessionRequest) async throws -> SessionID {
        nextSyntheticID += 1
        let id = SessionID(rawValue: "fake:\(nextSyntheticID)")
        let session = Session(
            id: id,
            title: request.title ?? request.workingDirectory.lastPathComponent,
            agent: request.agent,
            workingDirectory: request.workingDirectory,
            attention: .idle(),
            capabilities: [.focus, .close, .prompt]
        )
        sessions[id] = session
        hub.broadcast(.sessionChanged(session))
        return id
    }

    public func close(_ id: SessionID) async throws {
        guard sessions.removeValue(forKey: id) != nil else { throw BackendError.unknownSession(id) }
        if focusedID == id { focusedID = nil }
        hub.broadcast(.sessionRemoved(id))
    }

    public func prompt(_ id: SessionID, text: String) async throws {
        guard var session = sessions[id] else { throw BackendError.unknownSession(id) }
        session.attention = AttentionState(kind: .working)
        sessions[id] = session
        hub.broadcast(.sessionChanged(session))
    }

    // MARK: - Test/demo control surface

    public func setAttention(_ attention: AttentionState, for id: SessionID) async {
        guard var session = sessions[id] else { return }
        session.attention = attention
        sessions[id] = session
        hub.broadcast(.sessionChanged(session))
    }

    public func simulateDisconnect(reason: String) async {
        hub.broadcast(.connection(.unavailable(reason: reason)))
    }

    public func simulateReconnect() async {
        hub.broadcast(.connection(.connected))
        if let snapshot = try? await snapshot() {
            hub.broadcast(.snapshot(snapshot))
        }
    }
}
