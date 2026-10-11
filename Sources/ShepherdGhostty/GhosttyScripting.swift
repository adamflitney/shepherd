import Foundation

/// Where a terminal lives inside Ghostty. Ids are Ghostty's own and last only as long as Ghostty runs.
public struct GhosttyTerminalRef: Hashable, Sendable, Codable {
    public let windowID: String
    public let tabID: String
    public let terminalID: String

    public init(windowID: String, tabID: String, terminalID: String) {
        self.windowID = windowID
        self.tabID = tabID
        self.terminalID = terminalID
    }
}

public struct GhosttyTerminalInfo: Hashable, Sendable {
    public let ref: GhosttyTerminalRef
    /// The terminal's title (whatever the program set via OSC), e.g. Claude Code's "✳ Fix the build".
    public let name: String

    public init(ref: GhosttyTerminalRef, name: String) {
        self.ref = ref
        self.name = name
    }
}

public enum GhosttyError: Error, Equatable, Sendable, CustomStringConvertible {
    case notRunning
    case scriptFailed(String)
    case timedOut
    case malformedReply(String)

    public var description: String {
        switch self {
        case .notRunning: return "Ghostty is not running"
        case .scriptFailed(let m): return "Ghostty scripting failed: \(m)"
        case .timedOut: return "Ghostty did not answer in time"
        case .malformedReply(let m): return "unexpected reply from Ghostty: \(m)"
        }
    }
}

/// The slice of Ghostty's AppleScript interface shepherd uses. Behind a protocol so the backend can
/// be tested without a running Ghostty.
public protocol GhosttyScripting: Sendable {
    func isRunning() async -> Bool
    /// Opens a terminal running `command` in `cwd` with `env` added, as a new tab in `windowID` (or a
    /// new window when nil or when that window no longer exists).
    func open(command: String, workingDirectory: String, environment: [String: String], windowID: String?) async throws -> GhosttyTerminalRef
    /// Every terminal in every window, in one round trip.
    func listTerminals() async throws -> [GhosttyTerminalInfo]
    func inputText(_ text: String, terminalID: String) async throws
    func sendKey(_ key: String, modifiers: [String], terminalID: String) async throws
    /// Selects the terminal's tab and raises its window.
    func focus(terminalID: String) async throws
    func close(terminalID: String) async throws
    /// The terminal that has keyboard focus while Ghostty is the frontmost app, else nil.
    func frontmostTerminalID() async throws -> String?
    /// The id of Ghostty's front window, for "use this window for agents".
    func frontWindowID() async throws -> String?
}
