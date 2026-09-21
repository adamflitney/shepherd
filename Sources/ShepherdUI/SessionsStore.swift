import Observation
import ShepherdCore

/// The app-lifetime resident store: connects to the backend once, keeps the
/// session list in memory continuously, and re-derives the sorted/grouped
/// view on every change. Opening the panel then renders already-resident
/// state with no `await` - see the plan's Performance section for why this
/// matters (a hydrate-on-appear view model would flash empty-then-populate).
@MainActor
@Observable
public final class SessionsStore {
    public private(set) var sections: [SessionSection] = []
    public private(set) var connection: ConnectionState = .idle
    /// True whenever the list may not reflect live reality - distinct from
    /// any individual session's `AttentionState.Kind.unknown`, which means
    /// "the backend told us it doesn't know about this one."
    public private(set) var isStale: Bool = false

    private let backend: any SessionBackend
    private var sessionsByID: [SessionID: Session] = [:]
    private var listenTask: Task<Void, Never>?

    public init(backend: any SessionBackend) {
        self.backend = backend
    }

    public func start() async {
        guard listenTask == nil else { return }
        listenTask = Task { [weak self, backend] in
            for await event in backend.events() {
                await self?.handle(event)
            }
        }

        connection = .connecting
        do {
            let snapshot = try await backend.snapshot()
            apply(snapshot: snapshot)
            connection = .connected
            isStale = false
        } catch {
            connection = .unavailable(reason: "\(error)")
            isStale = true
        }
    }

    public func stop() {
        listenTask?.cancel()
        listenTask = nil
    }

    /// The store's reducer. Public so behaviour can be tested directly,
    /// deterministically, without racing the backend's `AsyncStream`.
    public func handle(_ event: BackendEvent) async {
        switch event {
        case .connection(let state):
            connection = state
            if case .unavailable = state { isStale = true }
        case .snapshot(let snapshot):
            apply(snapshot: snapshot)
            isStale = false
        case .sessionChanged(let session):
            sessionsByID[session.id] = session
            rebuildSections()
        case .sessionRemoved(let id):
            sessionsByID.removeValue(forKey: id)
            rebuildSections()
        case .focusChanged(let id):
            for key in sessionsByID.keys {
                sessionsByID[key]?.isFocused = (key == id)
            }
            rebuildSections()
        }
    }

    // MARK: - Actions

    public func focus(_ id: SessionID) async throws {
        try await backend.focus(id)
    }

    public func createSession(_ request: CreateSessionRequest) async throws -> SessionID {
        try await backend.createSession(request)
    }

    public func peek(_ id: SessionID) async throws -> String {
        try await backend.peek(id)
    }

    public func prompt(_ id: SessionID, text: String) async throws {
        try await backend.prompt(id, text: text)
    }

    public func close(_ id: SessionID) async throws {
        try await backend.close(id)
    }

    // MARK: - Private

    private func apply(snapshot: SessionsSnapshot) {
        sessionsByID = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0) })
        rebuildSections()
    }

    private func rebuildSections() {
        sections = groupSessions(sortSessions(Array(sessionsByID.values)))
    }
}
