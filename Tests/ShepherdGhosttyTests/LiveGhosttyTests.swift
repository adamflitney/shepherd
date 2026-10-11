import Foundation
import Testing
@testable import ShepherdGhostty

/// Talks to the real Ghostty. Opt-in (`SHEPHERD_LIVE_GHOSTTY=1`) because it opens windows on screen.
/// It only ever touches terminals it creates itself, and closes them afterwards.
@Suite("Live Ghostty", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_LIVE_GHOSTTY"] != nil))
struct LiveGhosttyTests {
    @Test func theWholeScriptingSurfaceWorksAgainstTheRealApp() async throws {
        let g = OsascriptGhosttyScripting()
        #expect(await g.isRunning())
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("shep-live-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }

        let started = Date()
        let a = try await g.open(
            command: "/bin/bash -c 'printf \"\\033]0;LIVE-TITLE\\007\"; echo \"env=$SHEPHERD_TASK_ID pwd=$PWD\" > \(out.path).env; cat -v > \(out.path)'",
            workingDirectory: "/usr", environment: ["SHEPHERD_TASK_ID": "7"], windowID: nil)
        print("open window: \(Date().timeIntervalSince(started))s  \(a)")

        let t2 = Date()
        let b = try await g.open(command: "/bin/bash -c 'sleep 300'", workingDirectory: "/tmp", environment: [:], windowID: a.windowID)
        print("open tab in same window: \(Date().timeIntervalSince(t2))s  \(b)")
        #expect(b.windowID == a.windowID)
        #expect(b.terminalID != a.terminalID)

        try await Task.sleep(nanoseconds: 800_000_000)
        let t3 = Date()
        let list = try await g.listTerminals()
        print("listTerminals: \(Date().timeIntervalSince(t3))s  (\(list.count) terminals total)")
        let mine = list.first { $0.ref.terminalID == a.terminalID }
        #expect(mine?.name == "LIVE-TITLE")
        #expect(list.contains { $0.ref.terminalID == b.terminalID })

        // a is now a background tab
        try await g.inputText("hello", terminalID: a.terminalID)
        for key in ["arrowDown", "arrowUp", "escape"] { try await g.sendKey(key, modifiers: [], terminalID: a.terminalID) }
        try await g.sendKey("enter", modifiers: [], terminalID: a.terminalID)
        // `cat` buffers what it writes to a file until it exits, so end it before reading
        try await g.sendKey("d", modifiers: ["control"], terminalID: a.terminalID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let got = (try? String(contentsOf: out, encoding: .utf8)) ?? "<none>"
        print("cat -v saw: \(got.debugDescription)")
        let env = (try? String(contentsOf: URL(fileURLWithPath: out.path + ".env"), encoding: .utf8)) ?? "<none>"
        print("env/cwd saw: \(env.debugDescription)")
        #expect(env.contains("env=7"))
        #expect(env.contains("pwd=/usr"))
        #expect(got.contains("hello"))
        #expect(got.contains("^[[B"))  // arrowDown arrived as a real key event
        #expect(got.contains("^[[A"))

        let t4 = Date()
        _ = try await g.frontmostTerminalID()
        let front = try await g.frontWindowID()
        print("frontmost queries: \(Date().timeIntervalSince(t4))s  frontWindow=\(front ?? "nil")")

        try await g.focus(terminalID: a.terminalID)

        // end the processes so closing does not raise Ghostty's "still running" confirmation
        try await g.sendKey("c", modifiers: ["control"], terminalID: b.terminalID)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        try await g.close(terminalID: a.terminalID)
        try await g.close(terminalID: b.terminalID)
        try await Task.sleep(nanoseconds: 800_000_000)
        let after = try await g.listTerminals()
        #expect(!after.contains { $0.ref.terminalID == a.terminalID })
        #expect(!after.contains { $0.ref.terminalID == b.terminalID })
        try? FileManager.default.removeItem(atPath: out.path + ".env")
    }
}
