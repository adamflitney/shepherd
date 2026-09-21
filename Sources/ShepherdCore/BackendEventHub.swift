import Foundation

/// Thread-safe fan-out of `BackendEvent`s to any number of `AsyncStream`
/// subscribers. Lives outside actor isolation deliberately: `SessionBackend`
/// declares `events()` as non-async, and an actor's synchronous methods are
/// only callable without `await` from outside if they're `nonisolated` - so
/// both `FakeSessionBackend` and the future Herdr adapter hold one of these
/// and expose it via a `nonisolated` `events()` implementation.
public final class BackendEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<BackendEvent>.Continuation] = [:]

    public init() {}

    public func makeStream() -> AsyncStream<BackendEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    public func broadcast(_ event: BackendEvent) {
        lock.lock()
        let subscribers = Array(continuations.values)
        lock.unlock()

        for continuation in subscribers {
            continuation.yield(event)
        }
    }
}
