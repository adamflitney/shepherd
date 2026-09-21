import Foundation

public struct SessionsSnapshot: Hashable, Sendable {
    public var sessions: [Session]
    public var groups: [SessionGroup]
    public var focusedSessionID: SessionID?

    public init(sessions: [Session] = [], groups: [SessionGroup] = [], focusedSessionID: SessionID? = nil) {
        self.sessions = sessions
        self.groups = groups
        self.focusedSessionID = focusedSessionID
    }
}

/// Whether we currently have a working connection to the backend, as opposed
/// to `AttentionState.Kind.unknown` which means "the backend told us it
/// doesn't know about this one session." A disconnect makes the whole list
/// stale and needs different treatment (a banner, dimmed rows), so it's a
/// separate axis rather than overloading `.unknown`.
public enum ConnectionState: Hashable, Sendable {
    case idle
    case connecting
    case connected
    case unavailable(reason: String)
}

/// Pushed by a `SessionBackend`. `sessionChanged` always carries the whole
/// value (never a delta): the consumer's reducer becomes a plain dictionary
/// upsert, reconnection is idempotent, and a dropped event self-heals on the
/// next one.
public enum BackendEvent: Hashable, Sendable {
    case connection(ConnectionState)
    case snapshot(SessionsSnapshot)
    case sessionChanged(Session)
    case sessionRemoved(SessionID)
    case focusChanged(SessionID?)
}

public struct CreateSessionRequest: Hashable, Sendable {
    public enum Placement: Hashable, Sendable {
        case standalone
        case alongside(SessionID)
    }

    public var workingDirectory: URL
    public var agent: AgentKind
    public var initialPrompt: String?
    /// A `claude` CLI session id to resume, when this session should
    /// continue an existing headless conversation (the inline quick-answer
    /// panel's "move to a session" action) rather than start fresh.
    public var resumeSessionID: String?
    public var title: String?
    public var placement: Placement

    public init(
        workingDirectory: URL,
        agent: AgentKind,
        initialPrompt: String? = nil,
        resumeSessionID: String? = nil,
        title: String? = nil,
        placement: Placement = .standalone
    ) {
        self.workingDirectory = workingDirectory
        self.agent = agent
        self.initialPrompt = initialPrompt
        self.resumeSessionID = resumeSessionID
        self.title = title
        self.placement = placement
    }
}

public enum BackendError: Error, Sendable, Equatable {
    case unavailable(String)
    case unsupported(String)
    case unknownSession(SessionID)
    case remote(code: String, message: String)
    case protocolViolation(String)
    case timedOut
}

/// The interface shepherd's UI and view models are built against. A single
/// adapter implements this over Herdr's socket API; a future custom backend
/// implements it directly - see the plan's domain-model section for why this
/// stays flat and agent-session-centric rather than mirroring any one
/// backend's topology.
public protocol SessionBackend: Sendable {
    /// One-shot hydrate. Throws `.unavailable` when the backend isn't running.
    func snapshot() async throws -> SessionsSnapshot

    /// Push stream. Deliberately non-throwing and infinite: transport failure
    /// is a `.connection(.unavailable)` event, not stream termination, so
    /// every consumer can write one `for await` loop and never think about
    /// reconnection.
    func events() -> AsyncStream<BackendEvent>

    func focus(_ id: SessionID) async throws
    func createSession(_ request: CreateSessionRequest) async throws -> SessionID
    func close(_ id: SessionID) async throws

    /// Sends a one-off prompt to a session's agent, fire-and-forget (no
    /// wait-for-completion) - matching the "bare creation only" MVP
    /// minimalism precedent. Interrupt is out of scope for this pass.
    func prompt(_ id: SessionID, text: String) async throws

    /// A one-shot look at what's currently on that session's screen, for the
    /// switcher's "peek" - deciding whether to switch to a session without
    /// actually switching. Raw and unstructured (whatever's visible), not a
    /// parsed "last message" - see `trimmedPeekText` for the only cleanup
    /// applied before display.
    func peek(_ id: SessionID) async throws -> String
}
