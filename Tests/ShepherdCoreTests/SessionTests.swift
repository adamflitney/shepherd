import Foundation
import Testing
@testable import ShepherdCore

@Test func sessionIDRoundTripsRawValue() {
    let id = SessionID(rawValue: "agent:5e2aeedc-ecd4-493c-9894-375709517f73")
    #expect(id.rawValue == "agent:5e2aeedc-ecd4-493c-9894-375709517f73")
    #expect(id.description == id.rawValue)
}

@Test func sessionIDEqualityIsByRawValue() {
    #expect(SessionID(rawValue: "a") == SessionID(rawValue: "a"))
    #expect(SessionID(rawValue: "a") != SessionID(rawValue: "b"))
}

@Test func agentKindHasKnownConstantsButAcceptsAnyRawValue() {
    // Herdr's `agent` field is an open string set - unrecognised agents must
    // still round-trip rather than being rejected.
    #expect(AgentKind.claude.rawValue == "claude")
    #expect(AgentKind(rawValue: "some-future-agent").rawValue == "some-future-agent")
}

@Test func sessionCapabilitiesComposeAsOptionSet() {
    let caps: SessionCapabilities = [.focus, .close]
    #expect(caps.contains(.focus))
    #expect(caps.contains(.close))
    #expect(!caps.contains(.prompt))
}

@Test func sessionIsIdentifiableByItsSessionID() {
    let session = Session(
        id: SessionID(rawValue: "agent:1"),
        title: "yolo-club-api",
        agent: .claude,
        workingDirectory: URL(fileURLWithPath: "/Users/devuser/Dev/yolo-club-api"),
        attention: .idle(),
        isFocused: true,
        capabilities: [.focus]
    )
    #expect(session.id.rawValue == "agent:1")
    #expect(session.id == session.id)
}
