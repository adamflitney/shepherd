import Foundation
import ShepherdCore
import ShepherdGhostty
import ShepherdHolder
import ShepherdTasks

/// `SessionBackend` over PTY holders: every agent runs in a holder process the app started, so sessions outlive the
/// app and can be attached from more than one place. Compared with the Ghostty backend:
///  - the list of sessions is the holder registry; a holder that answers is live, one that does not is *interrupted*
///    (the Mac restarted or the holder crashed) and can be brought back with `--resume`,
///  - keys and text go straight into the PTY,
///  - what an agent is doing still comes from Claude Code's hooks (the state files in `~/.shepherd/state`),
///  - there is no terminal window of its own: `focus` hands the session to `showSession`, which the dashboard
///    window provides (nothing yet, so `focus` throws until it is set).
public actor HolderSessionBackend: SessionBackend {
    public struct Pace: Sendable {
        public var afterText: UInt64
        public var betweenKeys: UInt64
        public var transcriptSettle: UInt64
        public init(afterText: UInt64 = 200_000_000, betweenKeys: UInt64 = 80_000_000, transcriptSettle: UInt64 = 300_000_000) {
            self.afterText = afterText; self.betweenKeys = betweenKeys; self.transcriptSettle = transcriptSettle
        }
        public static let none = Pace(afterText: 0, betweenKeys: 0, transcriptSettle: 0)
    }

    private let registry: SessionRegistry
    private let launcher: HolderLauncher
    private let taskStore: TaskStore
    private let prSync: TaskPRSync?
    private let hookStates: HookStateStore
    private let seen: SeenStore
    private let home: URL
    private let claudeCommand: String
    private let crookPath: String?
    private let webPort: Int?
    private let loginShell: String?
    private let remoteControlNames: Bool
    private let pace: Pace
    private let now: @Sendable () -> Date
    private var showSession: (@Sendable (SessionID) async -> Void)?

    private var liveness: [String: SessionLiveness] = [:]   // holder id -> last probe
    private var lastSeen: [String: Date]
    private var titleChecked: [String: Date] = [:]
    private var published: [String: Session] = [:]
    private var attentionSince: [String: (key: String, since: Date)] = [:]
    private var connection: ConnectionState = .idle
    private let hub = BackendEventHub()
    private var loops: [Task<Void, Never>] = []
    private var watchers: [DirectoryWatcher] = []

    public init(
        registry: SessionRegistry = .standard,
        launcher: HolderLauncher,
        taskStore: TaskStore = TaskStore(),
        hookStates: HookStateStore = HookStateStore(staleAfter: .infinity),
        seen: SeenStore = SeenStore(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        claudeCommand: String = ClaudeLocator.find(),
        crookPath: String? = nil,
        webPort: Int? = nil,
        loginShell: String? = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        remoteControlNames: Bool = false,
        prSync: TaskPRSync? = nil,
        pace: Pace = Pace(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.registry = registry; self.launcher = launcher; self.taskStore = taskStore; self.hookStates = hookStates
        self.seen = seen; self.home = home; self.claudeCommand = claudeCommand; self.crookPath = crookPath; self.webPort = webPort
        self.loginShell = loginShell; self.remoteControlNames = remoteControlNames; self.pace = pace; self.now = now
        self.prSync = prSync
        self.lastSeen = seen.load()
    }

    public nonisolated func events() -> AsyncStream<BackendEvent> { hub.makeStream() }

    /// The holder id behind a session, which names its socket (`shepherd-holder attach <id>`).
    public func holderID(for id: SessionID) -> String? {
        visibleRecords().first { $0.claudeSessionID == id.rawValue }?.id
    }

    /// The dashboard window registers itself here to be shown a session.
    public func setShowSession(_ handler: (@Sendable (SessionID) async -> Void)?) { showSession = handler }

    // MARK: - SessionBackend

    public func snapshot() async throws -> SessionsSnapshot {
        refresh(full: true)
        return currentSnapshot()
    }

    public func focus(_ id: SessionID) async throws {
        var record = try record(for: id)
        if liveness[record.id] == .interrupted {
            record = try resume(record)
        }
        markSeen(id)
        republish()
        guard let showSession else { throw BackendError.unsupported("there is no window to show the session in yet") }
        await showSession(id)
    }

    public func createSession(_ request: CreateSessionRequest) async throws -> SessionID {
        guard request.agent == .claude else { throw BackendError.unsupported("only Claude Code sessions can be started") }
        var task: TaskFile?
        if let taskID = request.taskID {
            guard let t = taskStore.get(taskID) else { throw BackendError.remote(code: "no_task", message: "no task \(taskID)") }
            task = t
        }
        var cwd = request.workingDirectory.path
        guard cwd.hasPrefix("/") else { throw BackendError.remote(code: "no_directory", message: "no working directory") }
        var madeForThisSession = false
        if task == nil, let explicit = request.resumeSessionID { task = taskStore.findBySession(explicit) }
        if task == nil {
            madeForThisSession = true
            let title = request.title ?? placeholderTitlePrefix + URL(fileURLWithPath: cwd).lastPathComponent
            task = try? taskStore.create(NewTask(title: title, projectPath: cwd))
            if let made = task { task = (try? taskStore.update(made.id) { $0.setStatus(.active) }) ?? made }
        }

        // A task with an earlier conversation on disk picks it up; anything else starts fresh under an id of our own,
        // so the link to the task exists before the agent has printed a thing.
        let sessionID: String
        var resuming = false
        if let explicit = request.resumeSessionID {
            sessionID = explicit; resuming = true
            if let ran = task?.sessionNotes.first(where: { $0.id == explicit })?.cwd { cwd = ran }
        } else if !request.fresh, let prior = resumableSession(of: task, in: cwd) {
            sessionID = prior.id; resuming = true; cwd = prior.cwd
        } else {
            sessionID = UUID().uuidString.lowercased()
        }
        if let live = registry.all().first(where: { $0.claudeSessionID == sessionID && registry.liveness($0) == .live }) {
            _ = live
            return SessionID(rawValue: sessionID)   // already running: nothing to start
        }

        let title = task.map { "#\($0.id) \($0.title)" } ?? request.title ?? URL(fileURLWithPath: cwd).lastPathComponent
        let prompt = resuming ? nil : (request.initialPrompt ?? (task != nil && !madeForThisSession ? (request.fresh ? Self.pickUpPrompt : Self.defaultTaskPrompt) : nil))
        var extra: [String] = remoteControlNames ? ["--remote-control", title] : []
        if let prompt { extra.append(prompt) }

        var env = ["SHEPHERD_SESSION_ID": sessionID]
        if let crookPath { env["SHEPHERD_CROOK"] = crookPath }
        if let webPort { env["SHEPHERD_WEB_PORT"] = String(webPort) }
        if let task { env["SHEPHERD_TASK_ID"] = String(task.id) }
        if let task {
            _ = try? taskStore.update(task.id) {
                if !resuming { $0.linkSession(sessionID) }
                $0.recordSession(id: sessionID, cwd: cwd, title: request.title)
            }
        }

        let spec = SessionSpec(taskID: task?.id, agent: .claude, claudeSessionID: sessionID, cwd: cwd,
                               argv: ClaudeCommand.argv(claudePath: claudeCommand, sessionID: sessionID, resume: resuming, extra: extra, loginShell: loginShell),
                               env: env, title: title, startedWithPrompt: prompt != nil)
        do { try launcher.launch(spec) } catch { throw BackendError.unavailable("\(error)") }
        lastSeen[sessionID] = now()
        persistSeen()
        refresh(full: true)
        republish()
        return SessionID(rawValue: sessionID)
    }

    public func close(_ id: SessionID) async throws {
        var record = try record(for: id)
        if liveness[record.id] == .live {
            HolderClient.kill(socketPath: registry.socketPath(record.id))
        } else {
            record.state = .killed
            record.endedAt = now()
            try? registry.save(record)
        }
        refresh(full: true)
        republish()
    }

    public func prompt(_ id: SessionID, text: String) async throws {
        let record = try liveRecord(for: id)
        guard let attachment = HolderClient.attach(socketPath: registry.socketPath(record.id)) else { throw BackendError.unavailable("the session does not answer") }
        defer { attachment.detach() }
        // Text and Enter in one go would be taken for a paste with a newline in it, not a submit.
        let body = attachment.modes.contains(2004) ? Array("\u{1b}[200~\(text)\u{1b}[201~".utf8) : Array(text.utf8)
        attachment.send(body)
        if pace.afterText > 0 { try? await Task.sleep(nanoseconds: pace.afterText) }
        attachment.send([13])
        markSeen(id)
    }

    public func respond(_ id: SessionID, keys: [String]) async throws {
        let record = try liveRecord(for: id)
        // What the question looks like decides what a digit means: a multi-select checklist is not the numbered menu
        // a single-choice question is.
        let attention = published[record.claudeSessionID ?? ""]?.attention
        let actions: [GhosttyKeyAction]
        if let attention, attention.kind == .blocked, attention.blocker == .needsAnswer, attention.optionsAllowMultiple, let options = attention.options {
            actions = GhosttyKeyMap.multiSelectActions(for: keys, optionCount: options.count)
        } else {
            actions = GhosttyKeyMap.actions(for: keys)
        }
        guard let attachment = HolderClient.attach(socketPath: registry.socketPath(record.id)) else { throw BackendError.unavailable("the session does not answer") }
        defer { attachment.detach() }
        for chunk in KeyBytes.chunks(for: actions) {
            attachment.send(chunk.bytes)
            if pace.betweenKeys > 0 { try? await Task.sleep(nanoseconds: pace.betweenKeys) }
            if chunk.pauseAfter > 0, pace.betweenKeys > 0 { try? await Task.sleep(nanoseconds: chunk.pauseAfter) }
        }
        markSeen(id)
    }

    /// The end of the conversation, from its transcript.
    public func peek(_ id: SessionID) async throws -> String {
        let record = try record(for: id)
        let url = TranscriptPeek.transcriptURL(workingDirectory: record.cwd, sessionID: id.rawValue, home: home)
        // The Stop hook fires a moment before Claude Code has written the last reply to the transcript.
        if pace.transcriptSettle > 0, published[id.rawValue]?.attention.kind != .working {
            for _ in 0..<4 where TranscriptPeek.recentMessages(at: url).last?.isUser == true {
                try? await Task.sleep(nanoseconds: pace.transcriptSettle)
            }
        }
        let text = TranscriptPeek.recentText(at: url)
        return text.isEmpty ? "(nothing said yet)" : text
    }

    /// Something has looked at the session (the dashboard shows it): a finish stops counting as unseen.
    public func markSeen(_ id: SessionID) {
        lastSeen[id.rawValue] = now()
        persistSeen()
    }

    // MARK: - observing

    public func startListening() {
        guard loops.isEmpty else { return }
        try? FileManager.default.createDirectory(at: hookStates.directoryURL, withIntermediateDirectories: true)
        try? registry.prepare()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        try? FileManager.default.createDirectory(at: taskStore.directory, withIntermediateDirectories: true)
        watchers = [hookStates.directoryURL, registry.directory, taskStore.directory].compactMap { DirectoryWatcher(url: $0) { continuation.yield() } }

        loops.append(Task { [weak self] in
            await self?.refresh(full: true)
            await self?.republish(announceConnection: true)
            for await _ in stream {
                try? await Task.sleep(nanoseconds: 80_000_000)  // coalesce the burst a hook write makes
                await self?.refresh(full: false)
                await self?.republish()
            }
        })
        if let prSync {
            let store = taskStore
            loops.append(Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    prSync.sync(store)
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                }
            })
        }
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.refresh(full: true)
                await self?.republish()
            }
        })
    }

    public func stopListening() {
        loops.forEach { $0.cancel() }
        loops = []
        watchers = []
    }

    /// `full` also probes every holder's socket (cheap, but a connect each), so the hook-driven path skips it.
    func refresh(full: Bool) {
        guard full else { return }
        var next: [String: SessionLiveness] = [:]
        for record in registry.all() where record.agent == .claude { next[record.id] = registry.liveness(record) }
        liveness = next
        connection = .connected
    }

    // MARK: - building sessions

    private func visibleRecords() -> [SessionRecord] {
        registry.all().filter { r in
            guard r.agent == .claude, r.claudeSessionID != nil else { return false }
            let l = liveness[r.id] ?? (r.state == .running ? .live : .ended)
            return l == .live || l == .interrupted
        }
    }

    private func currentSnapshot() -> SessionsSnapshot {
        let sessions = buildSessions()
        published = Dictionary(sessions.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
        let groups = Dictionary(sessions.compactMap { s in s.group.map { ($0.id, $0) } }, uniquingKeysWith: { a, _ in a }).values.sorted { $0.label < $1.label }
        return SessionsSnapshot(sessions: sessions, groups: Array(groups), focusedSessionID: nil)
    }

    private func buildSessions() -> [Session] {
        let states = hookStates.allStates()
        return visibleRecords().map { r in
            let sid = r.claudeSessionID ?? r.id
            let interrupted = liveness[r.id] == .interrupted
            let hook = hookState(for: sid, in: states)
            let seenAt = lastSeen[sid] ?? r.startedAt
            let unseen = (hook?.updatedAt ?? .distantPast) > seenAt
            var attention: AttentionState
            if interrupted {
                attention = AttentionState(kind: .idle, summary: "Interrupted. Resume to continue the conversation.")
            } else {
                attention = ghosttyAttention(hook: hook, unseenFinish: unseen)
                if hook == nil, r.startedWithPrompt == true, now().timeIntervalSince(r.startedAt) > ghosttyStartupGrace {
                    attention = folderTrustAttention()
                }
            }
            attention.since = since(for: sid, attention: attention, fallback: hook?.updatedAt ?? r.startedAt)

            var task = r.taskID.flatMap { taskStore.get($0) } ?? taskStore.findBySession(sid) ?? adoptIntoTask(r, sessionID: sid)
            if var found = task {
                if !found.sessionNotes.contains(where: { $0.id == sid }) {
                    found = (try? taskStore.update(found.id) { $0.recordSession(id: sid, cwd: r.cwd, title: r.title, now: r.startedAt) }) ?? found
                }
                task = retitledFromTranscript(found, record: r, sessionID: sid)
            }
            let group = task.map { SessionGroup(id: "task-\($0.id)", label: "#\($0.id) \($0.title)") }
                ?? SessionGroup(id: r.cwd, label: URL(fileURLWithPath: r.cwd).lastPathComponent)
            return Session(
                id: SessionID(rawValue: sid), title: task != nil ? group.label : (r.title ?? group.label), agent: .claude, workingDirectory: URL(fileURLWithPath: r.cwd),
                attention: attention, isFocused: false, group: group, lastActivityAt: hook?.updatedAt,
                capabilities: interrupted ? [.focus, .close] : [.focus, .prompt, .close])
        }.sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
    }

    /// The hook state for a session: the file named after its id, or (after `/clear` changed Claude's own id) the
    /// newest one that carries the id shepherd launched it under.
    private func hookState(for sessionID: String, in states: [String: ParsedHookState]) -> ParsedHookState? {
        let candidates = states.values.filter { $0.shepherdSessionID == sessionID } + (states[sessionID].map { [$0] } ?? [])
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
    }

    // MARK: - helpers

    static let defaultTaskPrompt = "Start on the task described in your session context."
    static let pickUpPrompt = "This is a new session picking the task up from an earlier one. Read the handoff, notes and plan in your session context, look in the task's workspace for scripts and files, then tell me where things stand and what you would do next."

    private func record(for id: SessionID) throws -> SessionRecord {
        guard let r = visibleRecords().first(where: { $0.claudeSessionID == id.rawValue }) else { throw BackendError.unknownSession(id) }
        return r
    }

    private func liveRecord(for id: SessionID) throws -> SessionRecord {
        let r = try record(for: id)
        guard liveness[r.id] != .interrupted else { throw BackendError.unavailable("the session was interrupted; resume it first") }
        return r
    }

    private func resume(_ record: SessionRecord) throws -> SessionRecord {
        var env: [String: String] = ["SHEPHERD_SESSION_ID": record.claudeSessionID ?? ""]
        if let crookPath { env["SHEPHERD_CROOK"] = crookPath }
        if let webPort { env["SHEPHERD_WEB_PORT"] = String(webPort) }
        if let task = record.taskID { env["SHEPHERD_TASK_ID"] = String(task) }
        let extra = remoteControlNames ? ["--remote-control", record.title ?? "shepherd"] : []
        do {
            let resumed = try launcher.resume(record.id, claudePath: claudeCommand, extra: extra, env: env, loginShell: loginShell)
            refresh(full: true)
            return resumed
        } catch { throw BackendError.unavailable("\(error)") }
    }

    private func persistSeen() { seen.save(lastSeen) }

    /// The task's newest conversation that has a transcript and is not already running.
    /// A session from before every session had a task (or one started with the command line) gets one the first time it
    /// is listed, so nothing on the board is without a task.
    private func adoptIntoTask(_ record: SessionRecord, sessionID: String) -> TaskFile? {
        let title = record.title ?? placeholderTitlePrefix + URL(fileURLWithPath: record.cwd).lastPathComponent
        guard let made = try? taskStore.create(NewTask(title: title, projectPath: record.cwd)) else { return nil }
        return try? taskStore.update(made.id) { $0.linkSession(sessionID); $0.recordSession(id: sessionID, cwd: record.cwd, title: record.title); $0.setStatus(.active) }
    }

    /// A task started from a bare session has nothing but a placeholder title. Once the conversation exists it takes Claude
    /// Code's own title for it (the `ai-title` entries in the transcript) and, if it has no objective, the first thing the
    /// user typed. After that both are the user's to change, so neither is ever overwritten.
    private func retitledFromTranscript(_ task: TaskFile, record: SessionRecord, sessionID: String) -> TaskFile {
        let needsTitle = task.title.hasPrefix(placeholderTitlePrefix)
        guard needsTitle || task.objective == nil else { return task }
        let url = TranscriptPeek.transcriptURL(workingDirectory: record.cwd, sessionID: sessionID, home: home)
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              titleChecked[sessionID] != modified else { return task }
        titleChecked[sessionID] = modified
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return task }
        var title: String?
        var firstPrompt: String?
        for line in text.split(separator: "\n") {
            let isTitle = line.contains("\"ai-title\""), isUser = firstPrompt == nil && line.contains("\"type\":\"user\"")
            guard isTitle || isUser,
                  let data = line.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if isTitle, let candidate = object["aiTitle"] as? String { title = candidate }
            if firstPrompt == nil, object["type"] as? String == "user", (object["origin"] as? [String: Any])?["kind"] as? String == "human",
               let message = object["message"] as? [String: Any], let content = message["content"] as? String {
                let words = content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !words.isEmpty, !words.hasPrefix("<"), words != Self.defaultTaskPrompt, words != Self.pickUpPrompt {
                    firstPrompt = words.count > 500 ? String(words.prefix(500)) + "…" : words
                }
            }
        }
        let newTitle = needsTitle ? title?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let newObjective = task.objective == nil ? firstPrompt : nil
        guard (newTitle?.isEmpty == false && newTitle!.count <= 200) || newObjective != nil else { return task }
        return (try? taskStore.update(task.id) {
            if let newTitle, !newTitle.isEmpty, newTitle.count <= 200 { $0.setTitle(newTitle) }
            if let newObjective { $0.setObjective(newObjective) }
        }) ?? task
    }

    /// The newest earlier conversation of the task that is not running and whose transcript is still on disk, looked for
    /// in the folder each session actually ran in (a task can have worked in several), and for sessions from before
    /// folders were noted, in `cwd`.
    private func resumableSession(of task: TaskFile?, in cwd: String) -> (id: String, cwd: String)? {
        guard let task else { return nil }
        let running = Set(registry.all().filter { registry.liveness($0) == .live }.compactMap(\.claudeSessionID))
        let noted = Dictionary(task.sessionNotes.map { ($0.id, $0.cwd) }, uniquingKeysWith: { first, _ in first })
        for id in task.sessions.reversed() where !running.contains(id) {
            let ran = noted[id] ?? cwd
            if FileManager.default.fileExists(atPath: TranscriptPeek.transcriptURL(workingDirectory: ran, sessionID: id, home: home).path) {
                return (id, ran)
            }
        }
        return nil
    }
}

/// When someone last looked at each session, so "finished while you were away" survives a restart.
/// `~/.shepherd/holder-seen.json`.
public struct SeenStore: Sendable {
    private let url: URL

    public init(url: URL = URL(fileURLWithPath: NSString(string: "~/.shepherd/holder-seen.json").expandingTildeInPath)) { self.url = url }

    public func load() -> [String: Date] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Date].self, from: data)) ?? [:]
    }

    public func save(_ values: [String: Date]) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(values).write(to: url, options: .atomic)
    }
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
