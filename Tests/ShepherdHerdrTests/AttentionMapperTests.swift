import Testing
@testable import ShepherdCore
@testable import ShepherdHerdr

@Test func attentionMapperMapsAllFiveKnownHerdrStatuses() {
    #expect(mapHerdrAgentStatus("blocked") == .blocked)
    #expect(mapHerdrAgentStatus("done") == .done)
    #expect(mapHerdrAgentStatus("working") == .working)
    #expect(mapHerdrAgentStatus("idle") == .idle)
    #expect(mapHerdrAgentStatus("unknown") == .unknown)
}

@Test func attentionMapperDegradesUnrecognisedStatusToUnknownRatherThanThrowing() {
    // A future Herdr release adding a sixth status must not crash the app.
    #expect(mapHerdrAgentStatus("some-future-status") == .unknown)
    #expect(mapHerdrAgentStatus("") == .unknown)
}
