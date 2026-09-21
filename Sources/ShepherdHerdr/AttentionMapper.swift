import ShepherdCore

/// Maps Herdr's `agent_status` wire string onto our closed `Kind`. Any
/// unrecognised string degrades to `.unknown` rather than throwing - a
/// Herdr release adding a sixth status must not brick the app.
public func mapHerdrAgentStatus(_ raw: String) -> AttentionState.Kind {
    AttentionState.Kind(rawValue: raw) ?? .unknown
}
