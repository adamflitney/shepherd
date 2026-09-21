import Foundation

public struct HerdrErrorBody: Decodable, Equatable, Sendable {
    public let code: String
    public let message: String
}

/// Frame-level classification only - which of Herdr's three envelope shapes
/// a raw line is. Payload decoding is a second step via `decodeResult`/
/// `decodeEventData`, once the caller knows what type to expect.
public enum HerdrFrameKind: Equatable {
    case success(id: String)
    case error(id: String, HerdrErrorBody)
    case event(type: String)
    case malformed
}

public enum HerdrWire {
    private struct FrameHeader: Decodable {
        let id: String?
        let event: String?
    }

    private struct ErrorEnvelope: Decodable {
        let error: HerdrErrorBody
    }

    /// Response frames always carry an `id` key (even `""` when Herdr can't
    /// echo one back for a malformed request); event frames never do. That's
    /// the whole discriminator - verified against a live socket.
    public static func classify(_ raw: Data) -> HerdrFrameKind {
        guard let header = try? JSONDecoder().decode(FrameHeader.self, from: raw) else {
            return .malformed
        }
        if let id = header.id {
            if let errorEnvelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: raw) {
                return .error(id: id, errorEnvelope.error)
            }
            return .success(id: id)
        }
        if let event = header.event {
            return .event(type: event)
        }
        return .malformed
    }

    public static func decodeResult<T: Decodable>(_ type: T.Type, from raw: Data) throws -> T {
        try JSONDecoder().decode(ResultEnvelope<T>.self, from: raw).result
    }

    public static func decodeEventData<T: Decodable>(_ type: T.Type, from raw: Data) throws -> T {
        try JSONDecoder().decode(EventEnvelope<T>.self, from: raw).data
    }

    /// Encodes one `{id, method, params}\n` request line - shared by
    /// `RequestClient`'s one-shot calls and the persistent connection's
    /// initial `events.subscribe` line, since both are the same wire shape.
    public static func encodeRequest<Params: Encodable>(id: String, method: String, params: Params) throws -> Data {
        var data = try JSONEncoder().encode(RequestEnvelope(id: id, method: method, params: params))
        data.append(0x0A)
        return data
    }
}

private struct ResultEnvelope<T: Decodable>: Decodable {
    let result: T
}

private struct EventEnvelope<T: Decodable>: Decodable {
    let data: T
}

private struct RequestEnvelope<P: Encodable>: Encodable {
    let id: String
    let method: String
    let params: P
}

public struct EmptyParams: Encodable {
    public init() {}
}

/// Decodes successfully against any JSON object - used where a call's
/// result body genuinely doesn't matter, only that it succeeded.
public struct IgnoredResult: Decodable, Sendable {}

// MARK: - Payload shapes

public struct AgentSessionWire: Decodable, Equatable, Sendable {
    public let source: String
    public let agent: String
    public let kind: String
    public let value: String
}

/// Mirrors Herdr's `PaneInfo`. `agent`/`agentStatus`'s absence models a plain
/// shell pane - Herdr omits `agent` entirely rather than sending it null.
public struct PaneWire: Decodable, Equatable, Sendable {
    public let paneID: String
    public let workspaceID: String
    public let tabID: String
    public let agent: String?
    public let agentStatus: String
    public let agentSession: AgentSessionWire?
    public let cwd: String?
    public let foregroundCwd: String?
    public let title: String?
    public let terminalTitle: String?
    public let terminalTitleStripped: String?
    public let focused: Bool

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case agent
        case agentStatus = "agent_status"
        case agentSession = "agent_session"
        case cwd
        case foregroundCwd = "foreground_cwd"
        case title
        case terminalTitle = "terminal_title"
        case terminalTitleStripped = "terminal_title_stripped"
        case focused
    }
}

public struct WorkspaceWire: Decodable, Equatable, Sendable {
    public let workspaceID: String
    public let number: Int
    public let label: String
    public let focused: Bool
    public let paneCount: Int
    public let tabCount: Int
    public let activeTabID: String
    public let agentStatus: String

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case number, label, focused
        case paneCount = "pane_count"
        case tabCount = "tab_count"
        case activeTabID = "active_tab_id"
        case agentStatus = "agent_status"
    }
}

public struct SessionSnapshotWire: Decodable, Equatable, Sendable {
    public let workspaces: [WorkspaceWire]
    public let panes: [PaneWire]
    public let focusedPaneID: String?

    enum CodingKeys: String, CodingKey {
        case workspaces, panes
        case focusedPaneID = "focused_pane_id"
    }
}

/// `session.snapshot`'s `result` isn't the snapshot directly - it's tagged
/// with a `type` field one level above it, matching Herdr's convention of
/// tagging polymorphic results.
public struct SessionSnapshotResultWire: Decodable, Equatable, Sendable {
    public let type: String
    public let snapshot: SessionSnapshotWire
}

public struct PaneUpdatedEventDataWire: Decodable, Equatable, Sendable {
    public let type: String
    public let pane: PaneWire
}

public struct PaneClosedEventDataWire: Decodable, Equatable, Sendable {
    public let paneID: String
    public let workspaceID: String

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
    }
}

/// `workspace.create`'s result. `rootPane`'s required fields overlap exactly
/// with `PaneWire`'s, so it decodes directly as one.
public struct WorkspaceCreatedResultWire: Decodable, Equatable, Sendable {
    public let type: String
    public let workspace: WorkspaceWire
    public let rootPane: PaneWire

    enum CodingKeys: String, CodingKey {
        case type, workspace
        case rootPane = "root_pane"
    }
}

/// `agent.start`'s result. `AgentInfo`'s required fields (`pane_id`,
/// `workspace_id`, `tab_id`, `agent_status`, `focused`) are a superset match
/// for `PaneWire`'s, so it decodes directly as one too.
public struct AgentStartedResultWire: Decodable, Equatable, Sendable {
    public let type: String
    public let agent: PaneWire
}

public struct PaneAgentStatusChangedEventDataWire: Decodable, Equatable, Sendable {
    public let paneID: String
    public let workspaceID: String
    public let agentStatus: String
    public let agent: String?
    public let title: String?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case agentStatus = "agent_status"
        case agent, title
    }
}
