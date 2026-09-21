import Testing
@testable import ShepherdCore
@testable import ShepherdHerdr

private func agentSession(kind: String, value: String) -> AgentSessionWire {
    AgentSessionWire(source: "herdr:claude", agent: "claude", kind: kind, value: value)
}

@Test func identityResolverGivesAProvisionalIDBeforeAnAgentSessionIsKnown() {
    var resolver = IdentityResolver()
    let resolution = resolver.resolve(paneID: "w4:p1", agentSession: nil)
    #expect(resolution.id == SessionID(rawValue: "pane:w4:p1"))
    #expect(resolution.previousProvisionalID == nil)
}

@Test func identityResolverUsesTheAgentSessionUUIDOnceKnown() {
    var resolver = IdentityResolver()
    let session = agentSession(kind: "id", value: "5e2aeedc-ecd4-493c-9894-375709517f73")
    let resolution = resolver.resolve(paneID: "w4:p1", agentSession: session)
    #expect(resolution.id == SessionID(rawValue: "agent:5e2aeedc-ecd4-493c-9894-375709517f73"))
}

@Test func identityResolverReportsTheMigrationFromProvisionalToStable() {
    var resolver = IdentityResolver()
    _ = resolver.resolve(paneID: "w4:p1", agentSession: nil) // pane exists before its agent registers

    let session = agentSession(kind: "id", value: "5e2aeedc-ecd4-493c-9894-375709517f73")
    let resolution = resolver.resolve(paneID: "w4:p1", agentSession: session)

    #expect(resolution.id == SessionID(rawValue: "agent:5e2aeedc-ecd4-493c-9894-375709517f73"))
    #expect(resolution.previousProvisionalID == SessionID(rawValue: "pane:w4:p1"))
}

@Test func identityResolverNeverReportsAMigrationOnSubsequentFrames() {
    var resolver = IdentityResolver()
    let session = agentSession(kind: "id", value: "abc")
    _ = resolver.resolve(paneID: "w4:p1", agentSession: session)

    let second = resolver.resolve(paneID: "w4:p1", agentSession: session)

    #expect(second.previousProvisionalID == nil)
}

@Test func identityResolverKeepsReportingTheStableIDEvenIfAgentSessionGoesMissingAgain() {
    // A pane that's gone stable once must never re-provisionalize, even if a
    // later frame happens to omit agent_session.
    var resolver = IdentityResolver()
    let session = agentSession(kind: "id", value: "abc")
    _ = resolver.resolve(paneID: "w4:p1", agentSession: session)

    let resolution = resolver.resolve(paneID: "w4:p1", agentSession: nil)

    #expect(resolution.id == SessionID(rawValue: "agent:abc"))
    #expect(resolution.previousProvisionalID == nil)
}

@Test func identityResolverTracksDifferentPanesIndependently() {
    var resolver = IdentityResolver()
    let a = resolver.resolve(paneID: "w4:p1", agentSession: nil)
    let b = resolver.resolve(paneID: "w4:p2", agentSession: nil)
    #expect(a.id != b.id)
}

@Test func identityResolverExtractsUUIDFromAPathKindAgentSession() {
    var resolver = IdentityResolver()
    let session = agentSession(
        kind: "path",
        value: "/Users/devuser/.claude/projects/shepherd/5e2aeedc-ecd4-493c-9894-375709517f73.jsonl"
    )
    let resolution = resolver.resolve(paneID: "w4:p1", agentSession: session)
    #expect(resolution.id == SessionID(rawValue: "agent:5e2aeedc-ecd4-493c-9894-375709517f73"))
}

@Test func identityResolverHashesAPathKindAgentSessionWithNoEmbeddedUUID() {
    var resolver = IdentityResolver()
    let session = agentSession(kind: "path", value: "/some/opaque/path")
    let first = resolver.resolve(paneID: "w4:p1", agentSession: session)
    var otherResolver = IdentityResolver()
    let second = otherResolver.resolve(paneID: "w9:p9", agentSession: session)
    // Deterministic: the same opaque path always yields the same identity,
    // independent of which pane it was observed on.
    #expect(first.id == second.id)
    #expect(first.id.rawValue.hasPrefix("agent:"))
}
