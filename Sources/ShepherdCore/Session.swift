import Foundation

/// A session's durable identity. Derived from the agent's own session id
/// (never from a backend's positional pane/tab/workspace ids, which are
/// reused across restarts) so annotations like "seen" watermarks stay
/// attached to the right agent.
public struct SessionID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Herdr's `agent` field is an open string set (new agent CLIs appear over
/// time), so this is a string wrapper with known constants rather than a
/// closed enum - an unrecognised value must round-trip, not be rejected.
public struct AgentKind: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let claude = AgentKind(rawValue: "claude")
    public static let codex = AgentKind(rawValue: "codex")
    public static let opencode = AgentKind(rawValue: "opencode")
}

/// What actions a session supports. A backend that can't (say) focus
/// anything reports that up front so the UI disables the action, rather than
/// the user discovering `.unsupported` on click.
public struct SessionCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let focus = SessionCapabilities(rawValue: 1 << 0)
    public static let prompt = SessionCapabilities(rawValue: 1 << 1)
    public static let interrupt = SessionCapabilities(rawValue: 1 << 2)
    public static let close = SessionCapabilities(rawValue: 1 << 3)
}

/// Display-only grouping (Herdr's workspace). Never load-bearing for
/// behaviour - see the domain-model note in the implementation plan on why
/// the workspace/tab/pane hierarchy isn't mirrored in the domain.
public struct SessionGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public var label: String
    public var ordinal: Int?

    public init(id: String, label: String, ordinal: Int? = nil) {
        self.id = id
        self.label = label
        self.ordinal = ordinal
    }
}

public struct WorktreeInfo: Hashable, Sendable {
    public var branch: String?
    public var path: URL?

    public init(branch: String? = nil, path: URL? = nil) {
        self.branch = branch
        self.path = path
    }
}

/// The unit of meaning shepherd displays: "an agent that may need me."
/// Deliberately flat - see the plan's domain-model section for why this
/// doesn't mirror Herdr's workspace/tab/pane hierarchy.
public struct Session: Identifiable, Hashable, Sendable {
    public let id: SessionID
    public var title: String
    public var agent: AgentKind
    public var workingDirectory: URL?
    public var attention: AttentionState
    public var isFocused: Bool
    public var group: SessionGroup?
    public var worktree: WorktreeInfo?
    public var lastActivityAt: Date?
    public var capabilities: SessionCapabilities

    public init(
        id: SessionID,
        title: String,
        agent: AgentKind,
        workingDirectory: URL? = nil,
        attention: AttentionState,
        isFocused: Bool = false,
        group: SessionGroup? = nil,
        worktree: WorktreeInfo? = nil,
        lastActivityAt: Date? = nil,
        capabilities: SessionCapabilities = []
    ) {
        self.id = id
        self.title = title
        self.agent = agent
        self.workingDirectory = workingDirectory
        self.attention = attention
        self.isFocused = isFocused
        self.group = group
        self.worktree = worktree
        self.lastActivityAt = lastActivityAt
        self.capabilities = capabilities
    }
}
