import Testing
@testable import ShepherdCore
@testable import ShepherdHerdr

private func agentSession(_ value: String = "abc") -> AgentSessionWire {
    AgentSessionWire(source: "herdr:claude", agent: "claude", kind: "id", value: value)
}

private func pane(status: String = "blocked", session: AgentSessionWire? = agentSession()) -> PaneWire {
    PaneWire(
        paneID: "w4:p1", workspaceID: "w4", tabID: "w4:t1", agent: "claude",
        agentStatus: status, agentSession: session, cwd: "/tmp", foregroundCwd: "/tmp",
        title: "x", terminalTitle: "x", terminalTitleStripped: "x", focused: false
    )
}

@Test func applyPaneObservationDefaultsToPlainHerdrStatusWithNoHookState() {
    var projection = SessionProjection()
    let events = projection.applyPaneObservation(pane())
    guard case .sessionChanged(let session) = events.first else {
        Issue.record("expected sessionChanged")
        return
    }
    #expect(session.attention.kind == .blocked)
    #expect(session.attention.blocker == nil)
}

@Test func applyPaneObservationReconcilesWithSuppliedHookState() {
    var projection = SessionProjection()
    let hookState = ParsedHookState(state: "needs-permission", toolName: "Edit", todos: nil)

    let events = projection.applyPaneObservation(pane(), hookState: hookState)

    guard case .sessionChanged(let session) = events.first else {
        Issue.record("expected sessionChanged")
        return
    }
    #expect(session.attention.blocker == .needsPermission)
    #expect(session.attention.summary == "Edit")
}

@Test func applySnapshotLooksUpHookStatesByAgentSessionUUID() {
    var projection = SessionProjection()
    let snapshot = SessionSnapshotWire(
        workspaces: [
            WorkspaceWire(workspaceID: "w4", number: 1, label: "x", focused: true, paneCount: 1, tabCount: 1, activeTabID: "w4:t1", agentStatus: "blocked"),
        ],
        panes: [pane(status: "blocked", session: agentSession("abc"))],
        focusedPaneID: nil
    )

    let result = projection.applySnapshot(snapshot, hookStates: [
        "abc": ParsedHookState(state: "asked-a-question", toolName: nil, todos: nil),
        "unrelated-uuid": ParsedHookState(state: "needs-permission", toolName: nil, todos: nil),
    ])

    #expect(result.sessions.first?.attention.blocker == .needsAnswer)
}
