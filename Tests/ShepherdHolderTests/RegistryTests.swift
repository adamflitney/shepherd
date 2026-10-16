import Foundation
import Testing
@testable import ShepherdHolder

func temporaryRegistry() -> SessionRegistry {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sh-\(UUID().uuidString.prefix(6))")
    return SessionRegistry(directory: dir)
}

@Suite("Session registry")
struct RegistryTests {
    private func record(_ id: String, state: SessionRecord.State = .running) -> SessionRecord {
        SessionRecord(id: id, taskID: 7, agent: .claude, claudeSessionID: "sid-\(id)", cwd: "/tmp", argv: ["/bin/sh"], cols: 100, rows: 30, state: state)
    }

    @Test func savesAndLoadsARecord() throws {
        let registry = temporaryRegistry()
        try registry.save(record("a1"))
        let loaded = try #require(registry.load("a1"))
        #expect(loaded.taskID == 7)
        #expect(loaded.claudeSessionID == "sid-a1")
        #expect(loaded.argv == ["/bin/sh"])
    }

    @Test func listsRecordsOldestFirstAndSkipsSpecFiles() throws {
        let registry = temporaryRegistry()
        var first = record("first"); first.startedAt = Date(timeIntervalSince1970: 100)
        var second = record("second"); second.startedAt = Date(timeIntervalSince1970: 200)
        try registry.save(second); try registry.save(first)
        try Data("{}".utf8).write(to: registry.specURL("first"))
        #expect(registry.all().map(\.id) == ["first", "second"])
    }

    @Test func aRunningRecordWithNoHolderIsInterrupted() throws {
        let registry = temporaryRegistry()
        let r = record("gone")
        try registry.save(r)
        #expect(registry.liveness(r) == .interrupted)
    }

    @Test func anEndedRecordIsEndedWhateverTheSocketSays() throws {
        let registry = temporaryRegistry()
        let r = record("done", state: .exited)
        try registry.save(r)
        #expect(registry.liveness(r) == .ended)
    }

    @Test func removeDeletesTheSessionsFiles() throws {
        let registry = temporaryRegistry()
        try registry.save(record("x"))
        registry.remove("x")
        #expect(registry.load("x") == nil)
    }

    @Test func ignoresACorruptRecord() throws {
        let registry = temporaryRegistry()
        try registry.prepare()
        try Data("not json".utf8).write(to: registry.recordURL("bad"))
        #expect(registry.all().isEmpty)
    }
}

@Suite("Launcher rules")
struct LauncherRuleTests {
    @Test func refusesTheShellAgentUnlessAllowed() {
        let launcher = HolderLauncher(registry: temporaryRegistry(), holderExecutable: "/nonexistent")
        #expect(throws: LaunchError.shellNotAllowed) {
            try launcher.launch(SessionSpec(agent: .shell, cwd: "/tmp", argv: ["/bin/sh"]))
        }
    }

    @Test func refusesAnEmptyCommandAndARelativeDirectory() {
        let launcher = HolderLauncher(registry: temporaryRegistry(), holderExecutable: "/nonexistent", allowShell: true)
        #expect(throws: LaunchError.emptyCommand) { try launcher.launch(SessionSpec(agent: .shell, cwd: "/tmp", argv: [])) }
        #expect(throws: LaunchError.relativeDirectory("here")) { try launcher.launch(SessionSpec(agent: .shell, cwd: "here", argv: ["/bin/sh"])) }
    }

    @Test func onlyAnInterruptedSessionCanBeResumed() throws {
        let registry = temporaryRegistry()
        try registry.save(SessionRecord(id: "e", agent: .claude, claudeSessionID: "s", cwd: "/tmp", argv: [], cols: 80, rows: 24, state: .exited))
        try registry.save(SessionRecord(id: "sh", agent: .shell, cwd: "/tmp", argv: ["/bin/sh"], cols: 80, rows: 24))
        let launcher = HolderLauncher(registry: registry, holderExecutable: "/nonexistent", allowShell: true)
        #expect(throws: LaunchError.notInterrupted("e")) { try launcher.resume("e", claudePath: "/x") }
        #expect(throws: LaunchError.notResumable("sh")) { try launcher.resume("sh", claudePath: "/x") }
        #expect(throws: LaunchError.notInterrupted("missing")) { try launcher.resume("missing", claudePath: "/x") }
    }
}
