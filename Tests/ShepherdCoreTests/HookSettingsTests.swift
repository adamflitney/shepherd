import Testing
@testable import ShepherdCore

private func shepherdHook(_ script: String) -> JSONValue {
    .object(["type": .string("command"), "command": .string("bash '/Users/devuser/.claude/hooks/\(script)'")])
}

// MARK: - stripShepherdHooks (ported from shepherd-legacy/src/uninstall.test.ts)

@Test func stripIsANoOpWhenThereIsNoHooksKeyAtAll() {
    let settings = JSONValue.object(["permissions": .object(["allow": .array([.string("Bash(ls:*)")])])])
    #expect(stripShepherdHooks(settings) == settings)
}

@Test func stripLeavesAnotherToolsHooksCompletelyUntouched() {
    let otherToolHook = JSONValue.object([
        "type": .string("command"),
        "command": .string("bash '/Users/devuser/.claude/hooks/herdr-agent-state.sh' session"),
    ])
    let settings = JSONValue.object([
        "hooks": .object([
            "SessionStart": .array([
                .object(["matcher": .string("*"), "hooks": .array([otherToolHook])]),
            ]),
        ]),
    ])
    #expect(stripShepherdHooks(settings) == settings)
}

@Test func stripDropsOnlyTheShepherdHookOutOfAnEventMixedWithAnotherTool() {
    let settings = JSONValue.object([
        "hooks": .object([
            "Stop": .array([
                .object([
                    "hooks": .array([
                        shepherdHook("shepherd-write-state.sh"),
                        .object(["type": .string("command"), "command": .string("some-other-tool-hook.sh")]),
                    ]),
                ]),
            ]),
        ]),
    ])

    let expected = JSONValue.object([
        "hooks": .object([
            "Stop": .array([
                .object(["hooks": .array([.object(["type": .string("command"), "command": .string("some-other-tool-hook.sh")])])]),
            ]),
        ]),
    ])
    #expect(stripShepherdHooks(settings) == expected)
}

@Test func stripDropsTheWholeHooksKeyOnceNothingIsLeftUnderIt() {
    let settings = JSONValue.object([
        "permissions": .object(["allow": .array([])]),
        "hooks": .object([
            "Notification": .array([.object(["matcher": .string(""), "hooks": .array([shepherdHook("shepherd-log-event.sh")])])]),
            "Stop": .array([.object(["hooks": .array([shepherdHook("shepherd-write-state.sh")])])]),
        ]),
    ])
    #expect(stripShepherdHooks(settings) == .object(["permissions": .object(["allow": .array([])])]))
}

@Test func stripRoundTripsARealInstallBackToItsPreInstallBaseline() {
    let baseline = JSONValue.object([
        "permissions": .object(["allow": .array([.string("Bash(wc:*)"), .string("Bash(test:*)"), .string("mcp__obsidian__obsidian_append_content")])]),
    ])

    let installed = insertShepherdHooks(baseline, hooksDirectory: "/Users/devuser/.claude/hooks")

    #expect(stripShepherdHooks(installed) == baseline)
}

// MARK: - insertShepherdHooks

@Test func insertIsIdempotent() {
    let baseline = JSONValue.object([:])
    let once = insertShepherdHooks(baseline, hooksDirectory: "/hooks")
    let twice = insertShepherdHooks(once, hooksDirectory: "/hooks")
    #expect(once == twice)
}

@Test func insertLeavesAnotherToolsEntryInTheSameEventAlone() {
    let settings = JSONValue.object([
        "hooks": .object([
            "Stop": .array([.object(["hooks": .array([.object(["type": .string("command"), "command": .string("other-tool.sh")])])])]),
        ]),
    ])

    let installed = insertShepherdHooks(settings, hooksDirectory: "/hooks")

    guard case .object(let root) = installed,
          case .object(let hooks)? = root["hooks"],
          case .array(let stopEntries)? = hooks["Stop"] else {
        Issue.record("expected Stop entries")
        return
    }
    #expect(stopEntries.count == 2) // the other tool's entry, plus shepherd's own
    #expect(stopEntries.contains(.object(["hooks": .array([.object(["type": .string("command"), "command": .string("other-tool.sh")])])])))
}

@Test func insertThenStripRoundTripsToTheOriginalSettingsExactly() {
    let baseline = JSONValue.object([
        "permissions": .object(["allow": .array([.string("Bash(git:*)")])]),
        "hooks": .object([
            "SessionStart": .array([.object(["hooks": .array([.object(["type": .string("command"), "command": .string("unrelated.sh")])])])]),
        ]),
    ])

    let roundTripped = stripShepherdHooks(insertShepherdHooks(baseline, hooksDirectory: "/hooks"))

    #expect(roundTripped == baseline)
}

// MARK: - the crook SessionStart hook

private let crook = "/Users/devuser/.shepherd/bin/crook"

private func sessionStartCommands(_ settings: JSONValue) -> [String] {
    guard case .object(let root) = settings, case .object(let hooks)? = root["hooks"],
          case .array(let entries)? = hooks["SessionStart"] else { return [] }
    return entries.flatMap { entry -> [String] in
        guard case .object(let f) = entry, case .array(let list)? = f["hooks"] else { return [] }
        return list.compactMap { if case .object(let h) = $0, case .string(let c)? = h["command"] { return c } else { return nil } }
    }
}

@Test func insertRegistersTheTaskContextHookOnSessionStartWhenCrookIsAvailable() {
    let installed = insertShepherdHooks(.object([:]), hooksDirectory: "/h", crookPath: crook)
    #expect(sessionStartCommands(installed) == ["'\(crook)' hook session-start"])
    guard case .object(let root) = installed, case .object(let hooks)? = root["hooks"], case .array(let entries)? = hooks["SessionStart"],
          case .object(let entry)? = entries.first else { Issue.record("no SessionStart entry"); return }
    #expect(entry["matcher"] == .string("startup|resume|clear|compact"))
}

@Test func insertWithoutCrookRegistersNoSessionStartHook() {
    #expect(sessionStartCommands(insertShepherdHooks(.object([:]), hooksDirectory: "/h")).isEmpty)
}

@Test func theCrookHookIsInstalledIdempotentlyAndStrippedAgainWithoutTouchingOtherToolsSessionStartHooks() {
    let other = JSONValue.object(["type": .string("command"), "command": .string("bash '/x/herdr-agent-state.sh' session")])
    let base = JSONValue.object(["hooks": .object(["SessionStart": .array([.object(["hooks": .array([other])])])])])
    let once = insertShepherdHooks(base, hooksDirectory: "/h", crookPath: crook)
    let twice = insertShepherdHooks(once, hooksDirectory: "/h", crookPath: crook)
    #expect(once == twice)
    #expect(sessionStartCommands(once).count == 2)
    #expect(stripShepherdHooks(once) == base)
}

@Test func movingCrookReplacesTheOldPathInsteadOfAddingASecondHook() {
    let first = insertShepherdHooks(.object([:]), hooksDirectory: "/h", crookPath: "/old/crook")
    let moved = insertShepherdHooks(first, hooksDirectory: "/h", crookPath: "/new/crook")
    #expect(sessionStartCommands(moved) == ["'/new/crook' hook session-start"])
}
