import Foundation
import ShepherdCore
import ShepherdTasks

/// `SessionBackend` over Ghostty: agents run in ordinary Ghostty tabs, started and driven through
/// Ghostty's AppleScript interface. Ghostty can neither read a screen nor report events, so
///  - what an agent is doing comes from Claude Code's hooks (the state files in `~/.shepherd/state`),
///  - what it said comes from its transcript,
///  - whether it is still running comes from the process table,
///  - and shepherd keeps a record of each session it started.
public actor GhosttySessionBackend: SessionBackend {
    private let scripting: any GhosttyScripting
    private let taskStore: TaskStore
    private let recordStore: GhosttyRecordStore
    private let hookStates: HookStateStore
    private let probe: any ProcessProbe
    private let agentsWindow: any AgentsWindowStoring
    private let home: URL
    private let claudeCommand: String
    private let now: @Sendable () -> Date
    private let pace: Pace

    /// Delays that keep keystrokes in the order the agent's TUI expects. Zero in tests.
    public struct Pace: Sendable {
        public var afterText: UInt64
        public var betweenKeys: UInt64
        public var afterTerminate: UInt64
        public init(afterText: UInt64 = 200_000_000, betweenKeys: UInt64 = 80_000_000, afterTerminate: UInt64 = 800_000_000) {
            self.afterText = afterText
            self.betweenKeys = betweenKeys
            self.afterTerminate = afterTerminate
        }
        public static let none = Pace(afterText: 0, betweenKeys: 0, afterTerminate: 0)
    }

    private var records: [String: GhosttySessionRecord]
    private var terminalNames: [String: String] = [:]  // terminal id -> title
    private var published: [String: Session] = [:]
    private var attentionSince: [String: (key: String, since: Date)] = [:]
    private var focusedTerminalID: String?
    private var connection: ConnectionState = .idle
    private let hub = BackendEventHub()
    private var tasks: [Task<Void, Never>] = []
    private var watcher: DirectoryWatcher?

    public init(
        scripting: any GhosttyScripting = OsascriptGhosttyScripting(),
        taskStore: TaskStore = TaskStore(),
        recordStore: GhosttyRecordStore = GhosttyRecordStore(),
        hookStates: HookStateStore = HookStateStore(staleAfter: .infinity),
        probe: any ProcessProbe = PSProcessProbe(),
        agentsWindow: any AgentsWindowStoring = FileAgentsWindowStore(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        claudeCommand: String = "claude",
        pace: Pace = Pace(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.scripting = scripting
        self.taskStore = taskStore
        self.recordStore = recordStore
        self.hookStates = hookStates
        self.probe = probe
        self.agentsWindow = agentsWindow
        self.home = home
        self.claudeCommand = claudeCommand
        self.pace = pace
        self.now = now
        self.records = Dictionary(recordStore.load().filter { $0.endedAt == nil }.map { ($0.sessionID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public nonisolated func events() -> AsyncStream<BackendEvent> { hub.makeStream() }

    // MARK: - SessionBackend

    public func snapshot() async throws -> SessionsSnapshot {
        await refresh(full: true)
        return currentSnapshot()
    }

    public func focus(_ id: SessionID) async throws {
        let record = try record(for: id)
        guard let ref = record.ref else { throw BackendError.unavailable("the session has no terminal") }
        do {
            try await scripting.focus(terminalID: ref.terminalID)
        } catch let e as GhosttyError {
            throw backendError(e)
        }
        markSeen(record.sessionID)
        republish()
    }

    public func createSession(_ request: CreateSessionRequest) async throws -> SessionID {
        guard request.agent == .claude else { throw BackendError.unsupported("only Claude Code sessions can be started in Ghostty") }

        var task: TaskFile?
        if let taskID = request.taskID {
            guard let t = taskStore.get(taskID) else { throw BackendError.remote(code: "no_task", message: "no task \(taskID)") }
            task = t
        }
        let cwd = request.workingDirectory.path
        guard !cwd.isEmpty else { throw BackendError.remote(code: "no_directory", message: "no working directory") }

        // A task with an earlier conversation on disk picks it up; anything else starts fresh under an
        // id of our choosing, so the link to the task exists before the agent has printed a thing.
        var sessionID: String
        var resuming = false
        if let explicit = request.resumeSessionID {
            sessionID = explicit
            resuming = true
        } else if let prior = await resumableSession(of: task, in: cwd) {
            sessionID = prior
            resuming = true
        } else {
            sessionID = UUID().uuidString.lowercased()
        }

        var command = "\(claudeCommand) " + (resuming ? "--resume" : "--session-id") + " \(sessionID)"
        let prompt = resuming ? nil : (request.initialPrompt ?? (task != nil ? Self.defaultTaskPrompt : nil))
        if let prompt { command += " " + shellQuote(prompt) }

        var env = ["SHEPHERD_SESSION_ID": sessionID]
        if let task { env["SHEPHERD_TASK_ID"] = String(task.id) }
        if let task, !resuming { _ = try? taskStore.update(task.id) { $0.linkSession(sessionID) } }

        let ref: GhosttyTerminalRef
        do {
            ref = try await scripting.open(command: command, workingDirectory: cwd, environment: env, windowID: agentsWindow.get())
        } catch let e as GhosttyError {
            throw backendError(e)
        }
        agentsWindow.set(ref.windowID)

        let title = request.title ?? task.map { "#\($0.id) \($0.title)" } ?? URL(fileURLWithPath: cwd).lastPathComponent
        records[sessionID] = GhosttySessionRecord(
            sessionID: sessionID, taskID: task?.id, agent: request.agent.rawValue, workingDirectory: cwd,
            title: title, ref: ref, createdAt: now(), lastSeenAt: now())
        persist()
        await refresh(full: false)
        republish()
        return SessionID(rawValue: sessionID)
    }

    public func close(_ id: SessionID) async throws {
        let record = try record(for: id)
        await probe.terminate(sessionID: record.sessionID)
        if pace.afterTerminate > 0 { try? await Task.sleep(nanoseconds: pace.afterTerminate) }
        if let ref = record.ref { try? await scripting.close(terminalID: ref.terminalID) }
        records[record.sessionID]?.endedAt = now()
        persist()
        republish()
    }

    public func prompt(_ id: SessionID, text: String) async throws {
        let record = try record(for: id)
        let ref = try terminal(of: record)
        do {
            try await scripting.inputText(text, terminalID: ref.terminalID)
            // text and Enter in one go would be taken for a paste with a newline in it, not a submit
            if pace.afterText > 0 { try? await Task.sleep(nanoseconds: pace.afterText) }
            try await scripting.sendKey("enter", modifiers: [], terminalID: ref.terminalID)
        } catch let e as GhosttyError {
            throw backendError(e)
        }
        markSeen(record.sessionID)
    }

    public func respond(_ id: SessionID, keys: [String]) async throws {
        let record = try record(for: id)
        let ref = try terminal(of: record)
        do {
            for action in GhosttyKeyMap.actions(for: keys) {
                switch action.kind {
                case .key(let name, let modifiers): try await scripting.sendKey(name, modifiers: modifiers, terminalID: ref.terminalID)
                case .text(let text): try await scripting.inputText(text, terminalID: ref.terminalID)
                }
                if pace.betweenKeys > 0 { try? await Task.sleep(nanoseconds: pace.betweenKeys) }
            }
        } catch let e as GhosttyError {
            throw backendError(e)
        }
        markSeen(record.sessionID)
    }

    /// The end of the conversation, from its transcript (Ghostty cannot read the screen).
    public func peek(_ id: SessionID) async throws -> String {
        let record = try record(for: id)
        let url = TranscriptPeek.transcriptURL(workingDirectory: record.workingDirectory, sessionID: record.sessionID, home: home)
        let text = TranscriptPeek.recentText(at: url)
        return text.isEmpty ? "(nothing said yet)" : text
    }

    // MARK: - observing

    /// Starts watching hook state, polling for liveness slowly and for focus only while something is
    /// waiting to be looked at. Safe to call twice.
    public func startListening() {
        guard tasks.isEmpty else { return }
        let dir = hookStates.directoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        watcher = DirectoryWatcher(url: dir) { continuation.yield() }

        tasks.append(Task { [weak self] in
            await self?.refresh(full: true)
            await self?.republish(announceConnection: true)
            for await _ in stream {
                try? await Task.sleep(nanoseconds: 80_000_000)  // coalesce the burst a hook write makes
                await self?.refresh(full: false)
                await self?.republish()
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.refresh(full: true)
                await self?.republish()
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                if await self.wantsFocusPoll() {
                    await self.pollFocus()
                    await self.republish()
                }
            }
        })
    }

    public func stopListening() {
        tasks.forEach { $0.cancel() }
        tasks = []
        watcher = nil
    }

    func wantsFocusPoll() -> Bool {
        published.values.contains { $0.attention.kind == .done || $0.attention.kind == .blocked }
    }

    func pollFocus() async {
        focusedTerminalID = (try? await scripting.frontmostTerminalID()) ?? nil
        if let focused = focusedTerminalID, let r = records.values.first(where: { $0.ref?.terminalID == focused }) {
            markSeen(r.sessionID)
        }
    }

    /// Re-reads everything that can change. `full` also asks Ghostty for its terminals and the process
    /// table for liveness, which cost a subprocess each, so the hook-driven path skips them.
    func refresh(full: Bool) async {
        if full {
            let alive = await probe.aliveSessions(among: Array(records.keys))
            do {
                let terminals = try await scripting.listTerminals()
                terminalNames = Dictionary(terminals.map { ($0.ref.terminalID, $0.name) }, uniquingKeysWith: { a, _ in a })
                connection = .connected
                let present = Set(terminals.map(\.ref.terminalID))
                for (id, r) in records where r.endedAt == nil {
                    // Ghostty restarted (the terminal is gone) or the agent exited: the session is over
                    let terminalGone = r.ref.map { !present.contains($0.terminalID) } ?? true
                    if !alive.contains(id) || terminalGone { records[id]?.endedAt = now() }
                }
            } catch {
                // Ghostty not running: sessions keep their records, but are unreachable
                connection = .unavailable(reason: "\(error)")
                for id in records.keys where !alive.contains(id) { records[id]?.endedAt = now() }
            }
            persist()
        }
    }

    // MARK: - building sessions

    private func currentSnapshot() -> SessionsSnapshot {
        let sessions = buildSessions()
        published = Dictionary(sessions.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
        let groups = Dictionary(sessions.compactMap { s in s.group.map { ($0.id, $0) } }, uniquingKeysWith: { a, _ in a }).values.sorted { $0.label < $1.label }
        let focused = sessions.first { $0.isFocused }?.id
        return SessionsSnapshot(sessions: sessions, groups: Array(groups), focusedSessionID: focused)
    }

    private func buildSessions() -> [Session] {
        let states = hookStates.allStates()
        return records.values.filter { $0.endedAt == nil }.sorted { $0.createdAt < $1.createdAt }.map { r in
            let hook = hookState(for: r, in: states)
            let isFocused = r.ref?.terminalID != nil && r.ref?.terminalID == focusedTerminalID
            let seenAt = r.lastSeenAt ?? r.createdAt
            let unseen = !isFocused && (hook?.updatedAt ?? .distantPast) > seenAt
            var attention = ghosttyAttention(hook: hook, unseenFinish: unseen)
            attention.since = since(for: r.sessionID, attention: attention, fallback: hook?.updatedAt ?? r.createdAt)

            let task = r.taskID.flatMap { taskStore.get($0) }
            let group = task.map { SessionGroup(id: "task-\($0.id)", label: "#\($0.id) \($0.title)") }
                ?? SessionGroup(id: r.workingDirectory, label: URL(fileURLWithPath: r.workingDirectory).lastPathComponent)
            let liveTitle = r.ref.flatMap { terminalNames[$0.terminalID] }.flatMap { $0.isEmpty ? nil : $0 }
            let title = liveTitle.map { t in r.taskID.map { "#\($0) \(t)" } ?? t } ?? r.title
            return Session(
                id: SessionID(rawValue: r.sessionID), title: title, agent: AgentKind(rawValue: r.agent),
                workingDirectory: URL(fileURLWithPath: r.workingDirectory), attention: attention,
                isFocused: isFocused, group: group, lastActivityAt: hook?.updatedAt,
                capabilities: [.focus, .prompt, .close])
        }
    }

    /// The hook state for a session: the file named after its id, or (after `/clear` changed Claude's
    /// own id) the newest one that carries the id shepherd launched it under.
    private func hookState(for r: GhosttySessionRecord, in states: [String: ParsedHookState]) -> ParsedHookState? {
        let candidates = states.values.filter { $0.shepherdSessionID == r.sessionID } + (states[r.sessionID].map { [$0] } ?? [])
        return candidates.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
    }

    private func since(for id: String, attention: AttentionState, fallback: Date) -> Date {
        let key = "\(attention.kind.rawValue)|\(attention.blocker?.rawValue ?? "")|\(attention.summary ?? "")"
        if let existing = attentionSince[id], existing.key == key { return existing.since }
        let date = attentionSince[id] == nil ? fallback : now()
        attentionSince[id] = (key, date)
        return date
    }

    private func republish(announceConnection: Bool = false) {
        if announceConnection { hub.broadcast(.connection(connection)) }
        let before = published
        let snapshot = currentSnapshot()
        for s in snapshot.sessions where before[s.id.rawValue] != s { hub.broadcast(.sessionChanged(s)) }
        for id in before.keys where published[id] == nil { hub.broadcast(.sessionRemoved(SessionID(rawValue: id))) }
        if snapshot.focusedSessionID != before.values.first(where: { $0.isFocused })?.id { hub.broadcast(.focusChanged(snapshot.focusedSessionID)) }
    }

    // MARK: - helpers

    static let defaultTaskPrompt = "Start on the task described in your session context."

    private func record(for id: SessionID) throws -> GhosttySessionRecord {
        guard let r = records[id.rawValue], r.endedAt == nil else { throw BackendError.unknownSession(id) }
        return r
    }

    private func terminal(of r: GhosttySessionRecord) throws -> GhosttyTerminalRef {
        guard let ref = r.ref else { throw BackendError.unavailable("the session has no terminal") }
        return ref
    }

    private func markSeen(_ sessionID: String) {
        records[sessionID]?.lastSeenAt = now()
        persist()
    }

    private func persist() { recordStore.save(Array(records.values)) }

    /// The task's newest conversation that has a transcript and is not already running.
    private func resumableSession(of task: TaskFile?, in cwd: String) async -> String? {
        guard let task else { return nil }
        let running = await probe.aliveSessions(among: task.sessions)
        return task.sessions.reversed().first { id in
            !running.contains(id)
                && FileManager.default.fileExists(atPath: TranscriptPeek.transcriptURL(workingDirectory: cwd, sessionID: id, home: home).path)
        }
    }

    private func backendError(_ e: GhosttyError) -> BackendError {
        switch e {
        case .notRunning: return .unavailable("Ghostty is not running")
        case .timedOut: return .timedOut
        case .scriptFailed(let m), .malformedReply(let m): return .remote(code: "ghostty", message: m)
        }
    }
}

/// `'it'\''s'`: a string as one shell word.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Calls back whenever something in a directory is created, removed, renamed or written.
final class DirectoryWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping @Sendable () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .link], queue: .global(qos: .utility))
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
