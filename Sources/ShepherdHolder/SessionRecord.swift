import Foundation

public enum AgentKind: String, Codable, Sendable {
    case claude
    /// Test-only: runs whatever argv it is given. `HolderLauncher` refuses it unless the caller opts in.
    case shell
}

/// One session as the holder and the app both see it. The holder writes it at start and at exit, so it stays correct
/// when the app is not running.
public struct SessionRecord: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case running, exited, killed, failed
    }

    public var id: String
    public var taskID: Int?
    public var agent: AgentKind
    public var claudeSessionID: String?
    public var cwd: String
    public var argv: [String]
    public var cols: Int
    public var rows: Int
    public var state: State
    public var holderPID: Int32?
    public var childPID: Int32?
    public var startedAt: Date
    public var endedAt: Date?
    public var exitStatus: Int32?
    public var error: String?

    public init(id: String, taskID: Int? = nil, agent: AgentKind, claudeSessionID: String? = nil, cwd: String, argv: [String],
                cols: Int, rows: Int, state: State = .running, holderPID: Int32? = nil, childPID: Int32? = nil,
                startedAt: Date = Date(), endedAt: Date? = nil, exitStatus: Int32? = nil, error: String? = nil) {
        self.id = id; self.taskID = taskID; self.agent = agent; self.claudeSessionID = claudeSessionID
        self.cwd = cwd; self.argv = argv; self.cols = cols; self.rows = rows; self.state = state
        self.holderPID = holderPID; self.childPID = childPID; self.startedAt = startedAt
        self.endedAt = endedAt; self.exitStatus = exitStatus; self.error = error
    }
}

public enum SessionLiveness: Equatable, Sendable {
    /// The holder answers on its socket.
    case live
    /// The record says running but nothing answers: the holder crashed or the Mac restarted. A Claude session can be
    /// brought back with `--resume`.
    case interrupted
    case ended
}

/// One JSON file per session under a directory (default `~/.shepherd/sessions`), next to its socket and log.
public struct SessionRegistry: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static var standard: SessionRegistry {
        let home = ProcessInfo.processInfo.environment["SHEPHERD_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".shepherd")
        return SessionRegistry(directory: home.appendingPathComponent("sessions"))
    }

    public func recordURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }
    public func socketPath(_ id: String) -> String { directory.appendingPathComponent("\(id).sock").path }
    public func logPath(_ id: String) -> String { directory.appendingPathComponent("\(id).log").path }
    func specURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).spec.json") }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    public func save(_ record: SessionRecord) throws {
        try prepare()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: recordURL(record.id), options: .atomic)
    }

    public func load(_ id: String) -> SessionRecord? {
        guard let data = try? Data(contentsOf: recordURL(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionRecord.self, from: data)
    }

    public func all() -> [SessionRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".spec.json") }
            .compactMap { load(String($0.dropLast(5))) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    public func liveness(_ record: SessionRecord) -> SessionLiveness {
        guard record.state == .running else { return .ended }
        return HolderClient.isLive(socketPath: socketPath(record.id)) ? .live : .interrupted
    }

    /// Removes a session's files (record, socket, log). Used to dismiss an interrupted or ended session.
    public func remove(_ id: String) {
        for url in [recordURL(id), specURL(id), URL(fileURLWithPath: socketPath(id)), URL(fileURLWithPath: logPath(id))] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
