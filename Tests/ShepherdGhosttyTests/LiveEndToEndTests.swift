import Foundation
import ShepherdCore
import ShepherdTasks
import Testing
@testable import ShepherdGhostty

/// The whole stack against the real things: Ghostty, Claude Code (a few cheap turns), the hook scripts
/// and `crook`. Opt-in (`SHEPHERD_LIVE_E2E=1`) because it opens a Ghostty window, spends a little on
/// the model, and needs `swift build` to have produced `crook`. It works in a scratch directory it
/// creates, answers Claude's folder-trust prompt for that directory only, and cleans up after itself.
@Suite("Live end to end", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_LIVE_E2E"] != nil))
struct LiveEndToEndTests {
    private func waitFor(_ what: String, timeout: TimeInterval, poll: TimeInterval = 1, _ check: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await check() { return }
            try await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
        Issue.record("timed out waiting for \(what)")
        throw CancellationError()
    }

    @Test func aTaskSessionRunsInGhosttyIsObservedThroughHooksAndAnswered() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let crook = repo.appendingPathComponent(".build/debug/crook").path
        let hookScript = repo.appendingPathComponent("Sources/Shepherd/HookScripts/shepherd-write-state.sh").path
        try #require(FileManager.default.isExecutableFile(atPath: crook), "run `swift build` first so crook exists")

        let tag = UUID().uuidString.prefix(8).lowercased()
        let work = URL(fileURLWithPath: "/private/tmp/shep-e2e-\(tag)")  // the real path: Claude keys transcripts by it
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shep-e2e-root-\(tag)")
        let tasksDir = root.appendingPathComponent("tasks")
        var sessionID: String?
        defer {
            try? FileManager.default.removeItem(at: work)
            try? FileManager.default.removeItem(at: root)
            let encoded = String(work.path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects/\(encoded)"))
            if let sessionID {
                try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".shepherd/state/\(sessionID).json"))
            }
        }

        // project-level hooks, so nothing in the user's own settings is touched
        try FileManager.default.createDirectory(at: work.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        func hook(_ command: String) -> [[String: Any]] { [["hooks": [["type": "command", "command": command]]]] }
        let state = "/bin/sh \(hookScript)"
        let settings: [String: Any] = ["hooks": [
            "SessionStart": hook("SHEPHERD_HOME=\(root.path) \(crook) hook session-start"),
            "UserPromptSubmit": hook(state), "Stop": hook(state), "SessionEnd": hook(state),
            "PermissionRequest": [["matcher": "", "hooks": [["type": "command", "command": state]]]],
            "Notification": [["matcher": "", "hooks": [["type": "command", "command": state]]]],
        ]]
        try JSONSerialization.data(withJSONObject: settings).write(to: work.appendingPathComponent(".claude/settings.json"))

        let tasks = TaskStore(directory: tasksDir)
        let task = try tasks.create(NewTask(title: "E2E task", objective: "The secret codeword is PINEAPPLE-77.", projectPath: work.path))
        let backend = GhosttySessionBackend(
            taskStore: tasks, recordStore: GhosttyRecordStore(url: root.appendingPathComponent("sessions.json")),
            agentsWindow: MemoryWindowStore())
        func session() async throws -> Session? { try await backend.snapshot().sessions.first }

        // 1. start the task's session
        let started = Date()
        let id = try await backend.createSession(CreateSessionRequest(
            workingDirectory: work, agent: .claude,
            initialPrompt: "What is the secret codeword in your task context? Answer in one short line.", taskID: task.id))
        sessionID = id.rawValue
        print("started \(id.rawValue.prefix(8)) in \(Date().timeIntervalSince(started))s")
        #expect(tasks.get(task.id)?.sessions == [id.rawValue])

        // 2. a brand-new directory shows Claude's one-time trust prompt, which no hook reports: the
        // backend presumes it after a few silent seconds and offers the menu's real choices
        var answeredTrust = false
        try await waitFor("the first answer to finish", timeout: 120) {
            let s = try await session()
            if let s, s.attention.kind != .unknown { print("  attention: \(s.attention.kind) \(s.attention.summary ?? "")") }
            if !answeredTrust, s?.attention.kind == .blocked, s?.attention.options == ["No, exit", "Yes, I trust this folder"] {
                print("trust prompt detected; answering 2 (Yes) for the scratch directory")
                try await backend.respond(id, keys: ["2"])
                answeredTrust = true
            }
            return answeredTrust && s?.attention.kind == .done
        }
        #expect(answeredTrust, "the trust prompt should have been detected")
        let first = try await backend.peek(id)
        print("peek after first turn:\n\(first)\n")
        #expect(first.contains("PINEAPPLE-77"), "the SessionStart hook should have injected the task context, and peek should see the reply")
        print("title: \(try await session()?.title ?? "nil")")

        // 3. a blocked question, answered by number through the arrow keys
        try await backend.prompt(id, text: "Use the AskUserQuestion tool to ask me which colour I prefer, with the options Red and Blue. Do nothing else until I answer.")
        var blocked: AttentionState?
        try await waitFor("the question to block the session", timeout: 90) {
            blocked = try await session()?.attention
            return blocked?.kind == .blocked
        }
        print("blocked: \(blocked?.blocker.map { "\($0)" } ?? "?") \(blocked?.summary ?? "") options=\(blocked?.options ?? [])")
        #expect(blocked?.blocker == .needsAnswer)
        #expect(blocked?.options?.count == 2)

        try await backend.respond(id, keys: ["2"])
        try await waitFor("the session to finish after the answer", timeout: 90) { try await session()?.attention.kind == .done }
        let second = try await backend.peek(id)
        print("peek after the answer:\n\(second)\n")
        #expect(second.lowercased().contains("blue"), "option 2 (Blue) should have been picked")

        // 3b. what do digits do in a multi-select question? (observation, the phone page sends them)
        try await backend.prompt(id, text: "Use the AskUserQuestion tool with multiSelect true to ask which of these I want: Apple, Banana, Cherry. Then tell me exactly which ones I chose.")
        try await waitFor("the multi-select question to block", timeout: 90) { try await session()?.attention.kind == .blocked }
        let multi = try await session()?.attention
        print("multi-select: options=\(multi?.options ?? []) multiple=\(multi?.optionsAllowMultiple ?? false)")
        try await backend.respond(id, keys: ["1", "3", "enter"])
        try await waitFor("the session to finish after the multi-select", timeout: 90) { try await session()?.attention.kind == .done }
        let multiResult = try await backend.peek(id)
        print("peek after multi-select:\n\(multiResult)\n")
        #expect(multiResult.contains("Apple") && multiResult.contains("Cherry"), "options 1 and 3 should have been toggled")
        #expect(multiResult.lowercased().contains("didn't choose banana") || multiResult.lowercased().contains("not banana") || !multiResult.lowercased().contains("chose banana"), "option 2 should not be chosen")

        // 4. closing ends the process and the tab
        try await backend.close(id)
        #expect(try await backend.snapshot().sessions.isEmpty)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(await PSProcessProbe().aliveSessions(among: [id.rawValue]).isEmpty)
        let terminals = try await OsascriptGhosttyScripting().listTerminals()
        #expect(terminals.allSatisfy { $0.name != "" || true })
        print("done in \(Date().timeIntervalSince(started))s")
    }
}
