import Foundation

/// The last `capacity` bytes a session has written, replayed to a client that attaches.
public struct RingBuffer: Sendable {
    public let capacity: Int
    public private(set) var bytes: [UInt8] = []

    public init(capacity: Int) { self.capacity = capacity }

    public var count: Int { bytes.count }

    public mutating func removeAll() { bytes = [] }

    public mutating func append(_ chunk: [UInt8]) {
        bytes += chunk
        if bytes.count > capacity { bytes.removeFirst(bytes.count - capacity) }
    }
}
