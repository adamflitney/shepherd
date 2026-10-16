import Foundation
import ShepherdCore
import ShepherdHolder
import ShepherdGhostty
import ShepherdTasks
import Testing
@testable import ShepherdHolderBackend

/// Real holders (the built `shepherd-holder`) running a stand-in for `claude` that prints what it was started with and
/// echoes every line it is typed.
private final class Rig: @unchecked Sendable {
    let root: URL
    let registry: SessionRegistry
    let tasks: TaskStore
    let stateDir: URL
    let fakeClaude: String
    let launcher: HolderLauncher
    let clock = Clock()

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date()
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
    }

    init() throws {
        root = URL(fileURLWithPath: "/tmp/hb-\(UUID().uuidString.prefix(6))")
        registry = SessionRegistry(directory: root.appendingPathComponent("s"))
        tasks = TaskStore(directory: root.appendingPathComponent("tasks"))
        stateDir = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        fakeClaude = root.appendingPathComponent("claude").path
        let script = """
        #!/bin/sh
        echo "argv: $@"
        echo "env: task=$SHEPHERD_TASK_ID sid=$SHEPHERD_SESSION_ID"
        while IFS= read -r line; do echo "got: $line"; done
        """
        try script.write(toFile: fakeClaude, atomically: true, encoding: .utf8)
        chmod(fakeClaude, 0o755)
        launcher = HolderLauncher(registry: registry, holderExecutable: try Self.holderExecutable())
    }

    static func holderExecutable() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { url.deleteLastPathComponent() }
        let candidates = [".build/debug/shepherd-holder", ".build/arm64-apple-macosx/debug/shepherd-holder", ".build/x86_64-apple-macosx/debug/shepherd-holder"]
        guard let found = candidates.map({ url.appendingPathComponent($0).path }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "rig", code: 1, userInfo: [NSLocalizedDescriptionKey: "shepherd-holder is not built"])
        }
        return found
    }

    func backend(remoteControl: Bool = false) -> HolderSessionBackend {
        let clock = self.clock
        return HolderSessionBackend(
            registry: registry, launcher: launcher, taskStore: tasks,
            hookStates: HookStateStore(directory: stateDir, staleAfter: .infinity),
            seen: SeenStore(url: root.appendingPathComponent("seen.json")),
            home: root.appendingPathComponent("home"), claudeCommand: fakeClaude, crookPath: "/x/crook",
            loginShell: nil, remoteControlNames: remoteControl, pace: .none, now: { clock.now })
    }

    func writeHook(session: String, state: String, at date: Date = Date()) throws {
        let doc: [String: Any] = ["schema": 1, "session_id": session, "state": state, "detail": [String: Any](),
                                  "updated_at": ISO8601DateFormatter().string(from: date)]
        try JSONSerialization.data(withJSONObject: doc).write(to: stateDir.appendingPathComponent("\(session).json"))
    }

    func screen(of sessionID: String) -> String {
        guard let r = registry.all().first(where: { $0.claudeSessionID == sessionID }),
              let bytes = HolderClient.dump(socketPath: registry.socketPath(r.id)) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    func waitForScreen(_ sessionID: String, containing text: String, seconds: Double = 5) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if screen(of: sessionID).contains(text) { return true }
            usleep(50_000)
        }
        return false
    }

    func teardown() {
        for r in registry.all() { HolderClient.kill(socketPath: registry.socketPath(r.id)) }
        usleep(400_000)
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Holder session backend", .serialized)
struct HolderSessionBackendTests {
    private func request(_ cwd: String = "/tmp", task: Int? = nil, prompt: String? = nil, title: String? = nil) -> CreateSessionRequest {
        CreateSessionRequest(workingDirectory: URL(fileURLWithPath: cwd), agent: .claude, initialPrompt: prompt, title: title, taskID: task)
    }

    @Test func startsAClaudeSessionInAHolderAndListsIt() async throws {
        let rig = try Rig(); defer { rig.teardown() }
        let backend = rig.backend()
        let id = try await backend.createSession(request(title: "scratch"))
        let snapshot = try await backend.snapshot()
        let session = try #require(snapshot.sessions.first)
        #expect(session.id == id)
        #expect(session.title == "scratch")
        #expect(session.capabilities.contains(.prompt))
        #expect(rig.waitForScreen(id.rawValue, containing: "argv: --session-id \(id.rawValue)"))
    }

    @Test func linksATaskBeforeTheAgentStartsAndPassesItsEnvironment() async throws {
        let rig = try Rig(); defer { rig.teardown() }
        let task = try rig.tasks.create(NewTask(title: "Fix login"))
        let backend = rig.backend()
        let id = try await backend.createSession(request(task: task.id))
        #expect(rig.tasks.get(task.id)?.sessions.contains(id.rawValue) == true)
        #expect(rig.waitForScreen(id.rawValue, containing: "env: task=\(task.id) sid=\(id.rawValue)"))
        let snapshot = try await backend.snapshot()
        #expect(snapshot.sessions.first?.group?.label == "#\(task.id) Fix login")
        #expect(rig.waitForScreen(id.rawValue, containing: "Start on the task described in your session context."))
    }

    @Test func passesTheTaskTitleAsTheRemoteControlNameWhenAsked() async throws {
        let rig = try Rig(); defer { rig.teardown() }
        let backend = rig.backend(remoteControl: true)
        let id = try await backend.createSession(request(title: "task: fix login"))
        #expect(rig.waitForScreen(id.rawValue, containing: "--remote-control task: fix login"))
    }

    @Test func promptTypesTextAndSubmitsIt() async throws {
        let rig = try Rig(); defer { rig.teardown() }
        let backend = rig.backend()
        let id = try await backend.createSession(request())
        _ = try await backend.snapshot()
        try await backend.prompt(id, text: "hello there")
        #expect(rig.waitForScreen(id.rawValue, containing: "got: hello there"))
    }

    @Test func respondSendsTheKeysTheAgentIsWaitingFor() async throws {
        let rig = try Rig(); defer { rig.teardown() }
        let backend = rig.backend()
        let id = try await backend.createSession(request())
        _ = try await backend.snapshot()
        try await backend.respond(id, keys: ["y", "enter"])
        #expect(rig.waitForScreen(id.rawValue, containing: "got: y"))
    }

    @Test func aSessionKilledOutsideTheAppShowsAsInterruptedAndResumes() async throws {
        let rig = try Rig(); defer { rig.teardown() }
        let backend = rig.backend()
        let id = try await backend.createSession(request(title: "survivor"))
        _ = try await backend.snapshot()
        let record = try #require(rig.registry.all().first)
        kill(try #require(record.holderPID), SIGKILL)
        usleep(300_000)

        let after = try await backend.snapshot()
        let session = try #require(after.sessions.first)
        #expect(session.id == id)
        #expect(session.attention.summary?.contains("Interrupted") == true)
        #expect(!session.capabilities.contains(.prompt))
        await #expect(throws: BackendError.self) { try await backend.prompt(id, text: "nope") }

        try? await backend.focus(id)   // resumes it; there is no window to show it in yet, so this throws afterwards
        let resumed = try await backend.snapshot()
        #expect(resumed.sessions.first?.attention.summary?.contains("Interrupted") != true)
        #expect(rig.waitForScreen(id.rawValue, containing: "argv: --resume \(id.rawValue)"))
    }

    @Test func closeEndsALiveSessionAndDropsItFromTheList() async throws {
        let rig = try Rig(); defer { rig.teardown() }
        let backend = rig.backend()
        let id = try await backend.createSession(request())
        _ = try await backend.snapshot()
        try await backend.close(id)
        let after = try await backend.snapshot()
        #expect(after.sessions.isEmpty)
    }

    @Test func closingAnInterruptedSessionDismissesIt() async throws {
        let rig = try Rig(); defer { rig.teardown() }
        let backend = rig.backend()
        let id = try await backend.createSession(request())
        _ = try await backend.snapshot()
        kill(try #require(rig.registry.all().first?.holderPID), SIGKILL)
        usleep(300_000)
        _ = try await backend.snapshot()
        try await backend.close(id)
        #expect(try await backend.snapshot().sessions.isEmpty)
    }

    @Test func aFinishedTurnCountsAsDoneUntilTheSessionIsSeen() async throws {
        let rig = try Rig(); defer { rig.teardown() }
        let backend = rig.backend()
        let id = try await backend.createSession(request())
        rig.clock.advance(10)
        try rig.writeHook(session: id.rawValue, state: "idle", at: rig.clock.now)
        #expect(try await backend.snapshot().sessions.first?.attention.kind == .done)
        rig.clock.advance(10)
        await backend.markSeen(id)
        #expect(try await backend.snapshot().sessions.first?.attention.kind == .idle)
    }

    @Test func aBlockedSessionReportsWhatItIsWaitingFor() async throws {
        let rig = try Rig(); defer { rig.teardown() }
        let backend = rig.backend()
        let id = try await backend.createSession(request())
        try rig.writeHook(session: id.rawValue, state: "needs-permission")
        let session = try #require(try await backend.snapshot().sessions.first)
        #expect(session.attention.kind == .blocked)
        #expect(session.attention.blocker == .needsPermission)
    }

    @Test func unknownSessionsAreRejected() async throws {
        let rig = try Rig(); defer { rig.teardown() }
        let backend = rig.backend()
        await #expect(throws: BackendError.unknownSession(SessionID(rawValue: "nope"))) { try await backend.close(SessionID(rawValue: "nope")) }
    }

    @Test func aTaskWithAnEarlierConversationResumesIt() async throws {
        let rig = try Rig(); defer { rig.teardown() }
        var task = try rig.tasks.create(NewTask(title: "Resume me"))
        let prior = "11111111-2222-3333-4444-555555555555"
        _ = try rig.tasks.update(task.id) { $0.linkSession(prior) }
        task = try #require(rig.tasks.get(task.id))
        let transcript = TranscriptPeek.transcriptURL(workingDirectory: "/tmp", sessionID: prior, home: rig.root.appendingPathComponent("home"))
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: transcript)

        let backend = rig.backend()
        let id = try await backend.createSession(request(task: task.id))
        #expect(id.rawValue == prior)
        #expect(rig.waitForScreen(prior, containing: "argv: --resume \(prior)"))
    }
}
