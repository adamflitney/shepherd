import Foundation
import ShepherdCore

/// Turns Herdr wire observations into `BackendEvent`s, with the dedupe
/// contract that makes the `pane.updated` firehose tolerable: an observation
/// that doesn't change the resulting `Session` value produces no event at
/// all. Shell panes (no `agent`) never become sessions.
public struct HerdrRoute: Equatable, Sendable {
    public let paneID: String
    public let workspaceID: String
}

public struct SessionProjection {
    private var identity = IdentityResolver()
    private var lastEmitted: [SessionID: Session] = [:]
    private var groupsByWorkspaceID: [String: SessionGroup] = [:]
    /// Backend-specific routing, kept private to this adapter and never
    /// surfaced on `Session` itself - fixes unstable pane ids for free, since
    /// ids stay durable while routes are refreshed on every observation.
    private var routesByID: [SessionID: HerdrRoute] = [:]

    public init() {}

    public func route(for id: SessionID) -> HerdrRoute? {
        routesByID[id]
    }

    /// `hookStates` is keyed by the agent's own session UUID (`agent_session.value`),
    /// matching how `~/.shepherd/state/<uuid>.json` files are named - not by
    /// our internal `SessionID`, which may carry a `"agent:"` prefix or be
    /// provisional. Reading these files is `HerdrSessionBackend`'s job; this
    /// stays a pure function taking already-parsed data.
    public mutating func applySnapshot(
        _ snapshot: SessionSnapshotWire,
        hookStates: [String: ParsedHookState] = [:],
        seedAttention: [SessionID: PersistedSessionAttention] = [:],
        now: Date = Date()
    ) -> SessionsSnapshot {
        groupsByWorkspaceID = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map {
            ($0.workspaceID, SessionGroup(id: $0.workspaceID, label: $0.label, ordinal: $0.number))
        })

        let previouslyEmitted = lastEmitted
        lastEmitted = [:]
        routesByID = [:]
        var sessions: [Session] = []
        for pane in snapshot.panes where pane.agent != nil {
            let resolution = identity.resolve(paneID: pane.paneID, agentSession: pane.agentSession)
            let hookState = pane.agentSession.flatMap { hookStates[$0.value] }
            let session = makeSession(
                from: pane,
                id: resolution.id,
                hookState: hookState,
                previous: previouslyEmitted[resolution.id],
                seed: seedAttention[resolution.id],
                now: now
            )
            sessions.append(session)
            lastEmitted[session.id] = session
            routesByID[session.id] = HerdrRoute(paneID: pane.paneID, workspaceID: pane.workspaceID)
        }

        return SessionsSnapshot(sessions: sessions, groups: Array(groupsByWorkspaceID.values))
    }

    /// The current `since` per session, keyed for `AttentionSinceStore` to
    /// persist - so the next app launch can seed `applySnapshot` above and
    /// avoid every session's recency collapsing to the restart time.
    public func currentPersistedAttention() -> [SessionID: PersistedSessionAttention] {
        Dictionary(uniqueKeysWithValues: lastEmitted.compactMap { id, session in
            session.attention.since.map { (id, PersistedSessionAttention(kind: session.attention.kind.rawValue, since: $0)) }
        })
    }

    /// Applies one `pane_updated` (or equivalent) observation.
    public mutating func applyPaneObservation(_ pane: PaneWire, hookState: ParsedHookState? = nil, now: Date = Date()) -> [BackendEvent] {
        guard pane.agent != nil else { return [] }

        let resolution = identity.resolve(paneID: pane.paneID, agentSession: pane.agentSession)
        let session = makeSession(from: pane, id: resolution.id, hookState: hookState, previous: lastEmitted[resolution.id], seed: nil, now: now)

        var events: [BackendEvent] = []
        if let previousProvisionalID = resolution.previousProvisionalID {
            lastEmitted.removeValue(forKey: previousProvisionalID)
            routesByID.removeValue(forKey: previousProvisionalID)
            events.append(.sessionRemoved(previousProvisionalID))
        }
        // The route is refreshed on every observation regardless of dedupe -
        // it must always be current even when the Session value didn't change.
        routesByID[session.id] = HerdrRoute(paneID: pane.paneID, workspaceID: pane.workspaceID)
        if lastEmitted[session.id] != session {
            lastEmitted[session.id] = session
            events.append(.sessionChanged(session))
        }
        return events
    }

    public mutating func applyPaneClosed(paneID: String) -> [BackendEvent] {
        let resolution = identity.resolve(paneID: paneID, agentSession: nil)
        guard lastEmitted.removeValue(forKey: resolution.id) != nil else { return [] }
        routesByID.removeValue(forKey: resolution.id)
        return [.sessionRemoved(resolution.id)]
    }

    private func makeSession(from pane: PaneWire, id: SessionID, hookState: ParsedHookState?, previous: Session?, seed: PersistedSessionAttention?, now: Date) -> Session {
        var attention = reconcileAttention(herdrKind: mapHerdrAgentStatus(pane.agentStatus), hookState: hookState)
        // `since` tracks when this session most recently *entered* its
        // current attention kind - carried forward while the kind is
        // unchanged, reset to `now` on any transition. This is what lets the
        // UI order same-kind sessions (idle in particular) by recency.
        //
        // `previous` only exists once this process has already observed the
        // session at least once - on a fresh app launch it's always nil, so
        // `seed` (loaded from `AttentionSinceStore`) fills that gap for the
        // very first observation, as long as the persisted kind still
        // matches (a stale kind's timestamp isn't a real transition time).
        if let previous {
            attention.since = previous.attention.kind == attention.kind ? previous.attention.since : now
        } else if let seed, seed.kind == attention.kind.rawValue {
            attention.since = seed.since
        } else {
            attention.since = now
        }
        return Session(
            id: id,
            title: pane.terminalTitleStripped ?? pane.title ?? id.rawValue,
            agent: AgentKind(rawValue: pane.agent ?? "unknown"),
            workingDirectory: (pane.foregroundCwd ?? pane.cwd).map { URL(fileURLWithPath: $0) },
            attention: attention,
            isFocused: pane.focused,
            group: groupsByWorkspaceID[pane.workspaceID],
            capabilities: [.focus, .close, .prompt]
        )
    }
}
