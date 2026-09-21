import Foundation
import Testing
@testable import ShepherdHerdr

private func fixtureLines(_ name: String) -> [Data] {
    let url = Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")!
    let content = try! String(contentsOf: url, encoding: .utf8)
    return content.split(separator: "\n").map { Data($0.utf8) }
}

@Test func classifyRecognisesASuccessResponse() {
    let line = fixtureLines("ping_response")[0]
    #expect(HerdrWire.classify(line) == .success(id: "fixture"))
}

@Test func classifyRecognisesAnErrorResponseWithEmptyID() {
    let line = fixtureLines("error_response")[0]
    guard case .error(let id, let body) = HerdrWire.classify(line) else {
        Issue.record("expected an error frame")
        return
    }
    #expect(id == "")
    #expect(body.code == "invalid_request")
    #expect(body.message.contains("unknown variant"))
}

@Test func classifyRecognisesTheSubscriptionAck() {
    let ack = fixtureLines("subscribe_ack_and_pane_updated_burst")[0]
    #expect(HerdrWire.classify(ack) == .success(id: "sub"))
}

@Test func classifyRecognisesAPaneUpdatedEventWithNoIDField() {
    let eventLine = fixtureLines("subscribe_ack_and_pane_updated_burst")[1]
    #expect(HerdrWire.classify(eventLine) == .event(type: "pane_updated"))
}

@Test func decodeEventDataDecodesAPaneUpdatedPayload() throws {
    let eventLine = fixtureLines("subscribe_ack_and_pane_updated_burst")[1]
    let payload = try HerdrWire.decodeEventData(PaneUpdatedEventDataWire.self, from: eventLine)
    #expect(payload.type == "pane_updated")
    #expect(payload.pane.agent == "claude")
    #expect(payload.pane.agentStatus == "working")
    #expect(!payload.pane.paneID.isEmpty)
}

@Test func decodeResultDecodesTheFullSessionSnapshot() throws {
    let line = fixtureLines("session_snapshot")[0]
    let result = try HerdrWire.decodeResult(SessionSnapshotResultWire.self, from: line)
    #expect(result.type == "session_snapshot")
    #expect(!result.snapshot.workspaces.isEmpty)
    #expect(!result.snapshot.panes.isEmpty)
}

@Test func sessionSnapshotDistinguishesAgentPanesFromShellPanes() throws {
    let line = fixtureLines("session_snapshot")[0]
    let result = try HerdrWire.decodeResult(SessionSnapshotResultWire.self, from: line)
    let agentPanes = result.snapshot.panes.filter { $0.agent != nil }
    let shellPanes = result.snapshot.panes.filter { $0.agent == nil }
    #expect(!agentPanes.isEmpty)
    #expect(!shellPanes.isEmpty)
}
