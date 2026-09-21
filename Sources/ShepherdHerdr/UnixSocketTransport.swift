import Foundation
import Network
import ShepherdCore

/// Guards a completion handler so it resumes a continuation at most once,
/// even when the underlying callback (e.g. `NWConnection`'s state updates)
/// can legitimately fire more than once.
private final class ResumeOnceGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func fireOnce(_ work: () -> Void) {
        lock.lock()
        let already = didResume
        didResume = true
        lock.unlock()
        if !already { work() }
    }
}

/// The real transport, talking to `~/.config/herdr/herdr.sock` over
/// `Network.framework`. Implements both transport protocols since both are
/// "connect, write, read" over the same kind of socket - `send` closes after
/// one frame (matching Herdr's verified one-shot request behaviour) while
/// `subscribe` keeps reading until the connection drops.
public final class UnixSocketTransport: OneShotLineTransport, EventStreamTransport, Sendable {
    private let socketPath: String

    public init(socketPath: String = (NSString(string: "~/.config/herdr/herdr.sock").expandingTildeInPath)) {
        self.socketPath = socketPath
    }

    public func send(_ line: Data) async throws -> Data {
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        defer { connection.cancel() }

        do {
            try await Self.waitForReady(connection)
            try await Self.write(line, on: connection)

            var framer = NDJSONFramer()
            while true {
                let chunk = try await Self.receiveChunk(on: connection)
                if chunk.isEmpty {
                    throw BackendError.unavailable("connection closed before a response arrived")
                }
                if let first = framer.append(chunk).first {
                    return first
                }
            }
        } catch let error as BackendError {
            throw error
        } catch {
            throw BackendError.unavailable("\(error)")
        }
    }

    public func subscribe(_ line: Data) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
            let task = Task {
                do {
                    try await Self.waitForReady(connection)
                    try await Self.write(line, on: connection)

                    var framer = NDJSONFramer()
                    while !Task.isCancelled {
                        let chunk = try await Self.receiveChunk(on: connection)
                        if chunk.isEmpty { break }
                        for frame in framer.append(chunk) {
                            continuation.yield(frame)
                        }
                    }
                } catch {
                    // Connection failed or dropped - the stream simply ends;
                    // HerdrSessionBackend's listen loop reconnects.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                connection.cancel()
            }
        }
    }

    // MARK: - NWConnection completion-handler bridging

    /// Resumes a `CheckedContinuation` exactly once even if the underlying
    /// completion handler could fire more than once (state updates can).
    private static func resumeOnce<T: Sendable>(
        _ body: @escaping (@escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let guardBox = ResumeOnceGuard()
        return try await withCheckedThrowingContinuation { continuation in
            body { result in
                guardBox.fireOnce { continuation.resume(with: result) }
            }
        }
    }

    private static func waitForReady(_ connection: NWConnection) async throws {
        try await resumeOnce { (complete: @escaping @Sendable (Result<Void, Error>) -> Void) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    complete(.success(()))
                case .failed(let error):
                    complete(.failure(error))
                case .cancelled:
                    complete(.failure(BackendError.unavailable("connection cancelled before becoming ready")))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func write(_ data: Data, on connection: NWConnection) async throws {
        try await resumeOnce { (complete: @escaping @Sendable (Result<Void, Error>) -> Void) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    complete(.failure(error))
                } else {
                    complete(.success(()))
                }
            })
        }
    }

    /// Empty `Data` signals the connection ended.
    private static func receiveChunk(on connection: NWConnection) async throws -> Data {
        try await resumeOnce { complete in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    complete(.failure(error))
                } else if let data, !data.isEmpty {
                    complete(.success(data))
                } else if isComplete {
                    complete(.success(Data()))
                } else {
                    complete(.success(Data()))
                }
            }
        }
    }
}
