import Foundation
import Testing
@testable import ShepherdCore
@testable import ShepherdHerdr

private func agentSession(_ value: String = "abc") -> AgentSessionWire {
    AgentSessionWire(source: "herdr:claude", agent: "claude", kind: "id", value: value)
}

private func pane(
    id: String = "w4:p1",
    workspaceID: String = "w4",
    agent: String? = "claude",
    status: String = "working",
    title: String? = "hello",
    session: AgentSessionWire? = agentSession(),
    focused: Bool = false
) -> PaneWire {
    PaneWire(
        paneID: id,
        workspaceID: workspaceID,
        tabID: "\(workspaceID):t1",
        agent: agent,
        agentStatus: status,
        agentSession: session,
        cwd: "/tmp/project",
        foregroundCwd: "/tmp/project",
        title: title,
        terminalTitle: title,
        terminalTitleStripped: title,
        focused: focused
    )
}

@Test func projectionIgnoresPanesWithNoAgent() {
    var projection = SessionProjection()
    let events = projection.applyPaneObservation(pane(agent: nil, session: nil))
    #expect(events.isEmpty)
}

@Test func projectionEmitsExactlyOneChangeForManyIdenticalObservations() {
    var projection = SessionProjection()
    var totalEvents = 0
    for _ in 0..<200 {
        totalEvents += projection.applyPaneObservation(pane()).count
    }
    #expect(totalEvents == 1)
}

@Test func projectionEmitsAgainWhenOnlyTheTitleChanges() {
    var projection = SessionProjection()
    _ = projection.applyPaneObservation(pane(title: "first"))

    let events = projection.applyPaneObservation(pane(title: "second"))

    #expect(events.count == 1)
    guard case .sessionChanged(let session) = events[0] else {
        Issue.record("expected sessionChanged")
        return
    }
    #expect(session.title == "second")
}

@Test func projectionEmitsRemovalAndChangeOnIdentityMigration() {
    var projection = SessionProjection()
    // A pane exists (and has an agent CLI attached) before its agent_session
    // is known, so it starts out provisional.
    _ = projection.applyPaneObservation(pane(session: nil))

    let events = projection.applyPaneObservation(pane(session: agentSession("abc")))

    #expect(events.count == 2)
    #expect(events[0] == .sessionRemoved(SessionID(rawValue: "pane:w4:p1")))
    guard case .sessionChanged(let session) = events[1] else {
        Issue.record("expected sessionChanged as the second event")
        return
    }
    #expect(session.id == SessionID(rawValue: "agent:abc"))
}

@Test func projectionEmitsRemovalWhenAPaneCloses() {
    var projection = SessionProjection()
    _ = projection.applyPaneObservation(pane())

    let events = projection.applyPaneClosed(paneID: "w4:p1")

    #expect(events == [.sessionRemoved(SessionID(rawValue: "agent:abc"))])
}

@Test func projectionClosingAnUnknownPaneEmitsNothing() {
    var projection = SessionProjection()
    #expect(projection.applyPaneClosed(paneID: "never-seen").isEmpty)
}

@Test func projectionSnapshotBuildsSessionsAndGroupsExcludingShellPanes() {
    var projection = SessionProjection()
    let snapshot = SessionSnapshotWire(
        workspaces: [
            WorkspaceWire(
                workspaceID: "w4", number: 1, label: "yolo-club-api", focused: true,
                paneCount: 2, tabCount: 2, activeTabID: "w4:t1", agentStatus: "idle"
            ),
        ],
        panes: [
            pane(id: "w4:p1", agent: "claude"),
            pane(id: "w4:p2", agent: nil, session: nil),
        ],
        focusedPaneID: "w4:p1"
    )

    let result = projection.applySnapshot(snapshot)

    #expect(result.sessions.map(\.id) == [SessionID(rawValue: "agent:abc")])
    #expect(result.groups.map(\.label) == ["yolo-club-api"])
    #expect(result.sessions.first?.group?.id == "w4")
}
