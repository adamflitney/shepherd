import Foundation

/// The subset of Claude Code's SessionStart hook payload we use.
public struct SessionStartInput: Decodable, Sendable {
    public var sessionID: String?
    public var source: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case source
    }

    public init(sessionID: String?, source: String? = nil) {
        self.sessionID = sessionID
        self.source = source
    }
}

/// SessionStart hook: finds the task a session belongs to and returns the hook output that injects
/// the task's plan and log. A session that is not linked yet is linked when shepherd started it for a
/// task (`SHEPHERD_TASK_ID`), which also re-links after `/clear`, where the session id changes but
/// the terminal keeps its environment. Returns nil when the session has no task.
public func sessionStartHookOutput(_ input: SessionStartInput, env: [String: String], store: TaskStore) -> String? {
    guard let sessionID = input.sessionID, !sessionID.isEmpty else { return nil }
    var task = store.findBySession(sessionID)
    if task == nil, let raw = env["SHEPHERD_TASK_ID"], let id = Int(raw), id > 0, store.get(id) != nil {
        task = try? store.update(id) { $0.linkSession(sessionID) }
    }
    guard let task else { return nil }
    let payload: [String: Any] = [
        "hookSpecificOutput": [
            "hookEventName": "SessionStart",
            "additionalContext": taskContext(task),
        ]
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]) else { return nil }
    return String(data: data, encoding: .utf8)
}
