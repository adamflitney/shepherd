import Foundation
import ShepherdCore
import ShepherdTasks
import Testing
@testable import ShepherdGhostty

/// Everything a backend needs, rooted in a fresh temp directory.
private struct Rig {
    let root: URL
    let scripting = FakeGhosttyScripting()
    let probe = FakeProbe()
    let windows = MemoryWindowStore()
    let tasks: TaskStore
    let stateDir: URL
    let home: URL
    let recordsURL: URL
    let clock = Clock()

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
    }

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-\(UUID().uuidString)")
        tasks = TaskStore(directory: root.appendingPathComponent("tasks"))
        stateDir = root.appendingPathComponent("state")
        home = root.appendingPathComponent("home")
        recordsURL = root.appendingPathComponent("sessions.json")
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    func backend() -> GhosttySessionBackend {
        let clock = self.clock
        return GhosttySessionBackend(
            scripting: scripting, taskStore: tasks, recordStore: GhosttyRecordStore(url: recordsURL),
            hookStates: HookStateStore(directory: stateDir, now: { clock.now }, staleAfter: .infinity),
            probe: probe, agentsWindow: windows, home: home, claudeCommand: "claude", pace: .none, now: { clock.now })
    }

    /// Writes a hook state file the way `shepherd_write_state.py` does.
    func writeHook(session: String, state: String, detail: [String: Any] = [:], at date: Date, shepherdID: String? = nil) throws {
        var doc: [String: Any] = ["schema": 1, "session_id": session, "state": state, "detail": detail,
                                  "updated_at": ISO8601DateFormatter().string(from: date)]
        if let shepherdID { doc["shepherd_session_id"] = shepherdID }
        try JSONSerialization.data(withJSONObject: doc).write(to: stateDir.appendingPathComponent("\(session).json"))
    }

    func writeTranscript(session: String, cwd: String, lines: [[String: Any]]) throws {
        let url = TranscriptPeek.transcriptURL(workingDirectory: cwd, sessionID: session, home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

private func req(_ cwd: String = "/work/app", task: Int? = nil, prompt: String? = nil) -> CreateSessionRequest {
    CreateSessionRequest(workingDirectory: URL(fileURLWithPath: cwd), agent: .claude, initialPrompt: prompt, taskID: task)
}

private func openCall(_ rig: Rig) -> (command: String, cwd: String, env: [String: String], windowID: String?)? {
    for case .open(let c, let cwd, let env, let w) in rig.scripting.calls { return (c, cwd, env, w) }
    return nil
}

@Suite("GhosttySessionBackend: starting sessions")
struct StartingTests {
    @Test func startsAPlainSessionUnderAnIdWeChoose() async throws {
        let rig = Rig()
        let backend = rig.backend()
        let id = try await backend.createSession(req("/work/app", prompt: "fix the build"))
        let open = try #require(openCall(rig))
        #expect(open.command == "claude --session-id \(id.rawValue) 'fix the build'")
        #expect(open.cwd == "/work/app")
        #expect(open.env == ["SHEPHERD_SESSION_ID": id.rawValue])
        #expect(open.windowID == nil)  // first session: no agents window yet, so a new one is made
        let snapshot = try await backend.snapshot()
        #expect(snapshot.sessions.map(\.id) == [id])
        #expect(snapshot.sessions[0].attention.kind == .unknown)  // no hook has spoken yet
        #expect(snapshot.sessions[0].title == "app")
    }

    @Test func rememberstheAgentsWindowAndReusesIt() async throws {
        let rig = Rig()
        let backend = rig.backend()
        _ = try await backend.createSession(req())
        #expect(rig.windows.get() == "win-1")
        _ = try await backend.createSession(req())
        let opens = rig.scripting.calls.compactMap { call -> String?? in if case .open(_, _, _, let w) = call { return .some(w) } else { return nil } }
        #expect(opens == [nil, "win-1"])
    }

    @Test func aTaskSessionIsLinkedBeforeTheAgentStartsAndGetsTheTaskEnvironment() async throws {
        let rig = Rig()
        let task = try rig.tasks.create(NewTask(title: "Board", projectPath: "/work/board"))
        let backend = rig.backend()
        let id = try await backend.createSession(req("/work/board", task: task.id))
        let open = try #require(openCall(rig))
        #expect(open.cwd == "/work/board")
        #expect(open.env["SHEPHERD_TASK_ID"] == "1")
        #expect(open.command.contains("'Start on the task described in your session context.'"))
        #expect(rig.tasks.get(task.id)?.sessions == [id.rawValue])
        let session = try await backend.snapshot().sessions[0]
        #expect(session.title == "#1 Board")
        #expect(session.group?.label == "#1 Board")
    }

    @Test func aTaskResumesItsNewestConversationWhenOneExistsAndIsNotRunning() async throws {
        let rig = Rig()
        let task = try rig.tasks.create(NewTask(title: "Board", projectPath: "/work/board"))
        try rig.tasks.update(task.id) { $0.linkSession("old-1"); $0.linkSession("old-2") }
        try rig.writeTranscript(session: "old-2", cwd: "/work/board", lines: [])
        rig.probe.everythingAlive = false  // nothing is running
        let backend = rig.backend()
        let id = try await backend.createSession(req("/work/board", task: task.id))
        #expect(id.rawValue == "old-2")
        let open = try #require(openCall(rig))
        #expect(open.command == "claude --resume old-2")  // no prompt when resuming
        #expect(rig.tasks.get(task.id)?.sessions == ["old-1", "old-2"])  // no second link
    }

    @Test func aTaskStartsFreshWhenItsConversationIsAlreadyRunningOrHasNoTranscript() async throws {
        let rig = Rig()
        let task = try rig.tasks.create(NewTask(title: "Board", projectPath: "/work/board"))
        try rig.tasks.update(task.id) { $0.linkSession("running-1") }
        try rig.writeTranscript(session: "running-1", cwd: "/work/board", lines: [])
        let backend = rig.backend()  // the fake probe says everything is alive
        let id = try await backend.createSession(req("/work/board", task: task.id))
        #expect(id.rawValue != "running-1")
        #expect(rig.tasks.get(task.id)?.sessions.count == 2)
    }

    @Test func rejectsUnknownTasksAndOtherAgentsAndReportsGhosttyProblems() async throws {
        let rig = Rig()
        let backend = rig.backend()
        await #expect(throws: BackendError.remote(code: "no_task", message: "no task 9")) { try await backend.createSession(req(task: 9)) }
        await #expect(throws: BackendError.self) {
            try await backend.createSession(CreateSessionRequest(workingDirectory: URL(fileURLWithPath: "/x"), agent: .opencode))
        }
        rig.scripting.failOpenWith = .notRunning
        await #expect(throws: BackendError.unavailable("Ghostty is not running")) { try await backend.createSession(req()) }
    }

    @Test func quotesPromptsSoTheyReachTheAgentAsOneArgument() async throws {
        #expect(shellQuote("it's $HOME; rm -rf /") == "'it'\\''s $HOME; rm -rf /'")
        let rig = Rig()
        _ = try await rig.backend().createSession(req(prompt: "what's \"this\"?"))
        #expect(try #require(openCall(rig)).command.hasSuffix("'what'\\''s \"this\"?'"))
    }

    @Test func sessionsSurviveARestartOfShepherd() async throws {
        let rig = Rig()
        let id = try await rig.backend().createSession(req())
        rig.scripting.setTerminals([GhosttyTerminalInfo(ref: GhosttyTerminalRef(windowID: "win-1", tabID: "tab-1", terminalID: "term-1"), name: "✳ Fix it")])
        let again = rig.backend()  // a new process, same files
        let snapshot = try await again.snapshot()
        #expect(snapshot.sessions.map(\.id) == [id])
        #expect(snapshot.sessions[0].title == "✳ Fix it")  // the live terminal title wins
    }
}

@Suite("GhosttySessionBackend: configuration")
struct ConfigurationTests {
    @Test func tellsTheAgentWhereCrookIsWhenItIsInstalled() async throws {
        let rig = Rig()
        let clock = rig.clock
        let backend = GhosttySessionBackend(
            scripting: rig.scripting, taskStore: rig.tasks, recordStore: GhosttyRecordStore(url: rig.recordsURL),
            hookStates: HookStateStore(directory: rig.stateDir, now: { clock.now }, staleAfter: .infinity),
            probe: rig.probe, agentsWindow: rig.windows, home: rig.home, claudeCommand: "claude",
            crookPath: "/h/.shepherd/bin/crook", pace: .none, now: { clock.now })
        let id = try await backend.createSession(req())
        #expect(try #require(openCall(rig)).env == ["SHEPHERD_SESSION_ID": id.rawValue, "SHEPHERD_CROOK": "/h/.shepherd/bin/crook"])
    }

    @Test func useFrontmostWindowPointsNewSessionsAtGhosttysFrontWindow() async throws {
        let rig = Rig()
        let backend = rig.backend()
        #expect(try await backend.useFrontmostWindowForAgents() == "win-1")  // what the fake reports as the front window
        #expect(rig.windows.get() == "win-1")
        rig.windows.set("somewhere-else")
        _ = try await backend.useFrontmostWindowForAgents()
        _ = try await backend.createSession(req())
        #expect(try #require(openCall(rig)).windowID == "win-1")
    }
}

@Suite("GhosttySessionBackend: attention from hooks")
struct AttentionTests {
    private func started(_ rig: Rig) async throws -> (GhosttySessionBackend, String) {
        let backend = rig.backend()
        let id = try await backend.createSession(req())
        return (backend, id.rawValue)
    }

    @Test func followsATurnFromWorkingToBlockedToDone() async throws {
        let rig = Rig()
        let (backend, id) = try await started(rig)
        let t1 = rig.clock.now.addingTimeInterval(5)
        func attention() async throws -> AttentionState { try await backend.snapshot().sessions[0].attention }

        try rig.writeHook(session: id, state: "working", detail: ["todos": ["done": 1, "total": 3, "activeForm": "Testing"]], at: t1)
        var a = try await attention()
        #expect(a.kind == .working)
        #expect(a.progress == TaskProgress(completed: 1, total: 3, currentItem: "Testing"))

        try rig.writeHook(session: id, state: "needs-permission", detail: ["tool_name": "Bash", "summary": "Bash: npm test"], at: t1.addingTimeInterval(1))
        a = try await attention()
        #expect(a.kind == .blocked)
        #expect(a.blocker == .needsPermission)
        #expect(a.summary == "Bash: npm test")

        try rig.writeHook(session: id, state: "asked-a-question", detail: ["question": "Which db?", "options": ["pg", "sqlite"], "multi_select": true], at: t1.addingTimeInterval(2))
        a = try await attention()
        #expect(a.blocker == .needsAnswer)
        #expect(a.options == ["pg", "sqlite"])
        #expect(a.optionsAllowMultiple)

        try rig.writeHook(session: id, state: "idle", at: t1.addingTimeInterval(3))
        a = try await attention()
        #expect(a.kind == .done)  // finished and nobody looked
    }

    @Test func aFinishedSessionBecomesIdleOnceSomeoneLooksOrTypes() async throws {
        let rig = Rig()
        let (backend, id) = try await started(rig)
        try rig.writeHook(session: id, state: "idle", at: rig.clock.now.addingTimeInterval(5))
        #expect(try await backend.snapshot().sessions[0].attention.kind == .done)

        rig.clock.advance(10)
        try await backend.focus(SessionID(rawValue: id))
        #expect(try await backend.snapshot().sessions[0].attention.kind == .idle)

        // a later finish is unseen again
        try rig.writeHook(session: id, state: "idle", at: rig.clock.now.addingTimeInterval(5))
        #expect(try await backend.snapshot().sessions[0].attention.kind == .done)
        rig.clock.advance(10)
        try await backend.prompt(SessionID(rawValue: id), text: "thanks")
        #expect(try await backend.snapshot().sessions[0].attention.kind == .idle)
    }

    @Test func aFinishWhileTheSessionIsInFrontIsNeverDone() async throws {
        let rig = Rig()
        let (backend, id) = try await started(rig)
        rig.scripting.frontmost = "term-1"
        await backend.pollFocus()
        try rig.writeHook(session: id, state: "idle", at: rig.clock.now.addingTimeInterval(5))
        let session = try await backend.snapshot().sessions[0]
        #expect(session.isFocused)
        #expect(session.attention.kind == .idle)
    }

    @Test func aStalledStopKeepsItsTodoProgress() async throws {
        let rig = Rig()
        let (backend, id) = try await started(rig)
        try rig.writeHook(session: id, state: "stalled", detail: ["todos": ["done": 1, "total": 2]], at: rig.clock.now.addingTimeInterval(5))
        let a = try await backend.snapshot().sessions[0].attention
        #expect(a.progress == TaskProgress(completed: 1, total: 2))
    }

    @Test func followsASessionThroughClearViaTheShepherdSessionId() async throws {
        let rig = Rig()
        let (backend, id) = try await started(rig)
        // after /clear Claude Code reports under a new id, but the hook records the id we launched it with
        try rig.writeHook(session: "claude-new-id", state: "working", at: rig.clock.now.addingTimeInterval(5), shepherdID: id)
        #expect(try await backend.snapshot().sessions[0].attention.kind == .working)
    }

    @Test func sinceOnlyMovesWhenTheStateChanges() async throws {
        let rig = Rig()
        let (backend, id) = try await started(rig)
        let t = rig.clock.now.addingTimeInterval(5)
        try rig.writeHook(session: id, state: "working", at: t)
        let first = try await backend.snapshot().sessions[0].attention.since
        rig.clock.advance(60)
        let second = try await backend.snapshot().sessions[0].attention.since
        #expect(first == second)
        try rig.writeHook(session: id, state: "needs-permission", detail: ["summary": "Bash: ls"], at: rig.clock.now)
        rig.clock.advance(1)
        let third = try await backend.snapshot().sessions[0].attention.since
        #expect(third != first)
    }

    @Test func aSessionWhoseProcessHasEndedDisappears() async throws {
        let rig = Rig()
        let (backend, id) = try await started(rig)
        #expect(try await backend.snapshot().sessions.count == 1)
        rig.probe.everythingAlive = false
        rig.probe.alive = []
        let snapshot = try await backend.snapshot()
        #expect(snapshot.sessions.isEmpty, "session \(id) should be gone")
    }

    @Test func aSessionWhoseTerminalWasClosedDisappears() async throws {
        let rig = Rig()
        let (backend, _) = try await started(rig)
        rig.scripting.setTerminals([])  // the user closed the tab
        #expect(try await backend.snapshot().sessions.isEmpty)
    }
}

@Suite("GhosttySessionBackend: driving a session")
struct DrivingTests {
    private func started(_ rig: Rig) async throws -> (GhosttySessionBackend, SessionID) {
        let backend = rig.backend()
        return (backend, try await backend.createSession(req()))
    }

    @Test func promptTypesTheTextThenPressesEnterSeparately() async throws {
        let rig = Rig()
        let (backend, id) = try await started(rig)
        try await backend.prompt(id, text: "run the tests")
        #expect(Array(rig.scripting.calls.suffix(2)) == [
            .inputText("run the tests", terminal: "term-1"),
            .sendKey("enter", modifiers: [], terminal: "term-1"),
        ])
    }

    @Test func respondTranslatesKeysIncludingDigitsThatPickMenuOptions() async throws {
        let rig = Rig()
        let (backend, id) = try await started(rig)
        try await backend.respond(id, keys: ["down", "enter"])
        try await backend.respond(id, keys: ["3"])
        try await backend.respond(id, keys: ["esc", "ctrl+c", "y"])
        let sent = rig.scripting.calls.dropFirst().map { "\($0)" }
        #expect(sent.count == 2 + 3 + 3)
        #expect(Array(rig.scripting.calls.dropFirst().prefix(2)) == [
            .sendKey("arrowDown", modifiers: [], terminal: "term-1"), .sendKey("enter", modifiers: [], terminal: "term-1"),
        ])
        #expect(Array(rig.scripting.calls.suffix(3)) == [
            .sendKey("escape", modifiers: [], terminal: "term-1"),
            .sendKey("c", modifiers: ["control"], terminal: "term-1"),
            .inputText("y", terminal: "term-1"),
        ])
    }

    @Test func focusRaisesTheTerminal() async throws {
        let rig = Rig()
        let (backend, id) = try await started(rig)
        try await backend.focus(id)
        #expect(rig.scripting.calls.last == .focus("term-1"))
    }

    @Test func closeEndsTheProcessFirstThenTheTerminalAndForgetsTheSession() async throws {
        let rig = Rig()
        let (backend, id) = try await started(rig)
        try await backend.close(id)
        #expect(rig.probe.terminated == [id.rawValue])
        #expect(rig.scripting.calls.last == .close("term-1"))
        #expect(try await backend.snapshot().sessions.isEmpty)
        await #expect(throws: BackendError.unknownSession(id)) { try await backend.focus(id) }
    }

    @Test func peekReadsTheEndOfTheTranscript() async throws {
        let rig = Rig()
        let (backend, id) = try await started(rig)
        try rig.writeTranscript(session: id.rawValue, cwd: "/work/app", lines: [
            ["type": "user", "message": ["role": "user", "content": "fix the build"]],
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "On it."], ["type": "tool_use", "name": "Bash"]]]],
            ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "ok"]]]],
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "Fixed: the lockfile was stale."]]]],
        ])
        let text = try await backend.peek(id)
        #expect(text == "› fix the build\n\nOn it.\n\nFixed: the lockfile was stale.")
    }

    @Test func peekSaysSoWhenThereIsNoTranscriptYet() async throws {
        let rig = Rig()
        let (backend, id) = try await started(rig)
        #expect(try await backend.peek(id) == "(nothing said yet)")
    }
}

@Suite("Ghostty helpers")
struct HelperTests {
    @Test func keyMapTranslatesTheVocabularyShepherdUses() {
        func names(_ keys: [String]) -> [String] {
            GhosttyKeyMap.actions(for: keys).map { a in
                switch a.kind {
                case .key(let n, let m): return ([n] + m).joined(separator: "+")
                case .text(let t): return "text:\(t)"
                }
            }
        }
        #expect(names(["down", "up", "enter", "esc"]) == ["arrowDown", "arrowUp", "enter", "escape"])
        #expect(names(["1"]) == ["enter"])
        #expect(names(["2"]) == ["arrowDown", "enter"])
        #expect(names(["4"]) == ["arrowDown", "arrowDown", "arrowDown", "enter"])
        #expect(names(["ctrl+c"]) == ["c+control"])
        #expect(names(["shift+tab"]) == ["tab+shift"])
        #expect(names(["y"]) == ["text:y"])
        #expect(names(["-"]) == ["text:-"])
    }

    @Test func parsesTerminalListings() throws {
        let sep = "\u{1F}"
        let reply = "w1\(sep)t1\(sep)T-A\(sep)✳ Fix it\nw1\(sep)t2\(sep)T-B\(sep)\n"
        let parsed = try OsascriptGhosttyScripting.parseTerminals(reply)
        #expect(parsed.map(\.ref.terminalID) == ["T-A", "T-B"])
        #expect(parsed.map(\.name) == ["✳ Fix it", ""])
        #expect(throws: GhosttyError.self) { try OsascriptGhosttyScripting.parseTerminals("garbage\n") }
    }

    @Test func escapesAppleScriptStrings() {
        #expect(AppleScript.quote(#"say "hi" \ now"#) == #""say \"hi\" \\ now""#)
    }

    @Test func transcriptPathsUseClaudesProjectDirectoryEncoding() {
        let url = TranscriptPeek.transcriptURL(workingDirectory: "/Users/a.b/dev/my app", sessionID: "abc", home: URL(fileURLWithPath: "/h"))
        #expect(url.path == "/h/.claude/projects/-Users-a-b-dev-my-app/abc.jsonl")
    }
}

@Suite("ClaudeLocator")
struct ClaudeLocatorTests {
    @Test func prefersTheFirstExecutableOnPathThenFallsBackToTheUsualPlaces() {
        let home = URL(fileURLWithPath: "/h")
        #expect(ClaudeLocator.find(pathEnvironment: "/a:/b", home: home, isExecutable: { $0 == "/b/claude" }) == "/b/claude")
        #expect(ClaudeLocator.find(pathEnvironment: "/a", home: home, isExecutable: { $0 == "/h/.local/bin/claude" }) == "/h/.local/bin/claude")
        #expect(ClaudeLocator.find(pathEnvironment: "", home: home, isExecutable: { _ in false }) == "claude")
    }
}

@Suite("Subprocesses")
struct SubprocessTests {
    @Test func drainsOutputBiggerThanAPipeWithoutStalling() async throws {
        // 300 KB on stdout and 200 KB on stderr: more than a pipe holds, as a full `ps` listing is
        let r = try await ProcessRunner.run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' a; head -c 200000 /dev/zero | tr '\\0' b >&2"])
        #expect(r.status == 0)
        #expect(r.stdout.count == 300_000)
        #expect(r.stderr.count == 200_000)
    }

    @Test func passesStdinAndReportsFailure() async throws {
        let r = try await ProcessRunner.run("/bin/sh", ["-c", "cat; exit 3"], stdin: "hello")
        #expect(r.stdout == "hello")
        #expect(r.status == 3)
    }

    @Test func theRealProbeSeesAProcessByItsSessionIdAndCanEndIt() async throws {
        let id = UUID().uuidString.lowercased()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30; true", id]  // the id is in the command line, as `claude --session-id <id>` has it; "; true" stops sh from exec-ing sleep and dropping it
        try process.run()
        defer { process.terminate() }
        let probe = PSProcessProbe()
        #expect(await probe.aliveSessions(among: [id, "00000000-nope"]) == [id])
        await probe.terminate(sessionID: id)
        process.waitUntilExit()
        #expect(await probe.aliveSessions(among: [id]).isEmpty)
    }
}

@Suite("Peek timing")
struct PeekTimingTests {
    @Test func peekWaitsForTheReplyThatTheStopHookOutranAndGivesUpIfItNeverComes() async throws {
        let rig = Rig()
        let clock = rig.clock
        let backend = GhosttySessionBackend(
            scripting: rig.scripting, taskStore: rig.tasks, recordStore: GhosttyRecordStore(url: rig.recordsURL),
            hookStates: HookStateStore(directory: rig.stateDir, now: { clock.now }, staleAfter: .infinity),
            probe: rig.probe, agentsWindow: rig.windows, home: rig.home, claudeCommand: "claude",
            pace: .init(afterText: 0, betweenKeys: 0, afterTerminate: 0, transcriptSettle: 50_000_000), now: { clock.now })
        let id = try await backend.createSession(req())
        let user: [String: Any] = ["type": "user", "message": ["role": "user", "content": "hello"]]
        let reply: [String: Any] = ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "Hi there."]]]]
        try rig.writeTranscript(session: id.rawValue, cwd: "/work/app", lines: [user])

        // the reply lands 120 ms into the wait, as it does in life
        let url = TranscriptPeek.transcriptURL(workingDirectory: "/work/app", sessionID: id.rawValue, home: rig.home)
        let both = try [user, reply].map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        let late = Task {
            try await Task.sleep(nanoseconds: 120_000_000)
            try both.write(to: url, atomically: true, encoding: .utf8)
        }
        #expect(try await backend.peek(id) == "› hello\n\nHi there.")
        try await late.value

        // and a reply that never comes costs a bounded wait, not a hang
        try rig.writeTranscript(session: id.rawValue, cwd: "/work/app", lines: [user])
        let started = Date()
        #expect(try await backend.peek(id) == "› hello")
        #expect(Date().timeIntervalSince(started) < 2)
    }
}
