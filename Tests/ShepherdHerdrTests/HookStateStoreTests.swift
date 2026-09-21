import Foundation
import Testing
@testable import ShepherdHerdr

private func withTempStateDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shepherd-hookstate-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

private func write(_ content: String, to dir: URL, filename: String) {
    try! content.write(to: dir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
}

@Test func hookStateStoreReadsOneSessionsStateByUUID() {
    withTempStateDir { dir in
        write(
            #"{"schema":1,"session_id":"abc","updated_at":"2026-09-17T14:11:41Z","state":"idle","detail":{}}"#,
            to: dir, filename: "abc.json"
        )
        let store = HookStateStore(directory: dir, now: { ISO8601DateFormatter().date(from: "2026-09-17T14:11:41Z")!.addingTimeInterval(1) })

        #expect(store.state(forSessionUUID: "abc")?.state == "idle")
        #expect(store.state(forSessionUUID: "missing") == nil)
    }
}

@Test func hookStateStoreReadsAllStatesKeyedByUUID() {
    withTempStateDir { dir in
        let now = ISO8601DateFormatter().date(from: "2026-09-17T14:11:41Z")!.addingTimeInterval(1)
        write(#"{"schema":1,"session_id":"abc","updated_at":"2026-09-17T14:11:41Z","state":"idle","detail":{}}"#, to: dir, filename: "abc.json")
        write(#"{"schema":1,"session_id":"def","updated_at":"2026-09-17T14:11:41Z","state":"stalled","detail":{}}"#, to: dir, filename: "def.json")
        write("not json at all", to: dir, filename: "corrupt.json")
        let store = HookStateStore(directory: dir, now: { now })

        let states = store.allStates()

        #expect(states.count == 2)
        #expect(states["abc"]?.state == "idle")
        #expect(states["def"]?.state == "stalled")
    }
}

@Test func hookStateStoreDegradesToEmptyWhenTheDirectoryDoesNotExist() {
    let store = HookStateStore(directory: URL(fileURLWithPath: "/no/such/directory-\(UUID().uuidString)"), now: Date.init)
    #expect(store.allStates().isEmpty)
    #expect(store.state(forSessionUUID: "anything") == nil)
}
