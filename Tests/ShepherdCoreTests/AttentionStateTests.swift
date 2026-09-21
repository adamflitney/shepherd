import Testing
@testable import ShepherdCore

@Test func attentionKindDeclarationOrderIsDisplayPriority() {
    // blocked is the most urgent state, unknown the least - Comparable follows
    // declaration order so the UI can sort on it directly.
    #expect(AttentionState.Kind.blocked < AttentionState.Kind.done)
    #expect(AttentionState.Kind.done < AttentionState.Kind.working)
    #expect(AttentionState.Kind.working < AttentionState.Kind.idle)
    #expect(AttentionState.Kind.idle < AttentionState.Kind.unknown)
}

@Test func attentionStateConvenienceConstructorsSetOnlyKind() {
    let idle = AttentionState.idle()
    #expect(idle.kind == .idle)
    #expect(idle.blocker == nil)
    #expect(idle.progress == nil)

    #expect(AttentionState.unknown.kind == .unknown)
}

@Test func attentionStateBlockerIsIndependentOfKind() {
    // blocker is meaningful only when kind == .blocked, but the type doesn't
    // enforce that - it's progressive-enhancement detail, not a second axis.
    var state = AttentionState(kind: .blocked)
    #expect(state.blocker == nil)

    state.blocker = .needsPermission
    #expect(state.kind == .blocked)
    #expect(state.blocker == .needsPermission)
}

@Test func attentionStateEqualityComparesAllFields() {
    let a = AttentionState(kind: .idle, since: nil)
    let b = AttentionState(kind: .idle, since: nil)
    let c = AttentionState(kind: .idle, progress: TaskProgress(completed: 1, total: 3))

    #expect(a == b)
    #expect(a != c)
}

@Test func taskProgressFractionHandlesZeroTotal() {
    #expect(TaskProgress(completed: 0, total: 0).fraction == 0)
    #expect(TaskProgress(completed: 1, total: 4).fraction == 0.25)
}
