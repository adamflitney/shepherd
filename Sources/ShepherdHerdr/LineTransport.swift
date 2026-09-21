import Foundation
import ShepherdCore

/// Sends exactly one line and returns exactly one line, over what may be a
/// fresh connection each call - mirrors the verified behaviour of Herdr's
/// socket, which closes the connection after one request/response pair (a
/// second write on the same connection fails with EPIPE).
public protocol OneShotLineTransport: Sendable {
    func send(_ line: Data) async throws -> Data
}

/// Test double: scripted responses played back in call order. Also records
/// every line sent, so tests can assert on the request shape.
public actor InMemoryLineTransport: OneShotLineTransport {
    private var responses: [Data]
    private(set) var sentLines: [Data] = []

    public init(responses: [Data] = []) {
        self.responses = responses
    }

    public func send(_ line: Data) async throws -> Data {
        sentLines.append(line)
        guard !responses.isEmpty else {
            throw BackendError.unavailable("InMemoryLineTransport: no scripted response left")
        }
        return responses.removeFirst()
    }
}
