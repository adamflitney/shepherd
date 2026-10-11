import Foundation

/// A key press to send to a Ghostty terminal.
public struct GhosttyKeyAction: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case key(name: String, modifiers: [String])
        /// Printable text. Ghostty's `send key` produces no text for plain letters and digits, so
        /// these go in as pasted input instead.
        case text(String)
        /// Wait (nanoseconds) for the screen to change before the next key.
        case pause(UInt64)
    }
    public let kind: Kind
}

/// Translates the key vocabulary the rest of shepherd uses (Herdr's: "down", "enter", "esc",
/// "ctrl+c", or a digit that picks a numbered menu option) into Ghostty's.
///
/// A digit "N" becomes N-1 presses of arrow-down then Enter. Claude Code's numbered menus start with
/// the cursor on option 1, and a digit sent through Ghostty would arrive as a pasted character
/// rather than a hotkey.
public enum GhosttyKeyMap {
    private static let named: [String: String] = [
        "enter": "enter", "return": "enter", "esc": "escape", "escape": "escape", "tab": "tab",
        "space": "space", "backspace": "backspace", "delete": "delete",
        "up": "arrowUp", "down": "arrowDown", "left": "arrowLeft", "right": "arrowRight",
        "home": "home", "end": "end", "pageup": "pageUp", "pagedown": "pageDown",
    ]

    public static func actions(for keys: [String]) -> [GhosttyKeyAction] {
        keys.flatMap(actions(for:))
    }

    public static func actions(for key: String) -> [GhosttyKeyAction] {
        let k = key.lowercased()
        if let name = named[k] { return [.init(kind: .key(name: name, modifiers: []))] }
        // "ctrl+c", "ctrl-c", "alt+x", "shift+tab"
        for sep in ["+", "-"] where key.contains(sep) && key.count > 2 {
            let parts = k.components(separatedBy: sep)
            guard parts.count >= 2, let last = parts.last, !last.isEmpty else { continue }
            let mods = parts.dropLast().compactMap { m -> String? in
                switch m {
                case "ctrl", "control": return "control"
                case "alt", "option", "opt": return "option"
                case "shift": return "shift"
                case "cmd", "command", "super": return "command"
                default: return nil
                }
            }
            if mods.count == parts.count - 1 {
                return [.init(kind: .key(name: named[last] ?? last, modifiers: mods))]
            }
        }
        if key.count == 1, let n = Int(key), n >= 1 {
            return Array(repeating: .init(kind: .key(name: "arrowDown", modifiers: [])), count: n - 1)
                + [.init(kind: .key(name: "enter", modifiers: []))]
        }
        return [.init(kind: .text(key))]
    }

    private static func key(_ name: String) -> GhosttyKeyAction { .init(kind: .key(name: name, modifiers: [])) }

    /// Answers for a multi-select `AskUserQuestion`, which Claude Code draws as a checklist:
    /// `1. [ ] Apple` ... `n. [ ] ...`, then "Type something", then a "Submit" row. Enter toggles the
    /// option under the cursor (a digit sent through Ghostty would only be pasted text), arrows move
    /// it, and Enter on "Submit" opens a review whose first choice, "Submit answers", Enter confirms.
    ///
    /// So a digit means "move to that option and toggle it", and a bare "enter" means "I am done":
    /// go to Submit, open the review, confirm. The cursor starts on option 1.
    public static func multiSelectActions(for keys: [String], optionCount n: Int) -> [GhosttyKeyAction] {
        var out: [GhosttyKeyAction] = []
        var cursor = 0
        func move(to target: Int) {
            let name = target > cursor ? "arrowDown" : "arrowUp"
            out += Array(repeating: key(name), count: abs(target - cursor))
            cursor = target
        }
        for k in keys {
            if let d = Int(k), k.count == 1, (1...max(1, n)).contains(d) {
                move(to: d - 1)
                out.append(key("enter"))
            } else if ["enter", "return"].contains(k.lowercased()) {
                move(to: n + 1)  // past the options and "Type something"
                out.append(key("enter"))
                out.append(.init(kind: .pause(350_000_000)))  // the review screen replaces the list
                out.append(key("enter"))
            } else if k.count == 1, Int(k) != nil {
                out.append(.init(kind: .text(k)))  // a digit with no option behind it
            } else {
                let actions = actions(for: k)
                out += actions
                for a in actions {
                    if case .key(let name, _) = a.kind {
                        if name == "arrowDown" { cursor += 1 } else if name == "arrowUp" { cursor = max(0, cursor - 1) }
                    }
                }
            }
        }
        return out
    }
}
