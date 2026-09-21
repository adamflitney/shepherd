import Foundation
import Testing
@testable import ShepherdCore

@Test func createSessionRequestDefaultsToStandalonePlacement() {
    let request = CreateSessionRequest(workingDirectory: URL(fileURLWithPath: "/tmp"), agent: .claude)
    #expect(request.placement == .standalone)
}

@Test func createSessionRequestPlacementCanTargetAnExistingSession() {
    let target = SessionID(rawValue: "agent:1")
    let request = CreateSessionRequest(
        workingDirectory: URL(fileURLWithPath: "/tmp"),
        agent: .claude,
        placement: .alongside(target)
    )
    #expect(request.placement == .alongside(target))
}

@Test func backendErrorCasesAreEquatable() {
    #expect(BackendError.unavailable("no socket") == BackendError.unavailable("no socket"))
    #expect(BackendError.unavailable("a") != BackendError.unavailable("b"))
    #expect(BackendError.unknownSession(SessionID(rawValue: "x")) == .unknownSession(SessionID(rawValue: "x")))
}
