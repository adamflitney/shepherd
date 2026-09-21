import Testing
@testable import ShepherdCore
@testable import ShepherdHerdr

private func agentSession(_ value: String = "abc") -> AgentSessionWire {
    AgentSessionWire(source: "herdr:claude", agent: "claude", kind: "id", value: value)
}

private func pane(id: String = "w4:p1", workspaceID: String = "w4", session: AgentSessionWire? = agentSession()) -> PaneWire {
    PaneWire(
        paneID: id, workspaceID: workspaceID, tabID: "\(workspaceID):t1", agent: "claude",
        agentStatus: "working", agentSession: session, cwd: "/tmp", foregroundCwd: "/tmp",
        title: "x", terminalTitle: "x", terminalTitleStripped: "x", focused: false
    )
}

@Test func projectionExposesTheRouteForAResolvedSession() {
    var projection = SessionProjection()
    _ = projection.applyPaneObservation(pane())

    let route = projection.route(for: SessionID(rawValue: "agent:abc"))

    #expect(route == HerdrRoute(paneID: "w4:p1", workspaceID: "w4"))
}

@Test func projectionMovesTheRouteWhenIdentityMigratesFromProvisionalToStable() {
    var projection = SessionProjection()
    _ = projection.applyPaneObservation(pane(session: nil))
    #expect(projection.route(for: SessionID(rawValue: "pane:w4:p1")) != nil)

    _ = projection.applyPaneObservation(pane(session: agentSession("abc")))

    #expect(projection.route(for: SessionID(rawValue: "pane:w4:p1")) == nil)
    #expect(projection.route(for: SessionID(rawValue: "agent:abc")) == HerdrRoute(paneID: "w4:p1", workspaceID: "w4"))
}

@Test func projectionRouteFromSnapshotIsAvailableImmediately() {
    var projection = SessionProjection()
    let snapshot = SessionSnapshotWire(
        workspaces: [
            WorkspaceWire(workspaceID: "w4", number: 1, label: "x", focused: true, paneCount: 1, tabCount: 1, activeTabID: "w4:t1", agentStatus: "idle"),
        ],
        panes: [pane()],
        focusedPaneID: nil
    )

    _ = projection.applySnapshot(snapshot)

    #expect(projection.route(for: SessionID(rawValue: "agent:abc")) == HerdrRoute(paneID: "w4:p1", workspaceID: "w4"))
}
