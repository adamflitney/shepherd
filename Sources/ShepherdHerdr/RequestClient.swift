import Foundation
import ShepherdCore

/// The request/response half of the Herdr socket protocol: encode, send over
/// a one-shot transport, decode. The persistent event-subscription half is a
/// separate connection entirely (see the plan's "two hard constraints") and
/// isn't this type's concern.
public actor RequestClient {
    private let transport: any OneShotLineTransport
    private var nextRequestID = 0

    public init(transport: any OneShotLineTransport) {
        self.transport = transport
    }

    public func call<Params: Encodable, Result: Decodable>(
        method: String,
        params: Params,
        resultType: Result.Type
    ) async throws -> Result {
        nextRequestID += 1
        let requestLine = try HerdrWire.encodeRequest(id: "req\(nextRequestID)", method: method, params: params)

        let responseLine: Data
        do {
            responseLine = try await transport.send(requestLine)
        } catch let error as BackendError {
            throw error
        } catch {
            throw BackendError.unavailable("\(error)")
        }

        switch HerdrWire.classify(responseLine) {
        case .success:
            return try HerdrWire.decodeResult(Result.self, from: responseLine)
        case .error(_, let body):
            throw BackendError.remote(code: body.code, message: body.message)
        case .event, .malformed:
            let raw = String(decoding: responseLine, as: UTF8.self)
            throw BackendError.protocolViolation("expected a response to \(method), got: \(raw)")
        }
    }
}
