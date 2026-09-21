import Foundation
import Testing
@testable import ShepherdCore
@testable import ShepherdHerdr

private struct EmptyParams: Encodable {}
private struct PongResult: Decodable, Equatable { let type: String }

@Test func requestClientDecodesASuccessfulResponse() async throws {
    let transport = InMemoryLineTransport(responses: [
        Data(#"{"id":"req1","result":{"type":"pong"}}"#.utf8),
    ])
    let client = RequestClient(transport: transport)

    let result = try await client.call(method: "ping", params: EmptyParams(), resultType: PongResult.self)

    #expect(result == PongResult(type: "pong"))
}

@Test func requestClientThrowsRemoteErrorForAnErrorEnvelope() async {
    let transport = InMemoryLineTransport(responses: [
        Data(#"{"id":"","error":{"code":"invalid_request","message":"bad method"}}"#.utf8),
    ])
    let client = RequestClient(transport: transport)

    await #expect(throws: BackendError.remote(code: "invalid_request", message: "bad method")) {
        try await client.call(method: "not.a.method", params: EmptyParams(), resultType: PongResult.self)
    }
}

@Test func requestClientThrowsProtocolViolationWhenAnEventArrivesInsteadOfAResponse() async {
    let transport = InMemoryLineTransport(responses: [
        Data(#"{"event":"pane_updated","data":{}}"#.utf8),
    ])
    let client = RequestClient(transport: transport)

    await #expect(throws: BackendError.self) {
        try await client.call(method: "ping", params: EmptyParams(), resultType: PongResult.self)
    }
}

@Test func requestClientWrapsTransportFailureAsUnavailable() async {
    let transport = InMemoryLineTransport(responses: [])
    let client = RequestClient(transport: transport)

    await #expect(throws: BackendError.self) {
        try await client.call(method: "ping", params: EmptyParams(), resultType: PongResult.self)
    }
}

@Test func requestClientSendsAWellFormedRequestLine() async throws {
    let transport = InMemoryLineTransport(responses: [
        Data(#"{"id":"req1","result":{"type":"pong"}}"#.utf8),
    ])
    let client = RequestClient(transport: transport)

    _ = try await client.call(method: "ping", params: EmptyParams(), resultType: PongResult.self)

    struct RequestShape: Decodable { let method: String; let params: [String: String] }

    let sent = await transport.sentLines
    #expect(sent.count == 1)
    #expect(sent[0].last == 0x0A)
    let decoded = try JSONDecoder().decode(RequestShape.self, from: sent[0])
    #expect(decoded.method == "ping")
}
