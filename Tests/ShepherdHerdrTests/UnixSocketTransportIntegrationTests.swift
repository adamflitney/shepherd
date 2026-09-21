import Foundation
import Testing
@testable import ShepherdCore
@testable import ShepherdHerdr

/// The one type this suite can't unit test - it talks to a real socket.
/// Skips cleanly when Herdr isn't running, so CI (and any dev machine
/// without Herdr installed) stays green; runs for real whenever it is.
private var herdrSocketExists: Bool {
    let path = (NSString(string: "~/.config/herdr/herdr.sock").expandingTildeInPath)
    return FileManager.default.fileExists(atPath: path)
}

private struct PongResultWire: Decodable { let type: String }

@Test(.enabled(if: herdrSocketExists))
func unixSocketTransportPingsARealHerdrServer() async throws {
    let client = RequestClient(transport: UnixSocketTransport())
    let result = try await client.call(method: "ping", params: EmptyParams(), resultType: PongResultWire.self)
    #expect(result.type == "pong")
}

@Test(.enabled(if: herdrSocketExists))
func unixSocketTransportFetchesARealSnapshot() async throws {
    let client = RequestClient(transport: UnixSocketTransport())
    let result = try await client.call(
        method: "session.snapshot", params: EmptyParams(), resultType: SessionSnapshotResultWire.self
    )
    #expect(result.type == "session_snapshot")
}

@Test(.enabled(if: herdrSocketExists))
func unixSocketTransportSubscribesAndReceivesTheAck() async throws {
    let transport = UnixSocketTransport()
    let line = try HerdrWire.encodeRequest(
        id: "sub", method: "events.subscribe",
        params: ["subscriptions": [["type": "workspace.focused"]]] as [String: [[String: String]]]
    )
    var iterator = transport.subscribe(line).makeAsyncIterator()
    let ack = await iterator.next()
    #expect(ack != nil)
    if let ack {
        #expect(HerdrWire.classify(ack) == .success(id: "sub"))
    }
}
