import Foundation

/// An agent's need-for-attention, expressed as one closed axis the UI can rely
/// on plus optional progressive-enhancement detail. A sixth `Kind` case would
/// break every switch and colour table; an enum-with-associated-values would
/// proliferate pattern-matching sites. This shape lets a richer backend (or a
/// future Herdr release) populate `blocker`/`progress`/`summary` without any
/// existing call site changing.
public struct AttentionState: Hashable, Sendable {
    /// The badge alphabet - genuinely closed, because this is what a glance
    /// can convey. Declaration order is display priority: most urgent first.
    public enum Kind: String, Hashable, Sendable, CaseIterable, Comparable {
        case blocked, done, working, idle, unknown

        public static func < (lhs: Kind, rhs: Kind) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// Why a session is blocked. Herdr can't distinguish these today, so this
    /// stays nil until Phase 3 wires in the hook-derived refinement.
    public enum Blocker: String, Hashable, Sendable {
        case needsAnswer, needsPermission
    }

    public var kind: Kind
    public var blocker: Blocker?
    public var progress: TaskProgress?
    public var summary: String?
    public var since: Date?

    public init(
        kind: Kind,
        blocker: Blocker? = nil,
        progress: TaskProgress? = nil,
        summary: String? = nil,
        since: Date? = nil
    ) {
        self.kind = kind
        self.blocker = blocker
        self.progress = progress
        self.summary = summary
        self.since = since
    }

    public static let unknown = AttentionState(kind: .unknown)

    public static func idle(since: Date? = nil) -> Self {
        AttentionState(kind: .idle, since: since)
    }
}

/// Todo-list progress, derived from Claude Code's `TodoWrite` hook in the
/// future hook-driven refinement (Phase 3). Not speculative: the legacy
/// prototype already produces exactly this shape in production.
public struct TaskProgress: Hashable, Sendable {
    public var completed: Int
    public var total: Int
    public var currentItem: String?

    public init(completed: Int, total: Int, currentItem: String? = nil) {
        self.completed = completed
        self.total = total
        self.currentItem = currentItem
    }

    public var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }
}
