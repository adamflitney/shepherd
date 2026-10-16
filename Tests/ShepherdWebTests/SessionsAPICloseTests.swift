import Foundation
import ShepherdCore
import Testing
@testable import ShepherdWebKit

private func request(_ method: String, _ path: String) -> HTTPServer.Request {
    HTTPServer.Request(method: method, path: path, query: [:], headers: [:], body: Data())
}

@Test func closingASessionOverTheAPIEndsItAndAnUnknownOneIsRefused() async throws {
    let id = SessionID(rawValue: "abc")
    let session = Session(id: id, title: "T", agent: .claude, attention: .idle(), capabilities: [.close])
    let backend = FakeSessionBackend(sessions: [session])
    let api = SessionsAPI(backend: backend)

    let closed = await api.handle(request("POST", "/api/sessions/abc/close"))
    #expect(closed.status == 200)
    #expect(try await backend.snapshot().sessions.isEmpty)

    let again = await api.handle(request("POST", "/api/sessions/abc/close"))
    #expect(again.status == 502)
}
