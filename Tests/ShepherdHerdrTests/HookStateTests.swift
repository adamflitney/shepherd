import Foundation
import Testing
@testable import ShepherdCore
@testable import ShepherdHerdr

// MARK: - parseHookStateFile

private func stateJSON(schema: Int = 1, state: String, updatedAt: String, detail: String = "{}") -> Data {
    Data(#"{"schema":\#(schema),"session_id":"s1","updated_at":"\#(updatedAt)","state":"\#(state)","detail":\#(detail)}"#.utf8)
}

@Test func parseHookStateFileDegradesToNilWhenContentIsMissing() {
    #expect(parseHookStateFile(nil, now: Date()) == nil)
}

@Test func parseHookStateFileDegradesToNilOnCorruptJSON() {
    #expect(parseHookStateFile(Data("{ not json".utf8), now: Date()) == nil)
}

@Test func parseHookStateFileDegradesToNilOnUnknownSchemaVersion() {
    let content = stateJSON(schema: 2, state: "idle", updatedAt: "2026-09-17T14:11:41Z")
    #expect(parseHookStateFile(content, now: Date(timeIntervalSince1970: 1_789_000_000)) == nil)
}

@Test func parseHookStateFileDegradesToNilWhenTooStale() {
    let updated = ISO8601DateFormatter().date(from: "2026-09-17T14:11:41Z")!
    let content = stateJSON(schema: 1, state: "idle", updatedAt: "2026-09-17T14:11:41Z")
    let now = updated.addingTimeInterval(16 * 60)
    #expect(parseHookStateFile(content, now: now, staleAfter: 15 * 60) == nil)
}

@Test func parseHookStateFileAcceptsAFreshFile() {
    let updated = ISO8601DateFormatter().date(from: "2026-09-17T14:11:41Z")!
    let content = stateJSON(
        schema: 1, state: "asked-a-question", updatedAt: "2026-09-17T14:11:41Z",
        detail: #"{"tool_name":"ExitPlanMode"}"#
    )
    let now = updated.addingTimeInterval(60)
    let parsed = parseHookStateFile(content, now: now, staleAfter: 15 * 60)
    #expect(parsed?.state == "asked-a-question")
    #expect(parsed?.toolName == "ExitPlanMode")
}

@Test func parseHookStateFileReadsTodoProgress() {
    let content = stateJSON(
        schema: 1, state: "stalled", updatedAt: "2026-09-17T14:11:41Z",
        detail: #"{"todos":{"done":2,"total":5,"activeForm":"Writing tests"}}"#
    )
    let now = ISO8601DateFormatter().date(from: "2026-09-17T14:11:41Z")!.addingTimeInterval(1)
    let parsed = parseHookStateFile(content, now: now, staleAfter: 15 * 60)
    #expect(parsed?.todos == ParsedHookTodos(completed: 2, total: 5, activeForm: "Writing tests"))
}

// MARK: - reconcileAttention (ported from shepherd-legacy/src/herdr.test.ts's reconcileState suite)

@Test func reconcileAttentionRefinesBlockedIntoNeedsPermission() {
    let result = reconcileAttention(herdrKind: .blocked, hookState: ParsedHookState(state: "needs-permission", toolName: nil, todos: nil))
    #expect(result.kind == .blocked)
    #expect(result.blocker == .needsPermission)
}

@Test func reconcileAttentionRefinesBlockedIntoNeedsAnswer() {
    let result = reconcileAttention(herdrKind: .blocked, hookState: ParsedHookState(state: "asked-a-question", toolName: nil, todos: nil))
    #expect(result.kind == .blocked)
    #expect(result.blocker == .needsAnswer)
}

@Test func reconcileAttentionFallsBackToPlainBlockedWithNoRefinement() {
    #expect(reconcileAttention(herdrKind: .blocked, hookState: nil).blocker == nil)
    #expect(reconcileAttention(herdrKind: .blocked, hookState: ParsedHookState(state: "idle", toolName: nil, todos: nil)).blocker == nil)
}

@Test func reconcileAttentionRefinesIdleIntoProgressWhenStalled() {
    let todos = ParsedHookTodos(completed: 2, total: 5, activeForm: "Writing tests")
    let result = reconcileAttention(herdrKind: .idle, hookState: ParsedHookState(state: "stalled", toolName: nil, todos: todos))
    #expect(result.kind == .idle)
    #expect(result.progress == TaskProgress(completed: 2, total: 5, currentItem: "Writing tests"))
}

@Test func reconcileAttentionTrustsHerdrWorkingOverAStaleHookFile() {
    // The two disagree: the hook file thinks the last turn stalled/was
    // blocked, but Herdr - realtime - says a new turn is already underway.
    #expect(reconcileAttention(herdrKind: .working, hookState: ParsedHookState(state: "stalled", toolName: nil, todos: nil)).kind == .working)
    #expect(reconcileAttention(herdrKind: .working, hookState: ParsedHookState(state: "needs-permission", toolName: nil, todos: nil)).kind == .working)
}

@Test func reconcileAttentionPassesThroughWorkingDoneUnknownUntouched() {
    #expect(reconcileAttention(herdrKind: .working, hookState: nil) == AttentionState(kind: .working))
    #expect(reconcileAttention(herdrKind: .done, hookState: nil) == AttentionState(kind: .done))
    #expect(reconcileAttention(herdrKind: .unknown, hookState: nil) == AttentionState(kind: .unknown))
}

@Test func reconcileAttentionSurfacesToolNameAsSummaryOnlyWhenBlocked() {
    let result = reconcileAttention(herdrKind: .blocked, hookState: ParsedHookState(state: "needs-permission", toolName: "Edit", todos: nil))
    #expect(result.summary == "Edit")
}
