import CryptoKit
import Foundation
import ShepherdCore

public struct IdentityResolution: Equatable {
    public let id: SessionID
    /// Non-nil only on the frame where a pane's identity migrates from a
    /// provisional pane-based id to a stable agent-based one - callers use
    /// this to emit `.sessionRemoved(previousProvisionalID)` followed by
    /// `.sessionChanged` for the new id, atomically.
    public let previousProvisionalID: SessionID?
}

/// Resolves a pane's durable session identity. Pane ids like `"w4:p1"` are
/// positional and reused across restarts - the worst identity, since "same
/// id, different session" would silently transfer an acknowledgement
/// watermark to an unrelated agent. A pane exists before its agent
/// registers, so this remembers the migration from provisional to stable so
/// a pane's identity never splits or reverts once it has one.
public struct IdentityResolver {
    /// The most recent id resolved for a pane, whether provisional or
    /// stable - tracking only "stable" would make a pane's very first
    /// observation (which usually already has `agentSession` attached)
    /// indistinguishable from a real provisional-to-stable migration.
    private var lastIDByPaneID: [String: SessionID] = [:]

    public init() {}

    public mutating func resolve(paneID: String, agentSession: AgentSessionWire?) -> IdentityResolution {
        let newID: SessionID
        if let agentSession {
            newID = Self.stableID(for: agentSession)
        } else if let remembered = lastIDByPaneID[paneID] {
            newID = remembered
        } else {
            newID = SessionID(rawValue: "pane:\(paneID)")
        }

        let previous = lastIDByPaneID[paneID]
        lastIDByPaneID[paneID] = newID

        if let previous, previous != newID, previous.rawValue.hasPrefix("pane:") {
            return IdentityResolution(id: newID, previousProvisionalID: previous)
        }
        return IdentityResolution(id: newID, previousProvisionalID: nil)
    }

    private static func stableID(for agentSession: AgentSessionWire) -> SessionID {
        switch agentSession.kind {
        case "path":
            let identifier = extractUUID(from: agentSession.value) ?? sha256Hex(agentSession.value)
            return SessionID(rawValue: "agent:\(identifier)")
        default:
            // "id" is the only kind observed live; anything else falls back
            // to using the raw value directly, same as "id".
            return SessionID(rawValue: "agent:\(agentSession.value)")
        }
    }

    /// The legacy hook-based prototype expects paths shaped like
    /// `.../<uuid>.jsonl` (Claude Code's own session transcript naming) -
    /// this kind wasn't observed live against Herdr, so it's speculative.
    private static func extractUUID(from path: String) -> String? {
        for component in path.split(separator: "/").reversed() {
            let stem = component.hasSuffix(".jsonl") ? String(component.dropLast(".jsonl".count)) : String(component)
            if UUID(uuidString: stem) != nil {
                return stem
            }
        }
        return nil
    }

    private static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
