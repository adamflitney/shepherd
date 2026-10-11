import Foundation
import ShepherdCore

/// Reconciles Herdr's realtime `agent_status` with the hook file's own
/// refinement - direct Swift port of the legacy prototype's
/// `reconcileState`. Herdr owns `working`/`done`/`unknown` outright; the
/// hook file only ever refines `blocked` (into a `Blocker`) and `idle`
/// (into idle-with-progress, when the hook state is `"stalled"`).
public func reconcileAttention(herdrKind: AttentionState.Kind, hookState: ParsedHookState?) -> AttentionState {
    switch herdrKind {
    case .blocked:
        switch hookState?.state {
        case "needs-permission":
            // The hook writes a one-line "ToolName: what" summary when it
            // can (see `summarize_permission_request` in the Python hook) -
            // falling back to the bare tool name only if it couldn't.
            return AttentionState(kind: .blocked, blocker: .needsPermission, summary: hookState?.summary ?? hookState?.toolName)
        case "asked-a-question":
            // A structured `AskUserQuestion` has its own literal question
            // text and labeled options; a plain-text question or
            // `ExitPlanMode` has neither, so `summary` falls back to the
            // tool name as before.
            return AttentionState(
                kind: .blocked,
                blocker: .needsAnswer,
                summary: hookState?.question ?? hookState?.toolName,
                options: hookState?.options,
                optionsAllowMultiple: hookState?.multiSelect ?? false
            )
        default:
            return AttentionState(kind: .blocked)
        }
    case .idle:
        guard hookState?.state == "stalled" else { return AttentionState(kind: .idle) }
        let progress = hookState?.todos.map { TaskProgress(completed: $0.completed, total: $0.total, currentItem: $0.activeForm) }
        return AttentionState(kind: .idle, progress: progress ?? nil)
    case .working, .done, .unknown:
        return AttentionState(kind: herdrKind)
    }
}
