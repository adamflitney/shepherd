import Foundation

/// The persistent half of the Herdr socket protocol: one long-lived
/// connection that stays open indefinitely, streaming frames after the
/// initial subscribe request. Deliberately separate from
/// `OneShotLineTransport` - Herdr's request connections close after one
/// response, so requests and the event stream are never the same connection.
public protocol EventStreamTransport: Sendable {
    /// Sends the subscribe request line, then yields every subsequent raw
    /// frame line (the ack and all pushed events) until the connection ends.
    /// A finished stream means the connection dropped; reconnection is the
    /// caller's responsibility.
    func subscribe(_ line: Data) -> AsyncStream<Data>
}

/// Test double: lets a test push frames on demand and finish the stream to
/// simulate a dropped connection.
public final class InMemoryEventTransport: EventStreamTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private(set) var lastSubscribeLine: Data?

    public init() {}

    public func subscribe(_ line: Data) -> AsyncStream<Data> {
        lock.lock()
        lastSubscribeLine = line
        lock.unlock()

        return AsyncStream { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
        }
    }

    public func push(_ line: Data) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(line)
    }

    public func dropConnection() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }
}
