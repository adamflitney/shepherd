import Foundation
import Network
import Darwin
import ShepherdHolder

public struct TerminalSpawnRequest: Sendable {
    public var cwd: String
    public var cols: Int
    public var rows: Int
    public var taskID: Int?
    public var title: String?
}

public struct TerminalBridgeConfig: Sendable {
    public var registry: SessionRegistry
    /// Whether a new session may start in this directory (already an absolute, symlink-resolved path that exists).
    public var isDirectoryAllowed: @Sendable (String) -> Bool
    /// Starts a session and returns the id of the holder that owns it. Nil means the bridge cannot start sessions.
    public var spawn: (@Sendable (TerminalSpawnRequest) async throws -> String)?
    /// Bytes queued toward one browser before it is dropped; half of it triggers a resync instead.
    public var maxPending: Int
    public var maxConnections: Int

    public init(registry: SessionRegistry, isDirectoryAllowed: @escaping @Sendable (String) -> Bool = { _ in false },
                spawn: (@Sendable (TerminalSpawnRequest) async throws -> String)? = nil, maxPending: Int = 2 << 20, maxConnections: Int = 64) {
        self.registry = registry; self.isDirectoryAllowed = isDirectoryAllowed; self.spawn = spawn
        self.maxPending = maxPending; self.maxConnections = maxConnections
    }
}

/// Whether a WebSocket upgrade's `Origin` is this server. The server's own gate compares only host names; a terminal
/// that can type into agents also needs the port (another app on another localhost port is the same host) and the
/// scheme's default port when `Host` carries none (behind `tailscale serve`).
func webSocketOriginAllowed(headers: [String: String]) -> Bool {
    guard let origin = headers["origin"] else { return true }   // not a browser
    guard let hostHeader = headers["host"], let url = URL(string: origin), let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https", let originHost = url.host else { return false }
    func normalise(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        return h
    }
    let hostParts = splitHostPort(hostHeader)
    guard normalise(originHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) == normalise(hostParts.host) else { return false }
    let defaultPort = scheme == "https" ? 443 : 80
    return (url.port ?? defaultPort) == (hostParts.port ?? defaultPort)
}

func splitHostPort(_ value: String) -> (host: String, port: Int?) {
    let v = value.trimmingCharacters(in: .whitespaces)
    if v.hasPrefix("["), let close = v.firstIndex(of: "]") {
        let host = String(v[v.index(after: v.startIndex)..<close])
        let rest = v[v.index(after: close)...]
        return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil)
    }
    if let colon = v.lastIndex(of: ":"), v.filter({ $0 == ":" }).count == 1 {
        return (String(v[..<colon]), Int(v[v.index(after: colon)...]))
    }
    return (v, nil)
}

/// Terminals over WebSocket. The app's HTTP server hands a connection here once the upgrade request has passed its
/// access checks; from then on it carries terminal bytes as binary frames and control as JSON text frames:
///   client: `list`, `spawn {cwd, cols, rows, task?, title?}`, `attach {id, cols, rows}`, `detach`, `resize {cols, rows}`
///   server: `hello`, `sessions`, `spawned`, `attached`, `ready`, `size`, `reset`, `detached`, `error`
/// The PTY size follows whoever typed or resized last; a browser that falls behind is resynced (replay and redraw),
/// not buffered without limit.
public final class TerminalBridge: @unchecked Sendable {
    private static let maxFrame = 256 * 1024
    private static let maxControl = 8 * 1024

    private final class SessionState {
        var cols: Int, rows: Int
        var driver: Int?
        var peers = Set<Int>()
        init(cols: Int, rows: Int) { self.cols = cols; self.rows = rows }
    }

    private final class Peer {
        let id: Int
        let conn: NWConnection
        let parser = WSParser(maxPayload: TerminalBridge.maxFrame)
        var frag: (op: UInt8, data: [UInt8])?
        var pending = 0
        var closed = false
        var lastRx = Date(), lastPing = Date()
        var link: HolderLink?
        var sessionID: String?
        var desired: (Int, Int)?
        var inTokens = 512.0 * 1024, inStamp = Date()
        var ctlTokens = 50.0, ctlStamp = Date()
        var ctlErrors = 0
        var pingTokens = 50.0, pingStamp = Date()
        var resyncing = false, resyncSince = Date()
        init(id: Int, conn: NWConnection) { self.id = id; self.conn = conn }
    }

    private let config: TerminalBridgeConfig
    private let q = DispatchQueue(label: "shepherd.terminal-bridge")
    private var peers: [Int: Peer] = [:]
    private var sessions: [String: SessionState] = [:]
    private var nextID = 1
    private var ticking = false

    public init(config: TerminalBridgeConfig) { self.config = config }

    /// Takes over `connection`, whose upgrade request already passed the server's gate. `leftover` is anything the
    /// client sent after the request headers.
    public func adopt(connection: NWConnection, headers: [String: String], leftover: Data) {
        q.async { self.adoptOnQueue(connection, headers, leftover) }
    }

    public func shutdown() {
        q.async {
            for p in Array(self.peers.values) { self.drop(p) }
        }
    }

    public var connectionCount: Int { q.sync { peers.count } }

    // MARK: handshake

    private func adoptOnQueue(_ conn: NWConnection, _ h: [String: String], _ leftover: Data) {
        guard peers.count < config.maxConnections else { conn.cancel(); return }
        guard h["upgrade"]?.lowercased() == "websocket",
              (h["connection"] ?? "").lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }),
              h["sec-websocket-version"] == "13",
              let key = h["sec-websocket-key"], Data(base64Encoded: key)?.count == 16 else {
            return reject(conn, 400, "Bad Request", "bad upgrade", ["Sec-WebSocket-Version": "13"])
        }
        guard webSocketOriginAllowed(headers: h) else { return reject(conn, 403, "Forbidden", "cross-origin") }
        let protocols = (h["sec-websocket-protocol"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard protocols.contains("shepherd-v1") else { return reject(conn, 400, "Bad Request", "unsupported protocol") }

        let p = Peer(id: nextID, conn: conn)
        nextID += 1
        peers[p.id] = p
        conn.stateUpdateHandler = { [weak self, weak p] state in
            switch state {
            case .failed, .cancelled: self?.q.async { if let self, let p { self.drop(p) } }
            default: break
            }
        }
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(webSocketAccept(forKey: key))\r\nSec-WebSocket-Protocol: shepherd-v1\r\n\r\n"
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
        sendJSON(p, ["type": "hello", "you": p.id])
        receiveLoop(p)
        if !leftover.isEmpty { onWS(p, leftover) }
        startTicking()
    }

    private func reject(_ conn: NWConnection, _ status: Int, _ reason: String, _ body: String, _ headers: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        conn.send(content: Data((head + "\r\n" + body).utf8), completion: .contentProcessed { _ in conn.cancel() })
        q.asyncAfter(deadline: .now() + 1) { conn.cancel() }
    }

    // MARK: connection lifecycle

    private func startTicking() {
        guard !ticking else { return }
        ticking = true
        q.asyncAfter(deadline: .now() + 5) { [weak self] in self?.tick() }
    }

    private func tick() {
        let now = Date()
        for p in peers.values where !p.closed {
            if now.timeIntervalSince(p.lastRx) > 90 { drop(p); continue }
            if now.timeIntervalSince(p.lastPing) > 25 { p.lastPing = now; sendWS(p, op: 9, []) }
        }
        if peers.isEmpty { ticking = false; return }
        q.asyncAfter(deadline: .now() + 5) { [weak self] in self?.tick() }
    }

    private func receiveLoop(_ p: Peer) {
        p.conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak p] data, _, isComplete, error in
            self?.q.async {
                guard let self, let p, !p.closed else { return }
                if let data, !data.isEmpty { p.lastRx = Date(); self.onWS(p, data) }
                if p.closed { return }
                if error != nil || isComplete { self.drop(p); return }
                self.receiveLoop(p)
            }
        }
    }

    private func drop(_ p: Peer) {
        if p.closed { return }
        p.closed = true
        p.link?.close(); p.link = nil
        leaveSession(p)
        peers[p.id] = nil
        p.conn.cancel()
    }

    private func leaveSession(_ p: Peer) {
        guard let id = p.sessionID, let st = sessions[id] else { return }
        st.peers.remove(p.id)
        if st.driver == p.id { st.driver = nil }
        if st.peers.isEmpty { sessions[id] = nil }
    }

    private func closeWS(_ p: Peer, _ code: UInt16, _ reason: String) {
        if p.closed { return }
        let d = encodeFrame(op: 8, [UInt8(code >> 8), UInt8(code & 0xff)] + Array(reason.utf8.prefix(100)))
        let c = p.conn
        c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
        q.asyncAfter(deadline: .now() + 1) { c.cancel() }
        p.closed = true   // ignore further input while the close flushes
        p.link?.close(); p.link = nil
        leaveSession(p)
        peers[p.id] = nil
    }

    // MARK: sending

    private func sendWS(_ p: Peer?, op: UInt8, _ payload: [UInt8]) {
        guard let p, !p.closed else { return }
        let d = encodeFrame(op: op, payload)
        let n = d.count
        p.pending += n
        if p.pending > config.maxPending { drop(p); return }
        p.conn.send(content: d, completion: .contentProcessed { [weak self, weak p] _ in self?.q.async { p?.pending -= n } })
    }

    /// Terminal output toward a browser. A client that falls too far behind is not disconnected: its output is stopped,
    /// its holder link closed, and once its socket drains it gets `reset` and a fresh replay and redraw. What it missed
    /// is exactly what a screen snapshot replaces.
    private func sendOutput(_ p: Peer?, _ bytes: [UInt8]) {
        guard let p, !p.closed, !p.resyncing else { return }
        if p.pending + bytes.count > config.maxPending / 2 {
            p.resyncing = true; p.resyncSince = Date()
            p.link?.close(); p.link = nil
            q.asyncAfter(deadline: .now() + 0.1) { [weak self, weak p] in self?.checkResync(p) }
            return
        }
        sendWS(p, op: 2, bytes)
    }

    private func checkResync(_ p: Peer?) {
        guard let p, !p.closed, p.resyncing else { return }
        if Date().timeIntervalSince(p.resyncSince) > 15 { drop(p); return }
        if p.pending < 32 * 1024, let id = p.sessionID {
            p.resyncing = false
            sendJSON(p, ["type": "reset"])
            let d = p.desired ?? (100, 30)
            attach(p, id, d.0, d.1)
            return
        }
        q.asyncAfter(deadline: .now() + 0.1) { [weak self, weak p] in self?.checkResync(p) }
    }

    private func sendJSON(_ p: Peer?, _ o: [String: Any]) { sendWS(p, op: 1, jsonBytes(o)) }

    private func ctlError(_ p: Peer, _ msg: String) {
        sendJSON(p, ["type": "error", "message": msg])
        p.ctlErrors += 1
        if p.ctlErrors > 20 { closeWS(p, 1008, "too many errors") }
    }

    // MARK: incoming frames

    private func onWS(_ p: Peer, _ data: Data) {
        p.parser.feed(data)
        while !p.closed {
            switch p.parser.next() {
            case .need: return
            case .fail(let code, let why): closeWS(p, code, why); return
            case .frame(let f): handleFrame(p, f)
            }
        }
    }

    private func handleFrame(_ p: Peer, _ f: WSFrame) {
        switch f.op {
        case 8: closeWS(p, 1000, "bye")
        case 9:
            if !take(&p.pingTokens, &p.pingStamp, cap: 50, rate: 20, cost: 1) { return closeWS(p, 1008, "ping rate limit") }
            sendWS(p, op: 10, f.payload)
        case 10: break
        default:
            if f.op != 0 {
                if p.frag != nil { return closeWS(p, 1002, "new message inside fragmented message") }
                if f.fin { deliver(p, f.op, f.payload) } else { p.frag = (f.op, f.payload) }
            } else {
                guard var fr = p.frag else { return closeWS(p, 1002, "continuation without start") }
                fr.data.append(contentsOf: f.payload)
                if fr.data.count > Self.maxFrame { return closeWS(p, 1009, "message too large") }
                if f.fin { p.frag = nil; deliver(p, fr.op, fr.data) } else { p.frag = fr }
            }
        }
    }

    private func take(_ tokens: inout Double, _ stamp: inout Date, cap: Double, rate: Double, cost: Double) -> Bool {
        let now = Date()
        tokens = min(cap, tokens + now.timeIntervalSince(stamp) * rate); stamp = now
        if tokens < cost { return false }
        tokens -= cost; return true
    }

    private func deliver(_ p: Peer, _ op: UInt8, _ payload: [UInt8]) {
        if op == 2 {   // terminal input
            if p.resyncing { return }
            guard let link = p.link, let id = p.sessionID, let st = sessions[id] else { return ctlError(p, "not attached") }
            if !take(&p.inTokens, &p.inStamp, cap: 512 * 1024, rate: 256 * 1024, cost: Double(payload.count)) { return closeWS(p, 1008, "input rate limit") }
            if st.driver != p.id {
                st.driver = p.id
                if let d = p.desired { applySize(st, p, d.0, d.1) }
            }
            if !link.sendInput(payload) { closeWS(p, 1011, "holder write failed") }
            return
        }
        if payload.count > Self.maxControl { return closeWS(p, 1009, "control message too large") }
        guard String(data: Data(payload), encoding: .utf8) != nil else { return closeWS(p, 1007, "invalid utf-8") }
        if !take(&p.ctlTokens, &p.ctlStamp, cap: 50, rate: 50, cost: 1) { return closeWS(p, 1008, "control rate limit") }
        guard let msg = (try? JSONSerialization.jsonObject(with: Data(payload))) as? [String: Any], let type = msg["type"] as? String else {
            return ctlError(p, "bad control message")
        }
        control(p, type, msg)
    }

    private func dim(_ v: Any?, _ dflt: Int) -> Int? {
        guard let v else { return dflt }
        guard let n = v as? Int, (1...1000).contains(n) else { return nil }
        return n
    }

    // MARK: control

    private func control(_ p: Peer, _ type: String, _ msg: [String: Any]) {
        switch type {
        case "list":
            let registry = config.registry
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak p] in
                let sessions = registry.all().map { r -> [String: Any] in
                    var d: [String: Any] = ["id": r.id, "agent": r.agent.rawValue, "cwd": r.cwd, "state": r.state.rawValue,
                                            "liveness": "\(registry.liveness(r))", "cols": r.cols, "rows": r.rows,
                                            "startedAt": r.startedAt.timeIntervalSince1970]
                    if let sid = r.claudeSessionID { d["claudeSessionID"] = sid }
                    if let t = r.taskID { d["taskID"] = t }
                    if let title = r.title { d["title"] = title }
                    return d
                }
                self?.q.async { self?.sendJSON(p, ["type": "sessions", "sessions": sessions]) }
            }
        case "spawn":
            guard let spawn = config.spawn else { return ctlError(p, "starting sessions is not available") }
            guard let cols = dim(msg["cols"], 100), let rows = dim(msg["rows"], 30) else { return ctlError(p, "bad size") }
            guard let cwd = msg["cwd"] as? String, allowedDirectory(cwd) else { return ctlError(p, "directory not allowed") }
            let title = (msg["title"] as? String).map { String($0.prefix(200)) }
            let request = TerminalSpawnRequest(cwd: URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path, cols: cols, rows: rows, taskID: msg["task"] as? Int, title: title)
            Task { [weak self, weak p] in
                do {
                    let id = try await spawn(request)
                    self?.q.async { self?.sendJSON(p, ["type": "spawned", "id": id]) }
                } catch {
                    self?.q.async { self?.sendJSON(p, ["type": "error", "message": "could not start the session"]) }
                }
            }
        case "attach":
            guard let id = msg["id"] as? String, id.range(of: "^[a-z0-9-]{1,40}$", options: .regularExpression) != nil else { return ctlError(p, "bad id") }
            guard let cols = dim(msg["cols"], 100), let rows = dim(msg["rows"], 30) else { return ctlError(p, "bad size") }
            attach(p, id, cols, rows)
        case "detach":
            detach(p)
        case "resize":
            guard let cols = dim(msg["cols"], 0), let rows = dim(msg["rows"], 0), cols > 0, rows > 0 else { return ctlError(p, "bad size") }
            p.desired = (cols, rows)
            guard let id = p.sessionID, let st = sessions[id] else { return }
            if st.driver == nil { st.driver = p.id }
            if st.driver == p.id { applySize(st, p, cols, rows) }
        default:
            ctlError(p, "unknown type")
        }
    }

    private func allowedDirectory(_ cwd: String) -> Bool {
        guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd) else { return false }
        return config.isDirectoryAllowed(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path)
    }

    private func applySize(_ st: SessionState, _ p: Peer, _ cols: Int, _ rows: Int) {
        guard cols != st.cols || rows != st.rows else { return }
        _ = p.link?.sendResize(cols, rows)
        st.cols = cols; st.rows = rows
        for id in st.peers { sendJSON(peers[id], ["type": "size", "cols": cols, "rows": rows, "driver": st.driver ?? -1]) }
    }

    private func detach(_ p: Peer) {
        p.link?.close(); p.link = nil
        leaveSession(p)
        p.sessionID = nil
        sendJSON(p, ["type": "detached", "reason": "requested"])
    }

    private final class Box { var replay = 0 }

    /// Re-asserts the modes the program currently has on, ahead of the replay (a wrapped ring has lost the switches).
    private func modePrefix(_ modes: [Int]) -> [UInt8] {
        ModeTracker.restoreSequence(for: modes.sorted { ($0 == 1049 ? 0 : 1, $0) < ($1 == 1049 ? 0 : 1, $1) })
    }

    private func attach(_ p: Peer, _ id: String, _ cols: Int, _ rows: Int) {
        if p.link != nil { return ctlError(p, "already attached") }
        let existing = sessions[id]
        let useC = existing?.cols ?? cols, useR = existing?.rows ?? rows
        guard let link = HolderLink(path: config.registry.socketPath(id), queue: q, oneShot: false) else { return ctlError(p, "session unreachable") }
        p.link = link; p.sessionID = id; p.desired = (cols, rows)
        let box = Box()
        link.onReply = { [weak self, weak p] obj in
            guard let self, let p else { return }
            if obj["ok"] as? Bool == true {
                let st = self.sessions[id] ?? { let s = SessionState(cols: useC, rows: useR); self.sessions[id] = s; return s }()
                st.peers.insert(p.id)
                box.replay = obj["replay"] as? Int ?? 0
                self.sendJSON(p, ["type": "attached", "id": id, "replay": box.replay, "cols": st.cols, "rows": st.rows])
                let prefix = self.modePrefix(obj["modes"] as? [Int] ?? [])
                if !prefix.isEmpty { self.sendWS(p, op: 2, prefix) }
            } else {
                self.ctlError(p, "attach failed")
                p.link = nil; p.sessionID = nil
            }
        }
        link.onBytes = { [weak self, weak p] bytes, _ in self?.sendOutput(p, bytes) }
        link.onReplayDone = { [weak self, weak p, weak link] in
            guard let self, let p else { return }
            self.sendJSON(p, ["type": "ready"])
            // nudge the size so a full-screen app repaints over a possibly truncated replay
            if box.replay > 0, let st = self.sessions[id], st.rows > 2 {
                _ = link?.sendResize(st.cols, st.rows - 1)
                self.q.asyncAfter(deadline: .now() + 0.08) { [weak self, weak link] in
                    if let st = self?.sessions[id] { _ = link?.sendResize(st.cols, st.rows) }
                }
            }
        }
        link.onClose = { [weak self, weak p] in
            guard let self, let p, !p.closed else { return }
            p.link = nil
            self.leaveSession(p)
            p.sessionID = nil
            self.sendJSON(p, ["type": "detached", "reason": "holder closed"])
        }
        link.start(request: ["op": "attach", "cols": useC, "rows": useR])
    }
}
