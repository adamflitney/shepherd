import Foundation

/// The holder's socket protocol. A connection starts with one JSON request line. After a successful `attach` reply
/// and the replay bytes, the connection carries output from the holder as raw bytes and input to it as frames:
/// `[type u8][length u32 big-endian][payload]`.
public enum HolderFrame: Equatable, Sendable {
    case input([UInt8])
    case resize(cols: UInt16, rows: UInt16)
    case detach

    public static let maxPayload = 1 << 20

    public func encoded() -> [UInt8] {
        switch self {
        case .input(let bytes): return Self.wrap(0, bytes)
        case .resize(let cols, let rows):
            return Self.wrap(1, [UInt8(cols >> 8), UInt8(cols & 0xff), UInt8(rows >> 8), UInt8(rows & 0xff)])
        case .detach: return Self.wrap(2, [])
        }
    }

    private static func wrap(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let n = payload.count
        return [type, UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)] + payload
    }
}

/// Incremental decoder. `push` returns the frames completed so far; a malformed stream (oversized length, bad resize)
/// flips `failed` and the caller drops the connection.
public struct HolderFrameParser: Sendable {
    private var buffer: [UInt8] = []
    public private(set) var failed = false

    public init() {}

    public mutating func push(_ bytes: [UInt8]) -> [HolderFrame] {
        guard !failed else { return [] }
        buffer += bytes
        var frames: [HolderFrame] = []
        while buffer.count >= 5 {
            let type = buffer[0]
            let length = Int(buffer[1]) << 24 | Int(buffer[2]) << 16 | Int(buffer[3]) << 8 | Int(buffer[4])
            guard length <= HolderFrame.maxPayload else { failed = true; buffer = []; return frames }
            guard buffer.count >= 5 + length else { break }
            let payload = Array(buffer[5..<(5 + length)])
            buffer.removeFirst(5 + length)
            switch type {
            case 0: frames.append(.input(payload))
            case 1:
                guard payload.count == 4 else { failed = true; buffer = []; return frames }
                frames.append(.resize(cols: UInt16(payload[0]) << 8 | UInt16(payload[1]), rows: UInt16(payload[2]) << 8 | UInt16(payload[3])))
            case 2: frames.append(.detach)
            default: failed = true; buffer = []; return frames
            }
        }
        return frames
    }
}
