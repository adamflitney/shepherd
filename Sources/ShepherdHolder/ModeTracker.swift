import Foundation

/// Follows `ESC [ ? Pm h|l` in a program's output, so a client that attaches after the replay buffer has wrapped can be
/// told which terminal modes are really on (alternate screen, mouse tracking, bracketed paste ...). Without it a
/// reconnected multi-line paste would be submitted line by line. Sequences may be split across reads.
public struct ModeTracker: Sendable {
    public static let tracked: Set<Int> = [1, 25, 47, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1047, 1049, 2004]

    private var state: [Int: Bool] = [:]
    private var carry: [UInt8] = []

    public init() {}

    public var activeModes: [Int] { state.filter { $0.value }.keys.sorted() }

    public mutating func feed(_ chunk: [UInt8]) {
        let data = carry + chunk
        var i = 0
        while i < data.count {
            guard let esc = data[i...].firstIndex(of: 0x1b) else { i = data.count; break }
            i = esc
            if i + 2 >= data.count { break }
            guard data[i + 1] == 0x5b, data[i + 2] == 0x3f else { i += 1; continue }
            var j = i + 3
            while j < data.count, (data[j] >= 0x30 && data[j] <= 0x39) || data[j] == 0x3b { j += 1 }
            if j >= data.count { break }
            if data[j] == 0x68 || data[j] == 0x6c {
                let params = String(decoding: data[(i + 3)..<j], as: UTF8.self).split(separator: ";").compactMap { Int($0) }
                for mode in params where Self.tracked.contains(mode) { state[mode] = data[j] == 0x68 }
            }
            i = j + 1
        }
        carry = i < data.count ? Array(data[i...].suffix(32)) : []
    }

    /// The bytes that switch the active modes back on, to send ahead of a replay.
    public static func restoreSequence(for modes: [Int]) -> [UInt8] {
        modes.flatMap { Array("\u{1b}[?\($0)h".utf8) }
    }
}
