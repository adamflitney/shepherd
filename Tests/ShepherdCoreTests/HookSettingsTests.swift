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
