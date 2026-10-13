import Foundation
import Darwin

final class Session {
    let id: String
    var cmd: String, args: [String], cwd: String
    var claudeSID: String?
    var master: Int32
    var pid: pid_t
    var ring = [UInt8]()
    var cols: UInt16, rows: UInt16
    var exited = false
    var status: Int32 = 0
    var exitedAt: Date?
    init(id: String, cmd: String, args: [String], cwd: String, claudeSID: String?, master: Int32, pid: pid_t, cols: UInt16, rows: UInt16) {
        self.id = id; self.cmd = cmd; self.args = args; self.cwd = cwd; self.claudeSID = claudeSID
        self.master = master; self.pid = pid; self.cols = cols; self.rows = rows
    }
}

final class Conn {
    let fd: Int32
    var inbuf = [UInt8]()
    var attached: String?
    init(fd: Int32) { self.fd = fd }
}

enum Owner { case listener, conn(Conn), master(Session) }

/// Owns PTYs and serves them over a unix socket. In `single` mode it holds exactly one session
/// (the dtach/abduco shape) and exits shortly after that session ends.
final class Holder {
    let home: String, sockPath: String, single: Bool
    var sessions: [String: Session] = [:]
    var conns: [Conn] = []
    var listener: Int32 = -1
    var stopping = false
    let ringMax = 512 * 1024

    init(home: String, sockPath: String, single: Bool) { self.home = home; self.sockPath = sockPath; self.single = single }

    // MARK: registry (one JSON file per session, survives the holder)
    func saveReg(_ s: Session, state: String) {
        let dir = home + "/reg"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var d: [String: Any] = ["id": s.id, "cmd": s.cmd, "args": s.args, "cwd": s.cwd, "cols": Int(s.cols), "rows": Int(s.rows), "state": state, "pid": Int(s.pid)]
        if let c = s.claudeSID { d["claudeSID"] = c }
        try? Data(json(d)).write(to: URL(fileURLWithPath: "\(dir)/\(s.id).json"), options: .atomic)
    }

    // MARK: session lifecycle
    func spawn(_ req: [String: Any]) -> [String: Any] {
        let id = (req["id"] as? String) ?? String(UUID().uuidString.prefix(8)).lowercased()
        guard let cmd = req["cmd"] as? String else { return ["ok": false, "error": "no cmd"] }
        let args = req["args"] as? [String] ?? []
        let cwd = req["cwd"] as? String ?? NSHomeDirectory()
        let cols = UInt16(req["cols"] as? Int ?? 100), rows = UInt16(req["rows"] as? Int ?? 30)
        let env = childEnvironment(req["env"] as? [String: String] ?? [:])
        guard let (master, pid) = spawnPTY(cmd: cmd, args: args, cwd: cwd, env: env, cols: cols, rows: rows) else {
            return ["ok": false, "error": "spawn failed"]
        }
        let s = Session(id: id, cmd: cmd, args: args, cwd: cwd, claudeSID: req["claudeSID"] as? String, master: master, pid: pid, cols: cols, rows: rows)
        sessions[id] = s
        saveReg(s, state: "running")
        log("spawned \(id) pid=\(pid) \(cmd) \(args.joined(separator: " "))")
        return ["ok": true, "id": id, "pid": Int(pid)]
    }

    func markExited(_ s: Session) {
        guard !s.exited else { return }
        var st: Int32 = 0
        var r = waitpid(s.pid, &st, WNOHANG)
        var tries = 0
        while r == 0 && tries < 10 { usleep(50_000); r = waitpid(s.pid, &st, WNOHANG); tries += 1 }
        if r == 0 { kill(s.pid, SIGKILL); waitpid(s.pid, &st, 0) }
        s.exited = true; s.status = st; s.exitedAt = Date()
        close(s.master)
        for c in conns where c.attached == s.id { drop(c) }
        saveReg(s, state: "exited")
        log("session \(s.id) exited status=\(st)")
    }

    func drop(_ c: Conn) {
        close(c.fd)
        conns.removeAll { $0 === c }
    }

    // MARK: requests
    func reply(_ c: Conn, _ d: [String: Any]) { _ = writeAll(c.fd, json(d) + [10]) }

    func handleRequest(_ c: Conn, _ line: [UInt8]) {
        guard let req = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], let op = req["op"] as? String else {
            reply(c, ["ok": false, "error": "bad request"]); drop(c); return
        }
        switch op {
        case "spawn":
            reply(c, spawn(req)); drop(c)
        case "list":
            let list = sessions.values.sorted { $0.id < $1.id }.map { s -> [String: Any] in
                var d: [String: Any] = ["id": s.id, "pid": Int(s.pid), "cwd": s.cwd, "alive": !s.exited, "cols": Int(s.cols), "rows": Int(s.rows), "ring": s.ring.count]
                if let c = s.claudeSID { d["claudeSID"] = c }
                return d
            }
            reply(c, ["ok": true, "sessions": list]); drop(c)
        case "kill":
            if let id = req["id"] as? String, let s = sessions[id] {
                if !s.exited { kill(s.pid, SIGTERM); usleep(200_000); markExited(s) }
                saveReg(s, state: "killed")
                reply(c, ["ok": true])
            } else { reply(c, ["ok": false, "error": "no such session"]) }
            drop(c)
        case "stop":
            reply(c, ["ok": true]); drop(c); stopping = true
        case "dump":
            if let id = req["id"] as? String, let s = sessions[id] {
                reply(c, ["ok": true, "bytes": s.ring.count, "cols": Int(s.cols), "rows": Int(s.rows)])
                _ = writeAll(c.fd, s.ring)
            } else { reply(c, ["ok": false, "error": "no such session"]) }
            drop(c)
        case "attach":
            guard let id = req["id"] as? String, let s = sessions[id], !s.exited else {
                reply(c, ["ok": false, "error": "no such live session"]); drop(c); return
            }
            if let cols = req["cols"] as? Int, let rows = req["rows"] as? Int { resize(s, UInt16(cols), UInt16(rows)) }
            reply(c, ["ok": true, "replay": s.ring.count])
            _ = writeAll(c.fd, s.ring)
            c.attached = id
        default:
            reply(c, ["ok": false, "error": "unknown op"]); drop(c)
        }
    }

    func resize(_ s: Session, _ cols: UInt16, _ rows: UInt16) {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        ioctl(s.master, TIOCSWINSZ, &ws)
        s.cols = cols; s.rows = rows
    }

    func handleFrames(_ c: Conn) {
        while let id = c.attached, let s = sessions[id], c.inbuf.count >= 5 {
            let type = c.inbuf[0]
            let len = Int(c.inbuf[1]) << 24 | Int(c.inbuf[2]) << 16 | Int(c.inbuf[3]) << 8 | Int(c.inbuf[4])
            guard c.inbuf.count >= 5 + len else { return }
            let payload = Array(c.inbuf[5..<(5 + len)])
            c.inbuf.removeFirst(5 + len)
            switch type {
            case 0: if !s.exited { _ = writeAll(s.master, payload) }
            case 1: if payload.count == 4 { resize(s, UInt16(payload[0]) << 8 | UInt16(payload[1]), UInt16(payload[2]) << 8 | UInt16(payload[3])) }
            case 2: drop(c); return
            default: break
            }
        }
    }

    func connReadable(_ c: Conn) {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(c.fd, &buf, buf.count)
        if n <= 0 { drop(c); return }
        c.inbuf += buf[0..<n]
        if c.attached == nil, let nl = c.inbuf.firstIndex(of: 10) {
            let line = Array(c.inbuf[0..<nl])
            c.inbuf.removeFirst(nl + 1)
            handleRequest(c, line)
        }
        if c.attached != nil { handleFrames(c) }
    }

    func masterReadable(_ s: Session) {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(s.master, &buf, buf.count)
        if n <= 0 { markExited(s); return }
        let chunk = Array(buf[0..<n])
        s.ring += chunk
        if s.ring.count > ringMax { s.ring.removeFirst(s.ring.count - ringMax) }
        for c in conns where c.attached == s.id { if !writeAll(c.fd, chunk) { drop(c) } }
    }

    // MARK: loop
    func run() {
        signal(SIGPIPE, SIG_IGN)
        guard let l = listenUnix(sockPath) else { log("cannot listen on \(sockPath)"); exit(1) }
        listener = l
        log("listening on \(sockPath) single=\(single)")
        while !stopping {
            var pfds = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0)]
            var owners: [Owner] = [.listener]
            for c in conns { pfds.append(pollfd(fd: c.fd, events: Int16(POLLIN), revents: 0)); owners.append(.conn(c)) }
            for s in sessions.values where !s.exited { pfds.append(pollfd(fd: s.master, events: Int16(POLLIN), revents: 0)); owners.append(.master(s)) }
            _ = poll(&pfds, nfds_t(pfds.count), 500)
            for (i, p) in pfds.enumerated() where p.revents != 0 {
                switch owners[i] {
                case .listener:
                    let fd = accept(listener, nil, nil)
                    if fd >= 0 { fcntl(fd, F_SETFD, FD_CLOEXEC); conns.append(Conn(fd: fd)) }
                case .conn(let c): if conns.contains(where: { $0 === c }) { connReadable(c) }
                case .master(let s): if !s.exited { masterReadable(s) }
                }
            }
            for s in sessions.values where !s.exited {
                var st: Int32 = 0
                if waitpid(s.pid, &st, WNOHANG) == s.pid { s.exited = false; markExitedWith(s, st) }
            }
            if single, !sessions.isEmpty, sessions.values.allSatisfy({ $0.exited }), conns.isEmpty,
               sessions.values.allSatisfy({ Date().timeIntervalSince($0.exitedAt ?? Date()) > 2 }) { break }
        }
        unlink(sockPath)
        log("holder exiting")
    }

    func markExitedWith(_ s: Session, _ st: Int32) {
        s.exited = true; s.status = st; s.exitedAt = Date()
        close(s.master)
        for c in conns where c.attached == s.id { drop(c) }
        saveReg(s, state: "exited")
        log("session \(s.id) reaped status=\(st)")
    }
}
