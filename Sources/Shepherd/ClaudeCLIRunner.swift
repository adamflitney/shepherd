import Foundation
import ShepherdCore

/// Shells out to the real `claude` CLI in `-p` (headless, non-interactive)
/// mode for the inline quick-answer panel. Thin I/O edge, untested by unit
/// tests - same tier as `UnixSocketTransport` or `AppleScriptTerminalActivator`;
/// the decode/escalation logic it hands off to is fully tested in
/// `ShepherdCore`'s `PromptRun.swift`.
enum ClaudeCLIRunner {
    struct RunError: Error { let message: String }

    /// A GUI app (unlike a Terminal-launched process) gets a minimal PATH
    /// that typically doesn't include wherever `claude` actually lives
    /// (nvm/homebrew/~/.local/bin/...). Resolving it once via a login shell
    /// - which sources the same profile a real terminal would - is far more
    /// portable than guessing or hardcoding a path. Cached since it can't
    /// change without relaunching Shepherd.
    private static let resolvedClaudePath: String? = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v claude"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }()

    /// Runs one turn. `resumeSessionID` continues a prior inline
    /// conversation via `--resume`; omitted, `claude` starts a fresh one and
    /// its own generated session id comes back in the decoded result.
    static func run(prompt: String, resumeSessionID: String?) async throws -> PromptRunResult {
        let data = try await runProcess(prompt: prompt, resumeSessionID: resumeSessionID)
        return try decodePromptRunResult(from: data)
    }

    private static func runProcess(prompt: String, resumeSessionID: String?) async throws -> Data {
        guard let claudePath = resolvedClaudePath else {
            throw RunError(message: "Couldn't find the claude CLI on PATH.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudePath)
            process.arguments = arguments(prompt: prompt, resumeSessionID: resumeSessionID)
            // Matches AppDelegate.defaultSessionDirectory (sessions.defaultDirectory,
            // default ~), so an escalated/promoted session (a real
            // interactive `claude`, started via Herdr) runs in the same
            // place this headless one did.
            process.currentDirectoryURL = URL(fileURLWithPath: ShepherdConfig.load().resolvedDefaultSessionDirectory)

            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe() // discarded - stderr isn't part of the JSON contract
            // Left unset, this inherits whatever Shepherd's own stdin is -
            // if that's ever a real tty (as it is when launched from a
            // terminal, e.g. during development), claude spends a fixed ~3s
            // waiting to see if piped input is coming before giving up.
            // Explicit /dev/null makes that EOF immediate every time.
            process.standardInput = FileHandle.nullDevice

            // A single JSON result line is well under the pipe's buffer, so
            // reading only after termination (rather than incrementally via
            // a readability handler) is simple and safe here, and avoids
            // mutating captured state from a concurrent callback.
            process.terminationHandler = { _ in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: data)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: RunError(message: "Couldn't launch claude: \(error)"))
            }
        }
    }

    private static func arguments(prompt: String, resumeSessionID: String?) -> [String] {
        var args = [
            "-p", "--output-format", "json",
            "--permission-prompts", "none",
            "--allowedTools", "Read Grep Glob WebSearch WebFetch",
            "--append-system-prompt", inlinePromptSystemPromptAddendum,
            // This path already replaces CLAUDE.md's home-session judgment
            // with its own read-only-tools + system-prompt contract, so none
            // of settings/skills/MCP loading is actually needed - skipping
            // them cuts CLI startup overhead from ~3s to well under 1s.
            // (--bare goes further but only supports API-key auth, not the
            // OAuth login this account uses.)
            "--setting-sources", "",
            "--disable-slash-commands",
            "--strict-mcp-config",
            // Haiku, not the default model: this path is for quick answers -
            // real work escalates to a full session anyway, and Haiku is
            // both faster and cheaper for exactly that quick-answer case.
            "--model", "haiku",
        ]
        if let resumeSessionID {
            args += ["--resume", resumeSessionID]
        }
        args.append(prompt)
        return args
    }
}
