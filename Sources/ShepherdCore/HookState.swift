import Foundation

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
    /// The literal question text, when the blocker is a structured
    /// `AskUserQuestion` - `nil` for a permission prompt or a plain-text
    /// question (which has no dedicated tool call to read this from).
    public let question: String?
    /// Labeled choices in Claude Code's own numbering order, for the same
    /// `AskUserQuestion` case. `nil` whenever `question` is.
    public let options: [String]?
    /// Whether `options` is a multi-select `AskUserQuestion` - `false` for a
    /// single-choice question or when `options` is `nil`.
    public let multiSelect: Bool
    /// A one-line human summary of *what's being approved*, for a
    /// `needs-permission` blocker - e.g. "Bash: rm -rf build/", not just
    /// the bare tool name, which on its own doesn't say enough to approve
    /// or deny from a phone with no view of the terminal.
    public let summary: String?
    /// When the hook last wrote this state; what "finished while you weren't looking" is measured from.
    public let updatedAt: Date?
    /// The id shepherd launched the session under (`SHEPHERD_SESSION_ID`), when the hook saw one.
    /// Claude Code's own session id changes on `/clear`; this one does not.
    public let shepherdSessionID: String?

    public init(
        state: String,
        toolName: String?,
        todos: ParsedHookTodos?,
        question: String? = nil,
        options: [String]? = nil,
        multiSelect: Bool = false,
        summary: String? = nil,
        updatedAt: Date? = nil,
        shepherdSessionID: String? = nil
    ) {
        self.state = state
        self.toolName = toolName
        self.todos = todos
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.summary = summary
        self.updatedAt = updatedAt
        self.shepherdSessionID = shepherdSessionID
    }
}

private let hookStateSchemaVersion = 1

private struct HookStateFileWire: Decodable {
    let schema: Int
    let state: String
    let detail: HookDetailWire
    let updatedAt: String
    let shepherdSessionID: String?

    enum CodingKeys: String, CodingKey {
        case schema, state, detail
        case updatedAt = "updated_at"
        case shepherdSessionID = "shepherd_session_id"
    }
}

private struct HookDetailWire: Decodable {
    let toolName: String?
    let todos: HookTodosWire?
    let question: String?
    let options: [String]?
    let multiSelect: Bool?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case todos, question, options, summary
        case multiSelect = "multi_select"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolName = try? container.decodeIfPresent(String.self, forKey: .toolName)
        todos = try? container.decodeIfPresent(HookTodosWire.self, forKey: .todos)
        question = try? container.decodeIfPresent(String.self, forKey: .question)
        options = try? container.decodeIfPresent([String].self, forKey: .options)
        multiSelect = try? container.decodeIfPresent(Bool.self, forKey: .multiSelect)
        summary = try? container.decodeIfPresent(String.self, forKey: .summary)
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
    return ParsedHookState(
        state: wire.state,
        toolName: wire.detail.toolName,
        todos: todos,
        question: wire.detail.question,
        options: wire.detail.options,
        multiSelect: wire.detail.multiSelect ?? false,
        summary: wire.detail.summary,
        updatedAt: updatedAt,
        shepherdSessionID: wire.shepherdSessionID
    )
}

/// Reads `~/.shepherd/state/<session-uuid>.json` files written by the
/// Claude Code hooks ported from `shepherd-legacy`. Pure I/O at the edge -
/// `SessionProjection` and `reconcileAttention` stay data-in, data-out.
public struct HookStateStore {
    private let directory: URL
    private let now: () -> Date
    private let staleAfter: TimeInterval

    /// `staleAfter` defaults to the 15 minutes that suited Herdr (which supplied the live status the
    /// file only refined). A backend that has no other source of state passes `.infinity`.
    public init(
        directory: URL = URL(fileURLWithPath: (NSString(string: "~/.shepherd/state").expandingTildeInPath)),
        now: @escaping () -> Date = Date.init,
        staleAfter: TimeInterval = 15 * 60
    ) {
        self.directory = directory
        self.now = now
        self.staleAfter = staleAfter
    }

    public var directoryURL: URL { directory }

    public func state(forSessionUUID uuid: String) -> ParsedHookState? {
        let url = directory.appendingPathComponent("\(uuid).json")
        return parseHookStateFile(try? Data(contentsOf: url), now: now(), staleAfter: staleAfter)
    }

    public func allStates() -> [String: ParsedHookState] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return [:]
        }

        var result: [String: ParsedHookState] = [:]
        for file in files where file.pathExtension == "json" {
            let uuid = file.deletingPathExtension().lastPathComponent
            guard let content = try? Data(contentsOf: file),
                  let parsed = parseHookStateFile(content, now: now(), staleAfter: staleAfter) else { continue }
            result[uuid] = parsed
        }
        return result
    }
}
