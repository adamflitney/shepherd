import Foundation

/// The subset of Claude Code's SessionStart hook payload we use.
public struct SessionStartInput: Decodable, Sendable {
    public var sessionID: String?
    public var source: String?
    public var cwd: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case source, cwd
    }

    public init(sessionID: String?, source: String? = nil, cwd: String? = nil) {
        self.sessionID = sessionID
        self.source = source
        self.cwd = cwd
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
    guard var task else { return nil }
    // A session started outside shepherd still tells the task where it ran.
    if let cwd = input.cwd, !task.sessionNotes.contains(where: { $0.id == sessionID }) {
        task = (try? store.update(task.id) { $0.recordSession(id: sessionID, cwd: cwd) }) ?? task
    }
    let parent = task.parent.flatMap { store.get($0) }
    let payload: [String: Any] = [
        "hookSpecificOutput": [
            "hookEventName": "SessionStart",
            "additionalContext": taskContext(task, parent: parent, children: store.children(of: task.id), crook: env["SHEPHERD_CROOK"].map { shellQuoted($0) } ?? "crook"),
        ]
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]) else { return nil }
    return String(data: data, encoding: .utf8)
}

/// A path as one shell word, for the command lines the context tells the agent to run.
private func shellQuoted(_ s: String) -> String {
    s.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
