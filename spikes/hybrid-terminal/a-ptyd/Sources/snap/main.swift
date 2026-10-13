import Foundation
import SwiftTerm

final class Sink: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

// snap <rawfile> <cols> <rows> [--tail N]  -> renders the bytes through SwiftTerm's headless engine
let a = CommandLine.arguments
let data = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: a[1])))
let cols = Int(a[2])!, rows = Int(a[3])!
let skip = a.firstIndex(of: "--skip").map { Int(a[$0 + 1])! } ?? 0
let t = Terminal(delegate: Sink(), options: TerminalOptions(cols: cols, rows: rows))
t.feed(byteArray: Array(data[skip...]))
print("alt-buffer:", t.isCurrentBufferAlternate, " cursor:", t.buffer.x, t.buffer.y)
for r in 0..<rows {
    if let l = t.getLine(row: r) { print(String(format: "%02d|", r) + l.translateToString(trimRight: true)) }
}
