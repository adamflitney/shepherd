import Foundation
import ShepherdCore
import ShepherdUI

/// Wire DTOs, kept separate from the domain model - same precedent as
/// `ShepherdHerdr`'s own wire types (`HerdrWire.swift`), just for this
/// server's JSON instead of Herdr's socket protocol.
private struct SessionWire: Encodable {
    let id: String
    let title: String
    let agent: String
    let attentionKind: String
    let blocker: String?
    let summary: String?
    let options: [String]?
    let optionsAllowMultiple: Bool
    let workingDirectory: String?
    let isFocused: Bool
    let canPrompt: Bool
    let canRespond: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, agent
        case attentionKind = "attention_kind"
        case blocker, summary, options
        case optionsAllowMultiple = "options_allow_multiple"
        case workingDirectory = "working_directory"
        case isFocused = "is_focused"
        case canPrompt = "can_prompt"
        case canRespond = "can_respond"
    }
}

private func wire(_ session: Session) -> SessionWire {
    SessionWire(
        id: session.id.rawValue,
        title: session.title,
        agent: session.agent.rawValue,
        attentionKind: session.attention.kind.rawValue,
        blocker: session.attention.blocker?.rawValue,
        summary: session.attention.summary,
        options: session.attention.options,
        optionsAllowMultiple: session.attention.optionsAllowMultiple,
        workingDirectory: session.workingDirectory?.path,
        isFocused: session.isFocused,
        canPrompt: session.capabilities.contains(.prompt),
        canRespond: session.attention.blocker != nil
    )
}

private struct PeekWire: Encodable { let text: String }
private struct ErrorWire: Encodable { let error: String }
private struct PromptBody: Decodable { let text: String }
private struct RespondBody: Decodable { let keys: [String] }

/// Everything the prototype's HTTP layer needs from the live app: the
/// current session list (freshly fetched per request - Herdr's socket call
/// is cheap and this is a low-traffic, single-user endpoint, so there's no
/// separate cache to keep in sync) and the same actions the native panel
/// already exposes through `SessionBackend`.
struct SessionsAPI {
    let backend: any SessionBackend

    func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        let parts = pathComponents(request.path)
        do {
            // Every session-scoped route is `api/sessions/<id>/<action>` -
            // matched by shape (count + fixed segments) rather than a
            // literal-array switch pattern, which Swift doesn't support for
            // variable-length `[String]` matches.
            if request.method == "GET", parts == ["api", "sessions"] {
                return try await listSessions()
            }
            if parts.count == 4, parts[0] == "api", parts[1] == "sessions" {
                let id = SessionID(rawValue: parts[2])
                switch (request.method, parts[3]) {
                case ("POST", "focus"):
                    try await backend.focus(id)
                    return .json(Data("{}".utf8))
                case ("POST", "prompt"):
                    let body = try JSONDecoder().decode(PromptBody.self, from: request.body)
                    try await backend.prompt(id, text: body.text)
                    return .json(Data("{}".utf8))
                case ("POST", "respond"):
                    let body = try JSONDecoder().decode(RespondBody.self, from: request.body)
                    try await backend.respond(id, keys: body.keys)
                    return .json(Data("{}".utf8))
                case ("GET", "peek"):
                    let text = try await backend.peek(id)
                    return .json(try JSONEncoder().encode(PeekWire(text: text)))
                default:
                    return .notFound()
                }
            }
            return .notFound()
        } catch let error as BackendError {
            return .json(try! JSONEncoder().encode(ErrorWire(error: "\(error)")), status: 502)
        } catch {
            return .json(try! JSONEncoder().encode(ErrorWire(error: "\(error)")), status: 400)
        }
    }

    private func listSessions() async throws -> HTTPServer.Response {
        let snapshot = try await backend.snapshot()
        let sorted = sortSessions(snapshot.sessions)
        return .json(try JSONEncoder().encode(sorted.map(wire)))
    }

    private func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
}

/// Bridges `BackendEvent`s into the small JSON payload the mobile page's
/// SSE listener understands - just enough to know "something changed,
/// re-fetch `/api/sessions`", not a full diff protocol.
func sseEventData(for event: BackendEvent) -> Data? {
    struct Payload: Encodable { let type: String }
    let type: String
    switch event {
    case .connection: type = "connection"
    case .snapshot: type = "snapshot"
    case .sessionChanged: type = "session_changed"
    case .sessionRemoved: type = "session_removed"
    case .focusChanged: type = "focus_changed"
    }
    return try? JSONEncoder().encode(Payload(type: type))
}
