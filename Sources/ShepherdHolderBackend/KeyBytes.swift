import Foundation
import ShepherdGhostty

/// The bytes a terminal sends for the key vocabulary the rest of shepherd uses. A real PTY needs the byte
/// sequences, where Ghostty's AppleScript took key names.
enum KeyBytes {
    private static let named: [String: [UInt8]] = [
        "enter": [13], "escape": [27], "tab": [9], "space": [32], "backspace": [127],
        "delete": Array("\u{1b}[3~".utf8), "home": Array("\u{1b}[H".utf8), "end": Array("\u{1b}[F".utf8),
        "pageUp": Array("\u{1b}[5~".utf8), "pageDown": Array("\u{1b}[6~".utf8),
        "arrowUp": Array("\u{1b}[A".utf8), "arrowDown": Array("\u{1b}[B".utf8),
        "arrowRight": Array("\u{1b}[C".utf8), "arrowLeft": Array("\u{1b}[D".utf8),
    ]

    /// Nil for a key that has no byte form here (ignored by the caller).
    static func bytes(name: String, modifiers: [String]) -> [UInt8]? {
        if modifiers.isEmpty { return named[name] ?? Array(name.utf8) }
        if modifiers == ["shift"], name == "tab" { return Array("\u{1b}[Z".utf8) }
        if modifiers == ["control"], name.count == 1, let c = name.uppercased().utf8.first, (64...95).contains(c) { return [c - 64] }
        if modifiers == ["option"], let base = named[name] ?? (name.count == 1 ? Array(name.utf8) : nil) { return [27] + base }
        return nil
    }

    /// What a list of key presses ("1", "down", "enter", "ctrl+c") turns into: one chunk per action, with the
    /// pauses the actions asked for.
    static func chunks(for actions: [GhosttyKeyAction]) -> [(bytes: [UInt8], pauseAfter: UInt64)] {
        var out: [(bytes: [UInt8], pauseAfter: UInt64)] = []
        for action in actions {
            switch action.kind {
            case .key(let name, let modifiers): if let b = bytes(name: name, modifiers: modifiers) { out.append((b, 0)) }
            case .text(let text): out.append((Array(text.utf8), 0))
            case .pause(let nanoseconds): if !out.isEmpty { out[out.count - 1].pauseAfter += nanoseconds }
            }
        }
        return out
    }
}
