import Foundation
import Network
import Darwin

enum Cfg {
    nonisolated(unsafe) static var port: UInt16 = 18750
    nonisolated(unsafe) static var holderSock = ""
    nonisolated(unsafe) static var token = ""
    nonisolated(unsafe) static var allowHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]"]
    nonisolated(unsafe) static var allowCwds: [String] = []
    nonisolated(unsafe) static var allowShell = false
    nonisolated(unsafe) static var owner: String?
    nonisolated(unsafe) static var webDir: String?
    nonisolated(unsafe) static var maxPending = 2 << 20
    static let maxHeader = 16 * 1024
    static let maxFrame = 256 * 1024
    static let maxControl = 8 * 1024
    static let maxConns = 64
    static let handshakeTimeout = 5.0
}

let q = DispatchQueue(label: "bridge")

final class SessionState {
    var cols: Int, rows: Int
    var driver: Int?
    var peers = Set<Int>()
    init(cols: Int, rows: Int) { self.cols = cols; self.rows = rows }
}

final class Peer {
    enum Phase { case http, ws }
    let id: Int
    let conn: NWConnection
    var phase = Phase.http
    var inbuf = Data()
    let parser = WSParser(maxPayload: Cfg.maxFrame)
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

struct Stats { var resyncs = 0, accepted = 0, rejectedHTTP = 0, upgraded = 0, wsClosedProtocol = 0, slowDrops = 0, rateDrops = 0 }

final class Server {
    let listener: NWListener
    var peers: [Int: Peer] = [:]
    var sessions: [String: SessionState] = [:]
    var nextID = 1
    var stats = Stats()
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Cfg.port)!)
        listener = try NWListener(using: params)
    }

    func start() {
        listener.newConnectionHandler = { [unowned self] conn in
            if peers.count >= Cfg.maxConns { conn.cancel(); return }
            let p = Peer(id: nextID, conn: conn); nextID += 1
            peers[p.id] = p; stats.accepted += 1
            conn.stateUpdateHandler = { [weak self, weak p] st in
                if case .failed = st, let self, let p { self.drop(p) }
                if case .cancelled = st, let self, let p { self.drop(p) }
            }
            conn.start(queue: q)
            // a client that never finishes its HTTP request is cut off
            q.asyncAfter(deadline: .now() + Cfg.handshakeTimeout) { [weak self, weak p] in
                if let self, let p, p.phase == .http, !p.closed { self.respond(p, 408, "Request Timeout", "timeout") }
            }
            receiveLoop(p)
        }
        listener.stateUpdateHandler = { log("listener \($0)") }
        listener.start(queue: q)
        q.asyncAfter(deadline: .now() + 5) { [unowned self] in tick() }
    }

    func tick() {
        let now = Date()
        for p in peers.values where p.phase == .ws && !p.closed {
            if now.timeIntervalSince(p.lastRx) > 90 { drop(p); continue }
            if now.timeIntervalSince(p.lastPing) > 25 { p.lastPing = now; sendWS(p, op: 9, []) }
        }
        q.asyncAfter(deadline: .now() + 5) { [unowned self] in tick() }
    }

    func receiveLoop(_ p: Peer) {
        p.conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak p] data, _, isComplete, error in
            guard let self, let p, !p.closed else { return }
            if let data, !data.isEmpty { p.lastRx = Date(); self.onData(p, data) }
            if p.closed { return }
            if error != nil || isComplete { self.drop(p); return }
            self.receiveLoop(p)
        }
    }

    func drop(_ p: Peer) {
        if p.closed { return }
        p.closed = true
        p.link?.close(); p.link = nil
        if let id = p.sessionID, let st = sessions[id] {
            st.peers.remove(p.id)
            if st.driver == p.id { st.driver = nil }
        }
        peers[p.id] = nil
        p.conn.cancel()
    }

    // MARK: HTTP

    func respond(_ p: Peer, _ status: Int, _ reason: String, _ body: String, type: String = "text/plain", headers: [String: String] = [:]) {
        if p.closed { return }
        stats.rejectedHTTP += status >= 400 ? 1 : 0
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        p.closed = true // stop reading; cancel once flushed
        peers[p.id] = nil
        p.link?.close()
        // strong capture on purpose: the Peer is already out of `peers`, and a weak capture would be nil by the
        // time the send completes, leaving the NWConnection open (a leaked socket per rejected request)
        let c = p.conn
        c.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in c.cancel() })
        q.asyncAfter(deadline: .now() + 1) { c.cancel() }
    }

    func onData(_ p: Peer, _ data: Data) {
        if p.phase == .ws { onWS(p, data); return }
        p.inbuf.append(data)
        guard let end = p.inbuf.range(of: Data("\r\n\r\n".utf8)) else {
            if p.inbuf.count > Cfg.maxHeader { respond(p, 431, "Request Header Fields Too Large", "headers too large") }
            return
        }
        if end.lowerBound > Cfg.maxHeader { respond(p, 431, "Request Header Fields Too Large", "headers too large"); return }
        let head = String(decoding: p.inbuf[..<end.lowerBound], as: UTF8.self)
        let rest = Array(p.inbuf[end.upperBound...])
        p.inbuf = Data()
        handleHTTP(p, head, rest)
    }

    func handleHTTP(_ p: Peer, _ head: String, _ rest: [UInt8]) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1", parts[1].count <= 2048, parts[1].hasPrefix("/") else {
            return respond(p, 400, "Bad Request", "bad request line")
        }
        var h: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let c = line.firstIndex(of: ":") else { return respond(p, 400, "Bad Request", "bad header") }
            let k = line[..<c].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            if k.isEmpty || line.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\t" }) { return respond(p, 400, "Bad Request", "bad header") }
            if ["host", "origin", "content-length", "sec-websocket-key", "sec-websocket-protocol", "authorization"].contains(k), h[k] != nil {
                return respond(p, 400, "Bad Request", "duplicate header")
            }
            h[k] = v
        }
        if h["transfer-encoding"] != nil || (h["content-length"].map { $0 != "0" } ?? false) { return respond(p, 400, "Bad Request", "request bodies are not supported") }
        guard parts[0] == "GET" else { return respond(p, 405, "Method Not Allowed", "GET only") }
        if let deny = gate(h) { return respond(p, 403, "Forbidden", deny) }

        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        let query = target.contains("?") ? String(target.split(separator: "?", maxSplits: 1)[1]) : ""
        switch path {
        case "/":
            if let r = staticFile("index.html") { respond(p, 200, "OK", r.body, type: r.type) }
            else { respond(p, 200, "OK", "<!doctype html><title>bridge spike</title><p>HTTP and WebSocket share this port.", type: "text/html") }
        case _ where path.hasPrefix("/vendor/"):
            if let r = staticFile("vendor/" + String(path.dropFirst(8))) { respond(p, 200, "OK", r.body, type: r.type) }
            else { respond(p, 404, "Not Found", "not found") }
        case "/api/sessions":
            guard let auth = h["authorization"], auth.hasPrefix("Bearer "), constantTimeEqual(String(auth.dropFirst(7)), Cfg.token) else {
                return respond(p, 401, "Unauthorized", "unauthorized")
            }
            holderOneShot(["op": "list"]) { [weak self, weak p] reply in
                guard let self, let p else { return }
                self.respond(p, 200, "OK", String(decoding: jsonBytes(reply), as: UTF8.self), type: "application/json")
            }
        case "/ws":
            upgrade(p, h, query: query, rest: rest)
        default:
            respond(p, 404, "Not Found", "not found")
        }
    }

    /// Phone-test pages: only plain file names directly under the web dir or its vendor/ folder.
    func staticFile(_ rel: String) -> (body: String, type: String)? {
        guard let dir = Cfg.webDir else { return nil }
        let comps = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(comps.count), comps.dropLast().allSatisfy({ $0 == "vendor" }),
              let name = comps.last, name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil, !name.hasPrefix(".") else { return nil }
        let path = dir + "/" + rel
        guard let body = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let type = name.hasSuffix(".html") ? "text/html; charset=utf-8" : name.hasSuffix(".js") ? "text/javascript; charset=utf-8" : name.hasSuffix(".css") ? "text/css; charset=utf-8" : "text/plain"
        return (body, type)
    }

    /// Host / Origin / Sec-Fetch-Site / Tailscale identity checks (same rules as ShepherdWebKit's AccessPolicy).
    func gate(_ h: [String: String]) -> String? {
        guard let host = h["host"].flatMap(hostname(fromHostHeader:)) else { return "missing host" }
        guard Cfg.allowHosts.contains(host) else { return "unexpected host" }
        if h["tailscale-funnel-request"] != nil { return "funnel not allowed" }
        if let login = h["tailscale-user-login"] {
            guard let owner = Cfg.owner, login.caseInsensitiveCompare(owner) == .orderedSame else { return "not the owner" }
        } else if h["x-forwarded-for"] != nil { return "proxy request without identity" }
        if let site = h["sec-fetch-site"], site != "same-origin", site != "none" { return "cross-site" }
        if let origin = h["origin"] {
            guard let u = URL(string: origin), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let oh = u.host.flatMap({ hostname(fromHostHeader: $0.contains(":") ? "[\($0)]" : $0) }), oh == host else { return "cross-origin" }
            let defaultPort = scheme == "https" ? 443 : 80
            let originPort = u.port ?? defaultPort
            // Host without a port (e.g. behind `tailscale serve`) means the scheme's default port
            let hostPort = hostPortNumber(h["host"] ?? "") ?? defaultPort
            if originPort != hostPort { return "cross-origin (port)" }
        }
        return nil
    }

    func hostPortNumber(_ hostHeader: String) -> Int? {
        let v = hostHeader.trimmingCharacters(in: .whitespaces)
        let tail = v.hasPrefix("[") ? v.split(separator: "]", maxSplits: 1).dropFirst().first.map(String.init) ?? "" : (v.contains(":") ? ":" + (v.split(separator: ":").last.map(String.init) ?? "") : "")
        guard tail.hasPrefix(":") else { return nil }
        return Int(tail.dropFirst())
    }

    func upgrade(_ p: Peer, _ h: [String: String], query: String, rest: [UInt8]) {
        guard h["upgrade"]?.lowercased() == "websocket",
              (h["connection"] ?? "").lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }),
              h["sec-websocket-version"] == "13",
              let key = h["sec-websocket-key"], Data(base64Encoded: key)?.count == 16 else {
            return respond(p, 400, "Bad Request", "bad upgrade", headers: ["Sec-WebSocket-Version": "13"])
        }
        let protos = (h["sec-websocket-protocol"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard protos.contains("shepherd-v1"),
              let tok = protos.first(where: { $0.hasPrefix("token.") }),
              constantTimeEqual(String(tok.dropFirst(6)), Cfg.token) else {
            return respond(p, 401, "Unauthorized", "unauthorized")
        }
        let accept = sha1Base64(key + Self.guid)
        p.phase = .ws; stats.upgraded += 1
        p.lastRx = Date()
        let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\nSec-WebSocket-Protocol: shepherd-v1\r\n\r\n"
        p.conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
        sendJSON(p, ["type": "hello", "you": p.id])
        if !rest.isEmpty { onWS(p, Data(rest)) }
    }

    // MARK: WebSocket

    func sendWS(_ p: Peer?, op: UInt8, _ payload: [UInt8]) {
        guard let p, !p.closed, p.phase == .ws else { return }
        let d = encodeFrame(op: op, payload)
        let n = d.count
        p.pending += n
        if p.pending > Cfg.maxPending {
            log("peer \(p.id) too slow (\(p.pending) bytes unsent), dropping")
            stats.slowDrops += 1
            drop(p); return
        }
        p.conn.send(content: d, completion: .contentProcessed { [weak p] _ in p?.pending -= n })
    }

    /// Terminal output toward a browser. A client that falls too far behind is not disconnected: its output is
    /// stopped, its holder link closed, and once its socket drains it gets `reset` + a fresh replay and redraw.
    /// What it missed is exactly what a screen snapshot replaces, so nothing is lost that matters.
    func sendOutput(_ p: Peer?, _ bytes: [UInt8]) {
        guard let p, !p.closed, p.phase == .ws, !p.resyncing else { return }
        if p.pending + bytes.count > Cfg.maxPending / 2 {
            p.resyncing = true; p.resyncSince = Date(); stats.resyncs += 1
            p.link?.close(); p.link = nil
            q.asyncAfter(deadline: .now() + 0.1) { [weak self, weak p] in self?.checkResync(p) }
            return
        }
        sendWS(p, op: 2, bytes)
    }

    func checkResync(_ p: Peer?) {
        guard let p, !p.closed, p.resyncing else { return }
        if Date().timeIntervalSince(p.resyncSince) > 15 { log("peer \(p.id) stalled for 15 s during resync, dropping"); stats.slowDrops += 1; drop(p); return }
        if p.pending < 32 * 1024, let id = p.sessionID {
            p.resyncing = false
            sendJSON(p, ["type": "reset"])
            let d = p.desired ?? (100, 30)
            attach(p, id, d.0, d.1)
            return
        }
        q.asyncAfter(deadline: .now() + 0.1) { [weak self, weak p] in self?.checkResync(p) }
    }

    func sendJSON(_ p: Peer?, _ o: [String: Any]) { sendWS(p, op: 1, jsonBytes(o)) }
    func ctlError(_ p: Peer, _ msg: String) {
        sendJSON(p, ["type": "error", "message": msg])
        p.ctlErrors += 1
        if p.ctlErrors > 20 { closeWS(p, 1008, "too many errors") }
    }

    func closeWS(_ p: Peer, _ code: UInt16, _ reason: String) {
        if p.closed { return }
        if p.phase == .ws {
            stats.wsClosedProtocol += (code == 1000 ? 0 : 1)
            let d = encodeFrame(op: 8, [UInt8(code >> 8), UInt8(code & 0xff)] + Array(reason.utf8.prefix(100)))
            let c = p.conn
            c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
            q.asyncAfter(deadline: .now() + 1) { c.cancel() }
            p.closed = true  // ignore any further input while the close flushes
            p.link?.close(); p.link = nil
            peers[p.id] = nil
            if let id = p.sessionID, let st = sessions[id] { st.peers.remove(p.id); if st.driver == p.id { st.driver = nil } }
        } else { drop(p) }
    }

    func onWS(_ p: Peer, _ data: Data) {
        p.parser.feed(data)
        while !p.closed {
            switch p.parser.next() {
            case .need: return
            case .fail(let code, let why): closeWS(p, code, why); return
            case .frame(let f): handleFrame(p, f)
            }
        }
    }

    func handleFrame(_ p: Peer, _ f: WSFrame) {
        switch f.op {
        case 8: closeWS(p, 1000, "bye")
        case 9:
            if !take(&p.pingTokens, &p.pingStamp, cap: 50, rate: 20, cost: 1) { stats.rateDrops += 1; return closeWS(p, 1008, "ping rate limit") }
            sendWS(p, op: 10, f.payload)
        case 10: break
        default:
            if f.op != 0 {
                if p.frag != nil { return closeWS(p, 1002, "new message inside fragmented message") }
                if f.fin { deliver(p, f.op, f.payload) } else { p.frag = (f.op, f.payload) }
            } else {
                guard var fr = p.frag else { return closeWS(p, 1002, "continuation without start") }
                fr.data.append(contentsOf: f.payload)
                if fr.data.count > Cfg.maxFrame { return closeWS(p, 1009, "message too large") }
                if f.fin { p.frag = nil; deliver(p, fr.op, fr.data) } else { p.frag = fr }
            }
        }
    }

    func take(_ tokens: inout Double, _ stamp: inout Date, cap: Double, rate: Double, cost: Double) -> Bool {
        let now = Date()
        tokens = min(cap, tokens + now.timeIntervalSince(stamp) * rate); stamp = now
        if tokens < cost { return false }
        tokens -= cost; return true
    }

    func deliver(_ p: Peer, _ op: UInt8, _ payload: [UInt8]) {
        if op == 2 { // terminal input
            if p.resyncing { return }
            guard let link = p.link, let id = p.sessionID, let st = sessions[id] else { return ctlError(p, "not attached") }
            if !take(&p.inTokens, &p.inStamp, cap: 512 * 1024, rate: 256 * 1024, cost: Double(payload.count)) {
                stats.rateDrops += 1; return closeWS(p, 1008, "input rate limit")
            }
            if st.driver != p.id {
                st.driver = p.id
                if let d = p.desired { applySize(st, p, d.0, d.1) }
            }
            if !link.sendInput(payload) { closeWS(p, 1011, "holder write failed") }
            return
        }
        if payload.count > Cfg.maxControl { return closeWS(p, 1009, "control message too large") }
        guard String(data: Data(payload), encoding: .utf8) != nil else { return closeWS(p, 1007, "invalid utf-8") }
        if !take(&p.ctlTokens, &p.ctlStamp, cap: 50, rate: 50, cost: 1) { stats.rateDrops += 1; return closeWS(p, 1008, "control rate limit") }
        guard let msg = (try? JSONSerialization.jsonObject(with: Data(payload))) as? [String: Any], let type = msg["type"] as? String else {
            return ctlError(p, "bad control message")
        }
        control(p, type, msg)
    }

    func dim(_ v: Any?, _ dflt: Int) -> Int? {
        guard let v else { return dflt }
        guard let n = v as? Int, (1...1000).contains(n) else { return nil }
        return n
    }

    func control(_ p: Peer, _ type: String, _ msg: [String: Any]) {
        switch type {
        case "list":
            holderOneShot(["op": "list"]) { [weak self, weak p] r in self?.sendJSON(p, ["type": "sessions", "sessions": r["sessions"] ?? []]) }
        case "spawn":
            guard let cols = dim(msg["cols"], 100), let rows = dim(msg["rows"], 30) else { return ctlError(p, "bad size") }
            guard let cwd = msg["cwd"] as? String, allowedCwd(cwd) else { return ctlError(p, "cwd not allowed") }
            var req: [String: Any] = ["op": "spawn", "cwd": cwd, "cols": cols, "rows": rows]
            switch msg["kind"] as? String {
            case "claude":
                let claude = NSHomeDirectory() + "/.local/bin/claude"
                guard FileManager.default.isExecutableFile(atPath: claude) else { return ctlError(p, "claude not found") }
                let sid = UUID().uuidString.lowercased()
                req["cmd"] = "/bin/sh"; req["args"] = ["-c", "\(claude) --session-id \(sid); exit $?"]; req["claudeSID"] = sid
            case "shell":
                guard Cfg.allowShell, let script = msg["script"] as? String, script.utf8.count <= 4096 else { return ctlError(p, "shell not allowed") }
                req["cmd"] = "/bin/sh"; req["args"] = ["-c", script]
            default: return ctlError(p, "unknown kind")
            }
            holderOneShot(req) { [weak self, weak p] r in
                if r["ok"] as? Bool == true { self?.sendJSON(p, ["type": "spawned", "id": r["id"] ?? ""]) }
                else { self?.sendJSON(p, ["type": "error", "message": "spawn failed"]) }
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

    func allowedCwd(_ cwd: String) -> Bool {
        guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd) else { return false }
        let real = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        return Cfg.allowCwds.contains { real == $0 || real.hasPrefix($0 + "/") }
    }

    func applySize(_ st: SessionState, _ p: Peer, _ cols: Int, _ rows: Int) {
        guard cols != st.cols || rows != st.rows else { return }
        _ = p.link?.sendResize(cols, rows)
        st.cols = cols; st.rows = rows
        for id in st.peers { sendJSON(peers[id], ["type": "size", "cols": cols, "rows": rows, "driver": st.driver ?? -1]) }
    }

    func detach(_ p: Peer) {
        p.link?.close(); p.link = nil
        if let id = p.sessionID, let st = sessions[id] { st.peers.remove(p.id); if st.driver == p.id { st.driver = nil } }
        p.sessionID = nil
        sendJSON(p, ["type": "detached", "reason": "requested"])
    }

    final class Box { var replay = 0 }

    /// Re-asserts the modes the program currently has on, ahead of the replay (a wrapped ring has lost the switches).
    func modePrefix(_ modes: [Int]) -> [UInt8] {
        var out = [UInt8]()
        for m in modes.sorted(by: { ($0 == 1049 ? 0 : 1, $0) < ($1 == 1049 ? 0 : 1, $1) }) { out += Array("\u{1b}[?\(m)h".utf8) }
        return out
    }

    func attach(_ p: Peer, _ id: String, _ cols: Int, _ rows: Int) {
        if p.link != nil { return ctlError(p, "already attached") }
        let existing = sessions[id]
        let useC = existing?.cols ?? cols, useR = existing?.rows ?? rows
        guard let link = HolderLink(path: Cfg.holderSock, queue: q, oneShot: false) else { return ctlError(p, "holder unreachable") }
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
                q.asyncAfter(deadline: .now() + 0.08) { [weak self, weak link] in
                    if let st = self?.sessions[id] { _ = link?.sendResize(st.cols, st.rows) }
                }
            }
        }
        link.onClose = { [weak self, weak p] in
            guard let self, let p, !p.closed else { return }
            p.link = nil
            if let sid = p.sessionID, let st = self.sessions[sid] { st.peers.remove(p.id) }
            p.sessionID = nil
            self.sendJSON(p, ["type": "detached", "reason": "holder closed"])
        }
        link.start(request: ["op": "attach", "id": id, "cols": useC, "rows": useR])
    }

    func holderOneShot(_ req: [String: Any], _ done: @escaping ([String: Any]) -> Void) {
        guard let link = HolderLink(path: Cfg.holderSock, queue: q, oneShot: true) else { return done(["ok": false, "error": "holder unreachable"]) }
        var finished = false
        link.onReply = { r in finished = true; done(r) }
        link.onClose = { if !finished { done(["ok": false, "error": "holder closed"]) } }
        link.start(request: req)
    }
}
