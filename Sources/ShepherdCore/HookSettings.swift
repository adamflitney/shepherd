import Foundation

/// Any hook command referencing one of these scripts is Shepherd's own.
/// Matching on script filename rather than hook event name keeps both
/// functions robust to which events Shepherd happens to register, and
/// leaves every other tool's hooks in `~/.claude/settings.json` untouched -
/// direct port of shepherd-legacy's `SHEPHERD_HOOK_MARKERS` approach.
public let shepherdHookMarkers = ["shepherd-log-event.sh", "shepherd-write-state.sh"]

private func isShepherdCommand(_ hook: JSONValue) -> Bool {
    guard case .object(let fields) = hook, case .string(let command)? = fields["command"] else { return false }
    return shepherdHookMarkers.contains { command.contains($0) } || isCrookSessionStartCommand(command)
}

/// The task-context hook: `'<path>/crook' hook session-start`.
private func isCrookSessionStartCommand(_ command: String) -> Bool {
    command.contains("crook") && command.contains("hook session-start")
}

/// Removes every hook entry that references a Shepherd script, dropping an
/// event's array once it's empty and the whole `hooks` key once nothing is
/// left under it. Direct port of shepherd-legacy's `stripShepherdHooks`.
public func stripShepherdHooks(_ settings: JSONValue) -> JSONValue {
    guard case .object(var root) = settings else { return settings }
    guard case .object(let hooksByEvent)? = root["hooks"] else { return settings }

    var nextHooksByEvent: [String: JSONValue] = [:]
    for (event, entries) in hooksByEvent {
        guard case .array(let entryList) = entries else {
            nextHooksByEvent[event] = entries
            continue
        }

        var nextEntries: [JSONValue] = []
        for entry in entryList {
            guard case .object(var entryFields) = entry, case .array(let hookList)? = entryFields["hooks"] else {
                nextEntries.append(entry)
                continue
            }
            let remaining = hookList.filter { !isShepherdCommand($0) }
            guard !remaining.isEmpty else { continue }
            entryFields["hooks"] = .array(remaining)
            nextEntries.append(.object(entryFields))
        }

        if !nextEntries.isEmpty {
            nextHooksByEvent[event] = .array(nextEntries)
        }
    }

    if nextHooksByEvent.isEmpty {
        root.removeValue(forKey: "hooks")
    } else {
        root["hooks"] = .object(nextHooksByEvent)
    }
    return .object(root)
}

/// One hook-event registration Shepherd installs. Mirrors the exact real
/// configuration already running via shepherd-legacy - `matcher` is nil for
/// events that don't carry one, and `SessionEnd` only wires up the state
/// writer (not the event-logger), matching what's actually registered.
struct ShepherdHookSpec {
    let event: String
    let matcher: String?
    let scripts: [String]
}

private let shepherdHookSpecs: [ShepherdHookSpec] = [
    ShepherdHookSpec(event: "Notification", matcher: "", scripts: shepherdHookMarkers),
    ShepherdHookSpec(event: "PermissionRequest", matcher: "", scripts: shepherdHookMarkers),
    ShepherdHookSpec(event: "Stop", matcher: nil, scripts: shepherdHookMarkers),
    ShepherdHookSpec(event: "UserPromptSubmit", matcher: nil, scripts: shepherdHookMarkers),
    ShepherdHookSpec(event: "PostToolUse", matcher: "TodoWrite", scripts: shepherdHookMarkers),
    ShepherdHookSpec(event: "SessionEnd", matcher: nil, scripts: ["shepherd-write-state.sh"]),
]

/// Adds Shepherd's own hook registrations, idempotently (strips any existing
/// ones first, so calling this twice never duplicates entries) and without
/// disturbing any other tool's entries already present for the same event.
public func insertShepherdHooks(_ settings: JSONValue, hooksDirectory: String, crookPath: String? = nil) -> JSONValue {
    guard case .object(var root) = stripShepherdHooks(settings) else { return settings }

    var hooksByEvent: [String: JSONValue]
    if case .object(let existing)? = root["hooks"] {
        hooksByEvent = existing
    } else {
        hooksByEvent = [:]
    }

    for spec in shepherdHookSpecs {
        var entryFields: [String: JSONValue] = [:]
        if let matcher = spec.matcher {
            entryFields["matcher"] = .string(matcher)
        }
        entryFields["hooks"] = .array(spec.scripts.map { script in
            .object(["type": .string("command"), "command": .string("bash '\(hooksDirectory)/\(script)'")])
        })
        let newEntry = JSONValue.object(entryFields)

        if case .array(var entries)? = hooksByEvent[spec.event] {
            entries.append(newEntry)
            hooksByEvent[spec.event] = .array(entries)
        } else {
            hooksByEvent[spec.event] = .array([newEntry])
        }
    }

    // Injects the linked task's plan and log into a session as it starts (see `crook hook session-start`).
    if let crookPath {
        let entry = JSONValue.object([
            "matcher": .string("startup|resume|clear|compact"),
            "hooks": .array([.object(["type": .string("command"), "command": .string("'\(crookPath)' hook session-start")])]),
        ])
        if case .array(var entries)? = hooksByEvent["SessionStart"] {
            entries.append(entry)
            hooksByEvent["SessionStart"] = .array(entries)
        } else {
            hooksByEvent["SessionStart"] = .array([entry])
        }
    }

    root["hooks"] = .object(hooksByEvent)
    return .object(root)
}
