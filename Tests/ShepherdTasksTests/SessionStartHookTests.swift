import Foundation
import Testing
@testable import ShepherdTasks

@Suite("SessionStart hook")
struct SessionStartHookTests {
    private func makeStore() -> TaskStore {
        TaskStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("crook-hook-\(UUID().uuidString)"))
    }

    private func context(_ output: String?) -> String? {
        guard let output, let data = output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let h = obj["hookSpecificOutput"] as? [String: Any] else { return nil }
        return h["additionalContext"] as? String
    }

    @Test func injectsThePlanAndLogOfTheLinkedTask() throws {
        let store = makeStore()
        let t = try store.create(NewTask(title: "Board", objective: "ship it"))
        try store.update(t.id) { task in
            task.addPlanItem("do a")
            task.appendLog("did b")
            task.linkSession("s1")
        }
        let text = context(sessionStartHookOutput(SessionStartInput(sessionID: "s1", source: "resume"), env: [:], store: store))
        #expect(text?.contains("task #1: Board") == true)
        #expect(text?.contains("- [ ] do a") == true)
        #expect(text?.contains("did b") == true)
    }

    @Test func doesNothingForUnlinkedSessions() throws {
        let store = makeStore()
        try store.create(NewTask(title: "Board"))
        #expect(sessionStartHookOutput(SessionStartInput(sessionID: "zzz"), env: [:], store: store) == nil)
        #expect(sessionStartHookOutput(SessionStartInput(sessionID: nil), env: [:], store: store) == nil)
    }

    @Test func linksASessionStartedForATaskViaTheEnvironmentIncludingAfterClear() throws {
        let store = makeStore()
        try store.create(NewTask(title: "Board"))
        let env = ["SHEPHERD_TASK_ID": "1"]
        #expect(sessionStartHookOutput(SessionStartInput(sessionID: "first"), env: env, store: store) != nil)
        #expect(sessionStartHookOutput(SessionStartInput(sessionID: "after-clear", source: "clear"), env: env, store: store) != nil)
        #expect(store.get(1)?.sessions == ["first", "after-clear"])
    }

    @Test func ignoresATaskIdThatDoesNotExist() {
        #expect(sessionStartHookOutput(SessionStartInput(sessionID: "s"), env: ["SHEPHERD_TASK_ID": "99"], store: makeStore()) == nil)
    }
}

@Suite("Task context for the agent")
struct TaskContextCrookTests {
    @Test func theContextNamesTheCrookPathItWasGiven() throws {
        let store = TaskStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("crook-ctx-\(UUID().uuidString)"))
        try store.create(NewTask(title: "T"))
        try store.update(1) { $0.linkSession("s1") }
        let plain = sessionStartHookOutput(SessionStartInput(sessionID: "s1"), env: [:], store: store) ?? ""
        #expect(plain.contains("`crook task plan"))
        let withPath = sessionStartHookOutput(SessionStartInput(sessionID: "s1"), env: ["SHEPHERD_CROOK": "/Users/a b/.shepherd/bin/crook"], store: store) ?? ""
        #expect(withPath.contains("'/Users/a b/.shepherd/bin/crook' task plan"))
    }
}
