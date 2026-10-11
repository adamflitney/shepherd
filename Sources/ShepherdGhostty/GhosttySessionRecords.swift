import Foundation
import ShepherdCore

/// What shepherd remembers about a session it started. Ghostty's terminal ids last only as long as
/// Ghostty does, so the record is how a session is found again after shepherd restarts.
public struct GhosttySessionRecord: Codable, Sendable, Equatable {
    public var sessionID: String
    public var taskID: Int?
    public var agent: String
    public var workingDirectory: String
    public var title: String
    public var ref: GhosttyTerminalRef?
    public var createdAt: Date
    /// When someone last looked at or typed into the session; "finished while you were away" is
    /// measured from here.
    public var lastSeenAt: Date?
    public var endedAt: Date?

    public init(sessionID: String, taskID: Int? = nil, agent: String = "claude", workingDirectory: String, title: String,
                ref: GhosttyTerminalRef? = nil, createdAt: Date = Date(), lastSeenAt: Date? = nil, endedAt: Date? = nil) {
        self.sessionID = sessionID
        self.taskID = taskID
        self.agent = agent
        self.workingDirectory = workingDirectory
        self.title = title
        self.ref = ref
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.endedAt = endedAt
    }
}

/// `~/.shepherd/ghostty-sessions.json`.
public struct GhosttyRecordStore: Sendable {
    private let url: URL

    public init(url: URL = URL(fileURLWithPath: NSString(string: "~/.shepherd/ghostty-sessions.json").expandingTildeInPath)) {
        self.url = url
    }

    public func load() -> [GhosttySessionRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([GhosttySessionRecord].self, from: data)) ?? []
    }

    public func save(_ records: [GhosttySessionRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Which Ghostty window agent tabs go into. Ghostty cannot place a window on a given monitor, so the
/// workable convention is one "agents" window that the user parks where they want it.
public protocol AgentsWindowStoring: Sendable {
    func get() -> String?
    func set(_ windowID: String?)
}

/// `~/.shepherd/ghostty-agents-window`. Window ids last only as long as Ghostty does; a stale id is
/// harmless because the driver opens a fresh window when the id no longer exists.
public struct FileAgentsWindowStore: AgentsWindowStoring {
    private let url: URL

    public init(url: URL = URL(fileURLWithPath: NSString(string: "~/.shepherd/ghostty-agents-window").expandingTildeInPath)) {
        self.url = url
    }

    public func get() -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public func set(_ windowID: String?) {
        if let windowID {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? windowID.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Whether an agent process for a session is still running.
public protocol ProcessProbe: Sendable {
    /// Which of these sessions still have a running process.
    func aliveSessions(among sessionIDs: [String]) async -> Set<String>
    /// Asks the session's processes to exit.
    func terminate(sessionID: String) async
}

/// Looks for a process whose command line mentions the session id (`claude --session-id <id>` or
/// `claude --resume <id>`). The id appears in the arguments for as long as the process lives, also
/// after `/clear`, and nothing else would contain a v4 UUID by accident.
public struct PSProcessProbe: ProcessProbe {
    public init() {}

    private func processTable() async -> [(pid: Int32, command: String)] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[(pid: Int32, command: String)], Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "pid=,command="]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let me = ProcessInfo.processInfo.processIdentifier
                let rows = out.split(separator: "\n").compactMap { line -> (pid: Int32, command: String)? in
                    let trimmed = line.drop(while: { $0 == " " })
                    guard let pid = Int32(trimmed.prefix(while: { $0.isNumber })), pid != me else { return nil }
                    return (pid, String(trimmed))
                }
                continuation.resume(returning: rows)
            }
            do { try process.run() } catch { continuation.resume(returning: []) }
        }
    }

    public func aliveSessions(among sessionIDs: [String]) async -> Set<String> {
        let table = await processTable()
        return Set(sessionIDs.filter { id in table.contains { $0.command.contains(id) } })
    }

    public func terminate(sessionID: String) async {
        for row in await processTable() where row.command.contains(sessionID) { kill(row.pid, SIGTERM) }
    }
}
