import Foundation

public struct NewTask: Sendable {
    public var title: String
    public var objective: String?
    public var projectPath: String?
    public var branch: String?
    public var parent: Int?

    public init(title: String, objective: String? = nil, projectPath: String? = nil, branch: String? = nil, parent: Int? = nil) {
        self.parent = parent
        self.title = title
        self.objective = objective
        self.projectPath = projectPath
        self.branch = branch
    }
}

/// Tasks live one per file in `~/.shepherd/tasks/<id>-<slug>.md` (or `$SHEPHERD_HOME/tasks`).
public struct TaskStore: Sendable {
    public let directory: URL

    public init(directory: URL = TaskStore.defaultDirectory()) {
        self.directory = directory
    }

    public static func defaultDirectory(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = env["SHEPHERD_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".shepherd")
        return home.appendingPathComponent("tasks")
    }

    /// Where a task's own scripts and files live, beside the tasks folder (`~/.shepherd/workspaces/<id>`). Not created
    /// until `ensureWorkspace`.
    public func workspaceDirectory(for id: Int) -> URL {
        directory.deletingLastPathComponent().appendingPathComponent("workspaces").appendingPathComponent(String(id))
    }

    @discardableResult
    public func ensureWorkspace(for id: Int) throws -> URL {
        let url = workspaceDirectory(for: id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func files() -> [(id: Int, url: URL)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { name -> (Int, URL)? in
            guard name.hasSuffix(".md"), let dash = name.firstIndex(of: "-"),
                  let id = Int(name[name.startIndex..<dash]) else { return nil }
            return (id, directory.appendingPathComponent(name))
        }
        .sorted { $0.0 < $1.0 }
        .map { (id: $0.0, url: $0.1) }
    }

    private func read(_ url: URL) -> TaskFile? {
        (try? String(contentsOf: url, encoding: .utf8)).map(TaskFile.parse)
    }

    public func list() -> [TaskFile] { files().compactMap { read($0.url) } }

    public func get(_ id: Int) -> TaskFile? { files().first { $0.id == id }.flatMap { read($0.url) } }

    public func children(of id: Int) -> [TaskFile] { list().filter { $0.parent == id } }

    public func findBySession(_ sessionID: String) -> TaskFile? { list().first { $0.sessions.contains(sessionID) } }

    @discardableResult
    public func create(_ input: NewTask, now: Date = Date()) throws -> TaskFile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try withLock {
            let id = (files().last?.id ?? 0) + 1
            if let parent = input.parent {
                guard let parentTask = files().first(where: { $0.id == parent }).flatMap({ read($0.url) }) else { throw TaskError("no task \(parent) to put this under") }
                if parentTask.parent != nil { throw TaskError("task \(parent) is itself a subtask; subtasks go one level deep") }
            }
            let task = TaskFile.create(id: id, title: input.title, objective: input.objective, projectPath: input.projectPath, branch: input.branch, parent: input.parent, now: now)
            let name = "\(String(format: "%04d", id))-\(slug(input.title)).md"
            try task.serialize().write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            return task
        }
    }

    /// Re-reads the file just before writing and applies `fn`, so only the intended fields change.
    @discardableResult
    public func update(_ id: Int, now: Date = Date(), _ fn: (inout TaskFile) throws -> Void) throws -> TaskFile {
        guard let file = files().first(where: { $0.id == id }), var task = read(file.url) else {
            throw TaskError("no task \(id)")
        }
        try fn(&task)
        task.touch(now: now)
        try task.serialize().write(to: file.url, atomically: true, encoding: .utf8)
        return task
    }

    public func delete(_ id: Int) throws {
        guard let file = files().first(where: { $0.id == id }) else { throw TaskError("no task \(id)") }
        try FileManager.default.removeItem(at: file.url)
    }

    private func withLock<T>(_ fn: () throws -> T) throws -> T {
        let lock = directory.appendingPathComponent(".lock")
        var tries = 0
        while true {
            do {
                try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
                break
            } catch {
                tries += 1
                if tries > 200 { throw error }
                usleep(10_000)
            }
        }
        defer { try? FileManager.default.removeItem(at: lock) }
        return try fn()
    }
}

public func slug(_ title: String) -> String {
    var out = ""
    var lastDash = true
    for c in title.lowercased() {
        if c.isASCII, c.isLetter || c.isNumber {
            out.append(c)
            lastDash = false
        } else if !lastDash {
            out.append("-")
            lastDash = true
        }
    }
    while out.hasSuffix("-") { out.removeLast() }
    out = String(out.prefix(40))
    while out.hasSuffix("-") { out.removeLast() }
    return out.isEmpty ? "task" : out
}
