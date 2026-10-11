import Foundation

/// Drives Ghostty by running AppleScript through `/usr/bin/osascript`. A subprocess per call keeps
/// the (not thread-safe) in-process AppleScript machinery out of the app and lets us time calls out;
/// it costs a few tens of milliseconds, which is fine for user-initiated actions.
public struct OsascriptGhosttyScripting: GhosttyScripting {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    // ASCII "unit separator", which does not occur in ids or titles.
    private static let sep = "\u{1F}"

    public func isRunning() async -> Bool {
        (try? await run("tell application \"System Events\" to return (exists process \"Ghostty\")"))?.trimmed == "true"
    }

    public func open(command: String, workingDirectory: String, environment: [String: String], windowID: String?) async throws -> GhosttyTerminalRef {
        let env = environment.sorted { $0.key < $1.key }.map { "\(AppleScript.quote($0.key + "=" + $0.value))" }.joined(separator: ", ")
        let target: String
        if let windowID {
            target = """
            set found to false
            repeat with w in windows
                if (id of w) is \(AppleScript.quote(windowID)) then
                    set found to true
                    set theTab to new tab in w with configuration cfg
                    set theWindowID to id of w
                    exit repeat
                end if
            end repeat
            if not found then
                set theWindow to new window with configuration cfg
                set theWindowID to id of theWindow
                set theTab to selected tab of theWindow
            end if
            """
        } else {
            target = """
            set theWindow to new window with configuration cfg
            set theWindowID to id of theWindow
            set theTab to selected tab of theWindow
            """
        }
        let script = """
        tell application "Ghostty"
            set cfg to new surface configuration
            set command of cfg to \(AppleScript.quote(command))
            set initial working directory of cfg to \(AppleScript.quote(workingDirectory))
            set environment variables of cfg to {\(env)}
            \(target)
            return theWindowID & "\(Self.sep)" & (id of theTab) & "\(Self.sep)" & (id of (focused terminal of theTab))
        end tell
        """
        let reply = try await run(script).trimmed
        let parts = reply.components(separatedBy: Self.sep)
        guard parts.count == 3 else { throw GhosttyError.malformedReply(reply) }
        return GhosttyTerminalRef(windowID: parts[0], tabID: parts[1], terminalID: parts[2])
    }

    public func listTerminals() async throws -> [GhosttyTerminalInfo] {
        let script = """
        tell application "Ghostty"
            set out to ""
            repeat with w in windows
                set wid to id of w
                repeat with t in tabs of w
                    set tid to id of t
                    repeat with term in terminals of t
                        set out to out & wid & "\(Self.sep)" & tid & "\(Self.sep)" & (id of term) & "\(Self.sep)" & (name of term) & linefeed
                    end repeat
                end repeat
            end repeat
            return out
        end tell
        """
        let reply = try await run(script)
        return try Self.parseTerminals(reply)
    }

    static func parseTerminals(_ reply: String) throws -> [GhosttyTerminalInfo] {
        try reply.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            let f = line.components(separatedBy: sep)
            guard f.count >= 4 else { throw GhosttyError.malformedReply(String(line)) }
            return GhosttyTerminalInfo(ref: GhosttyTerminalRef(windowID: f[0], tabID: f[1], terminalID: f[2]), name: f[3...].joined(separator: sep))
        }
    }

    public func inputText(_ text: String, terminalID: String) async throws {
        _ = try await run("""
        tell application "Ghostty" to input text \(AppleScript.quote(text)) to terminal id \(AppleScript.quote(terminalID))
        """)
    }

    public func sendKey(_ key: String, modifiers: [String], terminalID: String) async throws {
        let mods = modifiers.isEmpty ? "" : " modifiers \(AppleScript.quote(modifiers.joined(separator: ",")))"
        _ = try await run("""
        tell application "Ghostty" to send key \(AppleScript.quote(key))\(mods) to terminal id \(AppleScript.quote(terminalID))
        """)
    }

    public func focus(terminalID: String) async throws {
        _ = try await run("""
        tell application "Ghostty"
            focus terminal id \(AppleScript.quote(terminalID))
            activate
        end tell
        """)
    }

    public func close(terminalID: String) async throws {
        _ = try await run("tell application \"Ghostty\" to close terminal id \(AppleScript.quote(terminalID))")
    }

    public func frontmostTerminalID() async throws -> String? {
        let reply = try await run("""
        tell application "Ghostty"
            if not frontmost then return ""
            if (count of windows) is 0 then return ""
            return id of (focused terminal of (selected tab of front window))
        end tell
        """).trimmed
        return reply.isEmpty ? nil : reply
    }

    public func frontWindowID() async throws -> String? {
        let reply = try await run("""
        tell application "Ghostty"
            if (count of windows) is 0 then return ""
            return id of front window
        end tell
        """).trimmed
        return reply.isEmpty ? nil : reply
    }

    // MARK: - process plumbing

    private func run(_ script: String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await Self.execute(script) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw GhosttyError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func execute(_ script: String) async throws -> String {
        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run("/usr/bin/osascript", ["-"], stdin: script)
        } catch {
            throw GhosttyError.scriptFailed("\(error)")
        }
        if result.status == 0 { return result.stdout }
        let err = result.stderr
        if err.contains("-600") || err.contains("isn’t running") || err.contains("isn't running") { throw GhosttyError.notRunning }
        throw GhosttyError.scriptFailed(err.trimmed)
    }
}

enum AppleScript {
    /// A string literal for AppleScript source: wrapped in quotes with `\` and `"` escaped.
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
