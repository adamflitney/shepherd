import Foundation
import ShepherdCore

public struct ParsedHookTodos: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    public let activeForm: String?

    public init(completed: Int, total: Int, activeForm: String?) {
        self.completed = completed
        self.total = total
        self.activeForm = activeForm
    }
}

public struct ParsedHookState: Equatable, Sendable {
    public let state: String
    public let toolName: String?
    public let todos: ParsedHookTodos?

    public init(state: String, toolName: String?, todos: ParsedHookTodos?) {
        self.state = state
        self.toolName = toolName
        self.todos = todos
    }
}

private let hookStateSchemaVersion = 1

private struct HookStateFileWire: Decodable {
    let schema: Int
    let state: String
    let detail: HookDetailWire
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case schema, state, detail
        case updatedAt = "updated_at"
    }
}

private struct HookDetailWire: Decodable {
    let toolName: String?
    let todos: HookTodosWire?

    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case todos
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolName = try? container.decodeIfPresent(String.self, forKey: .toolName)
        todos = try? container.decodeIfPresent(HookTodosWire.self, forKey: .todos)
    }
}

private struct HookTodosWire: Decodable {
    let done: Int
    let total: Int
    let activeForm: String?
}

/// Parses one `~/.shepherd/state/<session-uuid>.json` file's raw content -
/// direct Swift port of the legacy prototype's `parseStateFileContent`.
/// Corrupt JSON, an unrecognised schema version, or a file too old to trust
/// all degrade to `nil` rather than throwing.
public func parseHookStateFile(
    _ content: Data?,
    now: Date,
    staleAfter: TimeInterval = 15 * 60
) -> ParsedHookState? {
    guard let content else { return nil }
    guard let wire = try? JSONDecoder().decode(HookStateFileWire.self, from: content) else { return nil }
    guard wire.schema == hookStateSchemaVersion else { return nil }
    guard let updatedAt = ISO8601DateFormatter().date(from: wire.updatedAt) else { return nil }
    guard now.timeIntervalSince(updatedAt) <= staleAfter else { return nil }

    let todos = wire.detail.todos.map {
        ParsedHookTodos(completed: $0.done, total: $0.total, activeForm: $0.activeForm)
    }
    return ParsedHookState(state: wire.state, toolName: wire.detail.toolName, todos: todos)
}

/// Reconciles Herdr's realtime `agent_status` with the hook file's own
/// refinement - direct Swift port of the legacy prototype's
/// `reconcileState`. Herdr owns `working`/`done`/`unknown` outright; the
/// hook file only ever refines `blocked` (into a `Blocker`) and `idle`
/// (into idle-with-progress, when the hook state is `"stalled"`).
public func reconcileAttention(herdrKind: AttentionState.Kind, hookState: ParsedHookState?) -> AttentionState {
    switch herdrKind {
    case .blocked:
        switch hookState?.state {
        case "needs-permission":
            return AttentionState(kind: .blocked, blocker: .needsPermission, summary: hookState?.toolName)
        case "asked-a-question":
            return AttentionState(kind: .blocked, blocker: .needsAnswer, summary: hookState?.toolName)
        default:
            return AttentionState(kind: .blocked)
        }
    case .idle:
        guard hookState?.state == "stalled" else { return AttentionState(kind: .idle) }
        let progress = hookState?.todos.map { TaskProgress(completed: $0.completed, total: $0.total, currentItem: $0.activeForm) }
        return AttentionState(kind: .idle, progress: progress ?? nil)
    case .working, .done, .unknown:
        return AttentionState(kind: herdrKind)
    }
}
