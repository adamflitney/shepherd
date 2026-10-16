import Foundation
import ShepherdCore

/// Attention for a session whose only source of state is Claude Code's hooks (Herdr is not there
/// to say working/idle). `unseenFinish` is "it stopped while nobody was looking", which is what
/// makes a finished session `.done` rather than just `.idle`.
public func ghosttyAttention(hook: ParsedHookState?, unseenFinish: Bool) -> AttentionState {
    guard let hook else { return .unknown }
    let progress = hook.todos.flatMap { t in
        t.total > 0 ? TaskProgress(completed: t.completed, total: t.total, currentItem: t.activeForm) : nil
    }
    switch hook.state {
    case "needs-permission":
        return AttentionState(kind: .blocked, blocker: .needsPermission, summary: hook.summary ?? hook.toolName)
    case "asked-a-question":
        return AttentionState(
            kind: .blocked,
            blocker: .needsAnswer,
            summary: hook.question ?? hook.toolName,
            options: hook.options,
            optionsAllowMultiple: hook.multiSelect
        )
    case "working":
        return AttentionState(kind: .working, progress: progress)
    case "stalled":
        return AttentionState(kind: unseenFinish ? .done : .idle, progress: progress)
    default:  // "idle" and anything unrecognised
        return AttentionState(kind: unseenFinish ? .done : .idle)
    }
}

/// How long a session started with a first message may stay silent before it is presumed to be stuck
/// on a startup dialog.
public let ghosttyStartupGrace: TimeInterval = 8

/// A fresh Claude Code session in a directory it has not seen shows a "do you trust this folder"
/// menu, and no hook fires for it. Shown as a blocked session with the menu's real choices, so it can
/// be answered from the panel or the phone (choice 2 is "Yes").
public func folderTrustAttention() -> AttentionState {
    AttentionState(
        kind: .blocked,
        blocker: .needsAnswer,
        summary: "Waiting to start: Claude may be asking to trust this folder",
        options: ["No, exit", "Yes, I trust this folder"]
    )
}
