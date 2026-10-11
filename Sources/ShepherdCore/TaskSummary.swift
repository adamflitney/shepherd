import Foundation

/// What the panel shows of a task. A plain value so the UI needn't know how tasks are stored.
public struct TaskSummary: Identifiable, Hashable, Sendable {
    public let id: Int
    public var title: String
    public var objective: String?
    public var projectPath: String?
    /// inbox | ready | active | review | done
    public var status: String
    public var progressDone: Int
    public var progressTotal: Int
    public var sessionIDs: [String]

    public init(id: Int, title: String, objective: String? = nil, projectPath: String? = nil, status: String = "inbox",
                progressDone: Int = 0, progressTotal: Int = 0, sessionIDs: [String] = []) {
        self.id = id
        self.title = title
        self.objective = objective
        self.projectPath = projectPath
        self.status = status
        self.progressDone = progressDone
        self.progressTotal = progressTotal
        self.sessionIDs = sessionIDs
    }

    /// The id of the group a backend puts this task's live session in (`Session.group`).
    public var groupID: String { "task-\(id)" }

    public var isDone: Bool { status == "done" }

    /// Active work first, then review, then what is ready, then the inbox.
    public var sortRank: Int {
        switch status {
        case "active": 0
        case "review": 1
        case "ready": 2
        case "inbox": 3
        default: 4
        }
    }
}
