import Foundation
import ShepherdCore

/// The Herdr-socket implementation of `SessionBackend`. Owns two kinds of
/// connection per the plan's verified constraints: one-shot `RequestClient`
/// calls for everything except events, and one persistent `EventStreamTransport`
/// connection that this actor reconnects with backoff, re-snapshotting on
/// every (re)connect since Herdr has no event replay.
public actor HerdrSessionBackend: SessionBackend {
    private let requestClient: RequestClient
    private let eventTransport: any EventStreamTransport
    private var terminalActivator: any TerminalActivator
    private let hookStateStore: HookStateStore
    private let attentionSinceStore: AttentionSinceStore
    private let reconnectDelayNanoseconds: UInt64
    private let periodicResyncDelayNanoseconds: UInt64

    private var projection = SessionProjection()
    private let hub = BackendEventHub()
    private var listenTask: Task<Void, Never>?
    private var periodicResyncTask: Task<Void, Never>?
    /// Loaded once and consumed by the first `applySnapshot` call only -
    /// every call after that has real `previous` values from this same
    /// process, so the persisted seed is no longer relevant.
    private var pendingSeedAttention: [SessionID: PersistedSessionAttention]?

    public init(
        requestClient: RequestClient,
        eventTransport: any EventStreamTransport,
        terminalActivator: any TerminalActivator = NoOpTerminalActivator(),
        hookStateStore: HookStateStore = HookStateStore(),
        attentionSinceStore: AttentionSinceStore = AttentionSinceStore(),
        reconnectDelayNanoseconds: UInt64 = 1_000_000_000,
        periodicResyncDelayNanoseconds: UInt64 = 60_000_000_000
    ) {
        self.requestClient = requestClient
        self.eventTransport = eventTransport
        self.terminalActivator = terminalActivator
        self.hookStateStore = hookStateStore
        self.attentionSinceStore = attentionSinceStore
        self.reconnectDelayNanoseconds = reconnectDelayNanoseconds
        self.periodicResyncDelayNanoseconds = periodicResyncDelayNanoseconds
        self.pendingSeedAttention = attentionSinceStore.load()
    }

    public nonisolated func events() -> AsyncStream<BackendEvent> {
        hub.makeStream()
    }

    /// Lets the picked terminal be changed live (the menu bar's "Terminal"
    /// submenu) without tearing down and rebuilding the whole backend.
    public func setTerminalActivator(_ activator: any TerminalActivator) {
        terminalActivator = activator
    }

    public func snapshot() async throws -> SessionsSnapshot {
        let result = try await requestClient.call(
            method: "session.snapshot", params: EmptyParams(), resultType: SessionSnapshotResultWire.self
        )
        let seed = pendingSeedAttention ?? [:]
        pendingSeedAttention = nil
        let snapshot = projection.applySnapshot(result.snapshot, hookStates: hookStateStore.allStates(), seedAttention: seed)
        attentionSinceStore.save(projection.currentPersistedAttention())
        return snapshot
    }

    /// Starts the persistent event connection. Subscribes to the
    /// `pane.updated` firehose (with `SessionProjection` deduping) rather
    /// than the precise per-pane `pane.agent_status_changed` subscription -
    /// that subscription's positive delivery wasn't confirmed against a real
    /// transition (see the plan's Phase 2 step 8 note), so this ships on the
    /// proven path.
    public func startListening() {
        guard listenTask == nil else { return }
        listenTask = Task { [weak self] in
            await self?.listenLoop()
        }
        periodicResyncTask = Task { [weak self] in
            await self?.periodicResyncLoop()
        }
    }

    public func stopListening() {
        listenTask?.cancel()
        listenTask = nil
        periodicResyncTask?.cancel()
        periodicResyncTask = nil
    }

    /// Defense-in-depth against a missed event on the live `pane.updated`
    /// firehose: the only other correction is a full re-snapshot on
    /// reconnect, so a single dropped frame (a network hiccup, a Herdr
    /// server restart that doesn't cleanly close the old socket) would
    /// otherwise leave a ghost or stale session in the store forever,
    /// invisible to anything short of an app restart - this is exactly what
    /// a user hit after several hours of uptime. `SessionsStore.apply` fully
    /// replaces its session dictionary on every `.snapshot`, so this is a
    /// self-correcting no-op whenever nothing actually drifted.
    private func periodicResyncLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: periodicResyncDelayNanoseconds)
            if Task.isCancelled { break }
            if let snapshot = try? await snapshot() {
                hub.broadcast(.snapshot(snapshot))
            }
        }
    }

    public func focus(_ id: SessionID) async throws {
        guard let route = projection.route(for: id) else { throw BackendError.unknownSession(id) }
        _ = try await requestClient.call(
            method: "workspace.focus",
            params: WorkspaceTargetParams(workspaceID: route.workspaceID),
            resultType: IgnoredResult.self
        )
        await terminalActivator.activate()
    }

    public func createSession(_ request: CreateSessionRequest) async throws -> SessionID {
        let created = try await requestClient.call(
            method: "workspace.create",
            params: WorkspaceCreateParams(cwd: request.workingDirectory.path, label: request.title, focus: false),
            resultType: WorkspaceCreatedResultWire.self
        )
        let paneID = created.rootPane.paneID
        // `--resume <id>` continues an existing `claude` CLI conversation
        // (the inline quick-answer panel's "move to a session" action) -
        // mutually exclusive with `initialPrompt` below, since a resumed
        // session already has that context.
        let args = request.resumeSessionID.map { ["--resume", $0] } ?? []
        _ = try await requestClient.call(
            method: "agent.start",
            params: AgentStartParamsWire(name: uniqueAgentName(kind: request.agent.rawValue), kind: request.agent.rawValue, paneID: paneID, args: args),
            resultType: AgentStartedResultWire.self
        )

        // `agent.start`'s own response is too early to trust for identity or
        // readiness - `agent_session` frequently isn't populated yet, and
        // the agent hasn't actually booted (still "unknown"). `agent.wait`
        // blocks until it reaches a real status.
        var settled = try await waitForSettledStatus(paneID: paneID)

        // A brand-new pane's very first "blocked" status is Claude Code's
        // own one-time folder-trust prompt ("Yes, I trust this folder" is
        // the second option, hence down+enter), not a real blocker - dismiss
        // it and wait again for the agent to actually finish booting.
        if settled.agentStatus == "blocked" {
            _ = try await requestClient.call(
                method: "agent.send_keys",
                params: AgentSendKeysParamsWire(target: paneID, keys: ["down", "enter"]),
                resultType: IgnoredResult.self
            )
            settled = try await waitForSettledStatus(paneID: paneID, until: ["idle", "working", "done"])
        }

        let hookState = settled.agentSession.flatMap { hookStateStore.state(forSessionUUID: $0.value) }
        let events = projection.applyPaneObservation(settled, hookState: hookState)
        for event in events { hub.broadcast(event) }

        let sessionID: SessionID
        if case .sessionChanged(let session) = events.last {
            sessionID = session.id
        } else {
            sessionID = SessionID(rawValue: "pane:\(paneID)")
        }

        if request.resumeSessionID == nil, let initialPrompt = request.initialPrompt {
            _ = try await requestClient.call(
                method: "agent.prompt",
                params: AgentPromptParams(target: paneID, text: initialPrompt),
                resultType: IgnoredResult.self
            )
        }

        return sessionID
    }

    /// `agent.wait`'s result shape ({type, agent}) matches `agent.start`'s
    /// exactly, so `AgentStartedResultWire` doubles as its decode target.
    private func waitForSettledStatus(
        paneID: String,
        until: [String] = ["idle", "working", "blocked", "done"],
        timeoutMS: Int = 20_000
    ) async throws -> PaneWire {
        let result = try await requestClient.call(
            method: "agent.wait",
            params: AgentWaitParamsWire(target: paneID, until: until, timeoutMS: timeoutMS),
            resultType: AgentStartedResultWire.self
        )
        return result.agent
    }

    public func close(_ id: SessionID) async throws {
        guard let route = projection.route(for: id) else { throw BackendError.unknownSession(id) }
        _ = try await requestClient.call(
            method: "pane.close",
            params: PaneTargetParams(paneID: route.paneID),
            resultType: IgnoredResult.self
        )
    }

    public func prompt(_ id: SessionID, text: String) async throws {
        guard let route = projection.route(for: id) else { throw BackendError.unknownSession(id) }
        _ = try await requestClient.call(
            method: "agent.prompt",
            params: AgentPromptParams(target: route.paneID, text: text),
            resultType: IgnoredResult.self
        )
    }

    public func peek(_ id: SessionID) async throws -> String {
        guard let route = projection.route(for: id) else { throw BackendError.unknownSession(id) }
        let result = try await requestClient.call(
            method: "pane.read",
            params: PaneReadParamsWire(paneID: route.paneID, source: "visible"),
            resultType: PaneReadResultWire.self
        )
        return result.text
    }

    // MARK: - Event connection

    private func listenLoop() async {
        while !Task.isCancelled {
            hub.broadcast(.connection(.connecting))

            let subscribeLine: Data
            do {
                subscribeLine = try HerdrWire.encodeRequest(
                    id: "sub",
                    method: "events.subscribe",
                    params: SubscribeParams(subscriptions: [
                        .init(type: "pane.updated"),
                        .init(type: "pane.closed"),
                    ])
                )
            } catch {
                hub.broadcast(.connection(.unavailable(reason: "\(error)")))
                try? await Task.sleep(nanoseconds: reconnectDelayNanoseconds)
                continue
            }

            let frames = eventTransport.subscribe(subscribeLine)

            if let snapshot = try? await snapshot() {
                hub.broadcast(.connection(.connected))
                hub.broadcast(.snapshot(snapshot))
            } else {
                hub.broadcast(.connection(.unavailable(reason: "snapshot failed")))
                try? await Task.sleep(nanoseconds: reconnectDelayNanoseconds)
                continue
            }

            for await frame in frames {
                handle(frame: frame)
            }

            if Task.isCancelled { break }
            hub.broadcast(.connection(.unavailable(reason: "connection dropped")))
            try? await Task.sleep(nanoseconds: reconnectDelayNanoseconds)
        }
    }

    private func handle(frame: Data) {
        guard case .event(let type) = HerdrWire.classify(frame) else { return }
        switch type {
        case "pane_updated":
            guard let payload = try? HerdrWire.decodeEventData(PaneUpdatedEventDataWire.self, from: frame) else { return }
            let hookState = payload.pane.agentSession.flatMap { hookStateStore.state(forSessionUUID: $0.value) }
            let events = projection.applyPaneObservation(payload.pane, hookState: hookState)
            for event in events {
                hub.broadcast(event)
            }
            if !events.isEmpty { attentionSinceStore.save(projection.currentPersistedAttention()) }
        case "pane_closed":
            guard let payload = try? HerdrWire.decodeEventData(PaneClosedEventDataWire.self, from: frame) else { return }
            let events = projection.applyPaneClosed(paneID: payload.paneID)
            for event in events {
                hub.broadcast(event)
            }
            if !events.isEmpty { attentionSinceStore.save(projection.currentPersistedAttention()) }
        default:
            break
        }
    }
}

/// Herdr's `agent.start` requires a globally-unique `name` - confirmed
/// live: reusing an agent's *kind* as its name (e.g. always `"claude"`)
/// collided with any other Claude agent already running anywhere in
/// Herdr, throwing `agent_name_taken` after `workspace.create` had
/// already succeeded - leaving exactly the empty, agent-less workspace a
/// user hit. Also confirmed live: the name must start with a lowercase
/// letter and contain only lowercase letters/digits/`-`/`_`, 1-32 chars
/// (`invalid_agent_name` otherwise).
func uniqueAgentName(kind: String) -> String {
    let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
    return "\(kind.lowercased())-\(suffix)"
}

private struct WorkspaceTargetParams: Encodable {
    let workspaceID: String
    enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" }
}

private struct PaneTargetParams: Encodable {
    let paneID: String
    enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
}

private struct WorkspaceCreateParams: Encodable {
    let cwd: String?
    let label: String?
    let focus: Bool
}

private struct AgentStartParamsWire: Encodable {
    let name: String
    let kind: String
    let paneID: String
    let args: [String]
    enum CodingKeys: String, CodingKey { case name, kind, paneID = "pane_id", args }
}

private struct AgentPromptParams: Encodable {
    let target: String
    let text: String
}

private struct AgentWaitParamsWire: Encodable {
    let target: String
    let until: [String]
    let timeoutMS: Int
    enum CodingKeys: String, CodingKey { case target, until, timeoutMS = "timeout_ms" }
}

private struct AgentSendKeysParamsWire: Encodable {
    let target: String
    let keys: [String]
}

private struct PaneReadParamsWire: Encodable {
    let paneID: String
    let source: String
    enum CodingKeys: String, CodingKey { case paneID = "pane_id", source }
}

private struct PaneReadResultWire: Decodable {
    let text: String
}

private struct SubscribeParams: Encodable {
    struct Subscription: Encodable { let type: String }
    let subscriptions: [Subscription]
}
