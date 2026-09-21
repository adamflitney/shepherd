import Foundation

/// The result of one headless `claude -p --output-format json` invocation -
/// the "home session, but inline in the panel" feature. Pure decode/decision
/// logic lives here so it's fully testable without ever shelling out; the
/// actual `Process` invocation is a thin I/O edge in the `Shepherd` target,
/// same tier as `UnixSocketTransport` or `AppleScriptTerminalActivator`.
public struct PromptRunResult: Equatable, Sendable {
    public let rawText: String
    public let sessionID: String
    public let isError: Bool
    public let hadPermissionDenials: Bool

    public init(rawText: String, sessionID: String, isError: Bool, hadPermissionDenials: Bool) {
        self.rawText = rawText
        self.sessionID = sessionID
        self.isError = isError
        self.hadPermissionDenials = hadPermissionDenials
    }
}

/// Appended to the headless call's system prompt. Claude runs there with
/// only read-only tools (Read/Grep/Glob/WebSearch/WebFetch) and no ability
/// to edit or run arbitrary commands - if a task genuinely needs more than
/// that, this is the explicit, parseable way for it to say so, rather than
/// Shepherd trying to infer intent from prose.
public let needsSessionMarker = "NEEDS_SESSION"

public let inlinePromptSystemPromptAddendum = """
You are running headless, inline in a quick-answer panel, with only \
read-only tools (Read, Grep, Glob, WebSearch, WebFetch) - no file edits, \
no shell commands with side effects. If the user's request genuinely needs \
more than that (making changes, running commands, or sustained multi-step \
work), don't attempt a workaround: give a one-sentence explanation of what \
you'd need to do, then end your reply with exactly this line on its own: \
\(needsSessionMarker)
"""

private struct RawPromptResult: Decodable {
    let result: String?
    let errors: [String]?
    let sessionID: String
    let isError: Bool
    let permissionDenials: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case result, errors
        case sessionID = "session_id"
        case isError = "is_error"
        case permissionDenials = "permission_denials"
    }
}

public enum PromptRunDecodeError: Error {
    case malformed
}

/// Decodes one line of `claude -p --output-format json` output. Tolerant of
/// the many fields this doesn't need (cost, token usage, timings, ...) -
/// only reads what the escalation decision and display actually depend on.
public func decodePromptRunResult(from json: Data) throws -> PromptRunResult {
    let raw: RawPromptResult
    do {
        raw = try JSONDecoder().decode(RawPromptResult.self, from: json)
    } catch {
        throw PromptRunDecodeError.malformed
    }

    let text = raw.result ?? raw.errors?.joined(separator: " ") ?? "No response."
    return PromptRunResult(
        rawText: text,
        sessionID: raw.sessionID,
        isError: raw.isError,
        hadPermissionDenials: !(raw.permissionDenials ?? []).isEmpty
    )
}

/// True when the read-only headless run couldn't (or says it couldn't)
/// finish the task, so the UI should hand off to a real Herdr session
/// instead of showing this as a final answer.
public func shouldEscalateToSession(_ result: PromptRunResult) -> Bool {
    result.hadPermissionDenials || textEndsWithMarker(result.rawText)
}

/// What to actually show inline - the marker line is Shepherd's own
/// protocol with the model, never something the user should see.
public func displayText(for result: PromptRunResult) -> String {
    guard textEndsWithMarker(result.rawText) else { return result.rawText }
    var lines = result.rawText.split(separator: "\n", omittingEmptySubsequences: false)
    lines.removeLast()
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func textEndsWithMarker(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(needsSessionMarker)
}

/// What the inline-prompt panel does with one submitted prompt, after the
/// escalation decision has already been made and acted on (spawning and
/// focusing a real session happens before this is returned, not after).
public enum InlinePromptOutcome: Equatable, Sendable {
    case answered(text: String, sessionID: String)
    case escalated
    case failed(String)
}
