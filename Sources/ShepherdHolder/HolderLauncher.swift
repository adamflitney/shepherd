import Foundation
import Darwin

public struct SessionSpec: Sendable {
    public var id: String
    public var taskID: Int?
    public var agent: AgentKind
    public var claudeSessionID: String?
    public var cwd: String
    public var argv: [String]
    public var env: [String: String]
    public var cols: Int
    public var rows: Int
    public var title: String?
    public var startedWithPrompt: Bool?

    public init(id: String = SessionSpec.newID(), taskID: Int? = nil, agent: AgentKind, claudeSessionID: String? = nil,
                cwd: String, argv: [String], env: [String: String] = [:], cols: Int = 100, rows: Int = 30,
                title: String? = nil, startedWithPrompt: Bool? = nil) {
        self.title = title; self.startedWithPrompt = startedWithPrompt
        self.id = id; self.taskID = taskID; self.agent = agent; self.claudeSessionID = claudeSessionID
        self.cwd = cwd; self.argv = argv; self.env = env; self.cols = cols; self.rows = rows
    }

    public static func newID() -> String { String(UUID().uuidString.prefix(8)).lowercased() }
}

public enum ClaudeCommand {
    /// `claude` runs under a wrapper shell, as in the spikes, so the PTY child is a shell that exits with claude's status.
    /// With `loginShell` the command runs in that shell as a login shell, so it gets the user's PATH the way a terminal
    /// tab does; a menu bar app's own environment is nearly empty.
    public static func argv(claudePath: String, sessionID: String, resume: Bool, extra: [String] = [], loginShell: String? = nil) -> [String] {
        let quoted = ([claudePath, resume ? "--resume" : "--session-id", sessionID] + extra).map(shellQuote).joined(separator: " ")
        guard let loginShell else { return ["/bin/sh", "-c", "\(quoted); exit $?"] }
        return [loginShell, "-l", "-c", "\(quoted); exit $?"]
    }

    static func shellQuote(_ s: String) -> String {
        s.isEmpty || s.contains(where: { !($0.isLetter || $0.isNumber || "/._-:=@".contains($0)) })
            ? "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" : s
    }
}

public enum LaunchError: Error, Equatable {
    case shellNotAllowed
    case emptyCommand
    case relativeDirectory(String)
    case holderDidNotStart(String)
    case notInterrupted(String)
    case notResumable(String)
}

/// Starts a holder as a detached process (its own session, output to a per-session log) and waits for its socket.
public struct HolderLauncher: Sendable {
    public let registry: SessionRegistry
    public let holderExecutable: String
    public var allowShell: Bool

    public init(registry: SessionRegistry, holderExecutable: String, allowShell: Bool = false) {
        self.registry = registry; self.holderExecutable = holderExecutable; self.allowShell = allowShell
    }

    @discardableResult
    public func launch(_ spec: SessionSpec) throws -> SessionRecord {
        if spec.agent == .shell && !allowShell { throw LaunchError.shellNotAllowed }
        guard !spec.argv.isEmpty else { throw LaunchError.emptyCommand }
        guard spec.cwd.hasPrefix("/") else { throw LaunchError.relativeDirectory(spec.cwd) }
        try registry.prepare()

        let record = SessionRecord(id: spec.id, taskID: spec.taskID, agent: spec.agent, claudeSessionID: spec.claudeSessionID,
                                   cwd: spec.cwd, argv: spec.argv, cols: spec.cols, rows: spec.rows,
                                   title: spec.title, startedWithPrompt: spec.startedWithPrompt)
        try registry.save(record)
        try writeSpec(spec)

        guard spawnDetached(arguments: ["hold", "--registry", registry.directory.path, "--id", spec.id], log: registry.logPath(spec.id)) else {
            throw LaunchError.holderDidNotStart("could not start \(holderExecutable)")
        }
        let socket = registry.socketPath(spec.id)
        for _ in 0..<100 {
            if HolderClient.isLive(socketPath: socket) { return registry.load(spec.id) ?? record }
            if let r = registry.load(spec.id), r.state == .failed { throw LaunchError.holderDidNotStart(r.error ?? "failed") }
            usleep(50_000)
        }
        throw LaunchError.holderDidNotStart("no answer on \(socket)")
    }

    /// Brings an interrupted Claude session back with `--resume`, keeping its id, task and directory.
    @discardableResult
    public func resume(_ id: String, claudePath: String, extra: [String] = [], env: [String: String] = [:], loginShell: String? = nil) throws -> SessionRecord {
        guard let record = registry.load(id), registry.liveness(record) == .interrupted else { throw LaunchError.notInterrupted(id) }
        guard record.agent == .claude, let sid = record.claudeSessionID else { throw LaunchError.notResumable(id) }
        return try launch(SessionSpec(id: record.id, taskID: record.taskID, agent: .claude, claudeSessionID: sid, cwd: record.cwd,
                                      argv: ClaudeCommand.argv(claudePath: claudePath, sessionID: sid, resume: true, extra: extra, loginShell: loginShell),
                                      env: env, cols: record.cols, rows: record.rows,
                                      title: record.title, startedWithPrompt: false))
    }

    private func writeSpec(_ spec: SessionSpec) throws {
        let object: [String: Any] = ["env": spec.env]
        let url = registry.specURL(spec.id)
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    private func spawnDetached(arguments: [String], log: String) -> Bool {
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var cargs: [UnsafeMutablePointer<CChar>?] = ([holderExecutable] + arguments).map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, holderExecutable, &actions, &attributes, cargs, environ) == 0
    }
}

/// What `shepherd-holder hold` runs: read the record the launcher wrote, then become the holder.
public enum HolderProcess {
    public static func run(registryDirectory: String, id: String) -> Int32 {
        let registry = SessionRegistry(directory: URL(fileURLWithPath: registryDirectory))
        guard let record = registry.load(id) else { logLine("no record for \(id)"); return 2 }
        var env: [String: String] = [:]
        if let data = try? Data(contentsOf: registry.specURL(id)),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            env = object["env"] as? [String: String] ?? [:]
        }
        try? FileManager.default.removeItem(at: registry.specURL(id))
        let final = Holder(config: HolderConfig(record: record, env: env, registry: registry)).run()
        return final.state == .failed ? 1 : 0
    }
}
