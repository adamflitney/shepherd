import Foundation

/// Splits a byte stream into newline-delimited JSON frames. Compacts the
/// internal buffer once per `append` call rather than once per frame, so a
/// burst containing many frames in one read stays O(n) instead of the
/// quadratic behaviour a naive "remove the completed frame, repeat" approach
/// would have under load.
public struct NDJSONFramer {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)

        var frames: [Data] = []
        var searchStart = buffer.startIndex
        while let newlineIndex = buffer[searchStart...].firstIndex(of: 0x0A) {
            let frame = buffer[searchStart..<newlineIndex]
            if !frame.isEmpty {
                frames.append(Data(frame))
            }
            searchStart = buffer.index(after: newlineIndex)
        }

        if searchStart > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<searchStart)
        }

        return frames
    }
}
