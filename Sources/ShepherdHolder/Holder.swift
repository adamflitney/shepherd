import Foundation
import Darwin

public struct HolderConfig: @unchecked Sendable {
    public var record: SessionRecord
    public var env: [String: String]
    public var registry: SessionRegistry
    public var ringBytes: Int
    /// How long the holder lingers after its session ends, so a client that is attached can finish reading.
    public var exitGrace: TimeInterval
    public var maxClients: Int

    public init(record: SessionRecord, env: [String: String] = [:], registry: SessionRegistry,
                ringBytes: Int = 512 * 1024, exitGrace: TimeInterval = 2, maxClients: Int = 16) {
        self.record = record; self.env = env; self.registry = registry
        self.ringBytes = ringBytes; self.exitGrace = exitGrace; self.maxClients = maxClients
    }
}

/// Owns one PTY running one agent and serves it over a unix socket (the dtach shape). It outlives the app, exits
/// shortly after its session ends, and keeps its record in the registry current. All state lives on the thread that
/// calls `run()`; only `stop()` may be called from elsewhere.
public final class Holder: @unchecked Sendable {
    private final class Conn {
        let fd: Int32
        let opened = Date()
        var inbuf: [UInt8] = []
        var parser = HolderFrameParser()
        var attached = false
        init(fd: Int32) { self.fd = fd }
    }

    private let config: HolderConfig
    private var record: SessionRecord
    private var child: PTYChild?
    private var ring: RingBuffer
    private var modes = ModeTracker()
    private var conns: [Conn] = []
    private var listener: Int32 = -1
    private var ended = false
    private var endedAt: Date?
    private let stopLock = NSLock()
    private var stopRequested = false

    public init(config: HolderConfig) {
        self.config = config
        self.record = config.record
        self.ring = RingBuffer(capacity: config.ringBytes)
    }

    public func stop() {
        stopLock.lock(); stopRequested = true; stopLock.unlock()
    }

    private var shouldStop: Bool {
        stopLock.lock(); defer { stopLock.unlock() }
        return stopRequested
    }

    /// Runs until the session has ended and the grace period is over. Returns the final record.
    @discardableResult
    public func run() -> SessionRecord {
        signal(SIGPIPE, SIG_IGN)
        try? config.registry.prepare()
        let socketPath = config.registry.socketPath(record.id)
        guard let l = listenUnix(socketPath) else { return fail("cannot listen on \(socketPath)") }
        listener = l
        defer { close(listener); unlink(socketPath) }

        guard let spawned = spawnPTY(argv: record.argv, cwd: record.cwd, env: childEnvironment(config.env),
                                     cols: UInt16(clamping: record.cols), rows: UInt16(clamping: record.rows)) else {
            return fail("could not start \(record.argv.first ?? "nothing")")
        }
        child = spawned
        _ = fcntl(spawned.master, F_SETFL, fcntl(spawned.master, F_GETFL) | O_NONBLOCK)
        record.holderPID = getpid()
        record.childPID = spawned.pid
        persist()
        logLine("holding \(record.id) pid=\(spawned.pid) \(record.argv.joined(separator: " "))")

        while true {
            if shouldStop && !ended { terminate(state: .killed) }
            if ended, conns.isEmpty, Date().timeIntervalSince(endedAt ?? Date()) > config.exitGrace { break }
            if ended, Date().timeIntervalSince(endedAt ?? Date()) > config.exitGrace * 5 { break }
            poll()
        }
        for c in conns { close(c.fd) }
        conns.removeAll()
        logLine("holder exiting \(record.id) state=\(record.state.rawValue)")
        return record
    }

    // MARK: loop

    private func poll() {
        var pfds = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0)]
        let connsAtPoll = conns
        for c in connsAtPoll { pfds.append(pollfd(fd: c.fd, events: Int16(POLLIN), revents: 0)) }
        let masterIndex: Int?
        if !ended, let child {
            masterIndex = pfds.count
            pfds.append(pollfd(fd: child.master, events: Int16(POLLIN), revents: 0))
        } else { masterIndex = nil }
        _ = Darwin.poll(&pfds, nfds_t(pfds.count), 250)

        if pfds[0].revents != 0 { acceptClient() }
        for (i, c) in connsAtPoll.enumerated() where pfds[i + 1].revents != 0 && conns.contains(where: { $0 === c }) { clientReadable(c) }
        if let masterIndex, pfds[masterIndex].revents != 0, !ended { masterReadable() }
        if !ended, let child {
            var status: Int32 = 0
            if waitpid(child.pid, &status, WNOHANG) == child.pid { finish(state: .exited, status: status) }
        }
        let now = Date()
        for c in conns where !c.attached && now.timeIntervalSince(c.opened) > 5 { drop(c) }
    }

    private func acceptClient() {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        guard conns.count < config.maxClients else { close(fd); return }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        conns.append(Conn(fd: fd))
    }

    private func drop(_ c: Conn) {
        close(c.fd)
        conns.removeAll { $0 === c }
    }

    private func masterReadable() {
        if !pumpMaster() { finish(state: .exited, status: nil) }
    }

    /// Reads what the session has written and hands it to the ring and the attached clients. False at end of output.
    /// Must keep running while the holder waits for the session to exit: a process that is closing its terminal waits
    /// for unread output to drain, so a holder that stops reading can never see it finish.
    @discardableResult
    private func pumpMaster() -> Bool {
        guard let child else { return false }
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(child.master, &buf, buf.count)
        if n < 0, errno == EAGAIN || errno == EINTR { return true }
        if n <= 0 { return false }
        let chunk = Array(buf[0..<n])
        modes.feed(chunk)
        ring.append(chunk)
        for c in conns where c.attached {
            if !writeBounded(c.fd, chunk) { logLine("dropping a stalled client on \(record.id)"); drop(c) }
        }
        return true
    }

    /// Waits up to `seconds` for the child to exit while draining its output. Returns its status once reaped.
    private func waitForExit(seconds: Double) -> Int32? {
        guard let child else { return nil }
        let deadline = Date().addingTimeInterval(seconds)
        var status: Int32 = 0
        while true {
            if waitpid(child.pid, &status, WNOHANG) == child.pid { return status }
            if Date() >= deadline { return nil }
            var p = pollfd(fd: child.master, events: Int16(POLLIN), revents: 0)
            if Darwin.poll(&p, 1, 50) > 0, p.revents & Int16(POLLIN) != 0 { pumpMaster() }
        }
    }

    private func clientReadable(_ c: Conn) {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(c.fd, &buf, buf.count)
        if n < 0, errno == EAGAIN || errno == EINTR { return }
        if n <= 0 { drop(c); return }
        if c.attached {
            for frame in c.parser.push(Array(buf[0..<n])) {
                switch frame {
                case .input(let bytes): if let child, !ended { _ = writeBounded(child.master, bytes) }
                case .resize(let cols, let rows): resize(cols: cols, rows: rows)
                case .detach: drop(c); return
                }
            }
            if c.parser.failed { drop(c) }
            return
        }
        c.inbuf += buf[0..<n]
        if c.inbuf.count > 64 * 1024 { drop(c); return }
        if let newline = c.inbuf.firstIndex(of: 10) {
            let line = Array(c.inbuf[0..<newline])
            let rest = Array(c.inbuf[(newline + 1)...])
            c.inbuf = []
            handleRequest(c, line)
            if c.attached, !rest.isEmpty, conns.contains(where: { $0 === c }) {
                for frame in c.parser.push(rest) { if case .detach = frame { drop(c); return } else { apply(frame) } }
            }
        }
    }

    private func apply(_ frame: HolderFrame) {
        switch frame {
        case .input(let bytes): if let child, !ended { _ = writeBounded(child.master, bytes) }
        case .resize(let cols, let rows): resize(cols: cols, rows: rows)
        case .detach: break
        }
    }

    // MARK: requests

    private func reply(_ c: Conn, _ object: [String: Any]) { _ = writeBounded(c.fd, jsonBytes(object) + [10], budgetMs: 1000) }

    private func info() -> [String: Any] {
        var d: [String: Any] = ["ok": true, "id": record.id, "alive": !ended, "cols": record.cols, "rows": record.rows,
                                "ring": ring.count, "modes": modes.activeModes, "state": record.state.rawValue]
        if let pid = record.childPID { d["pid"] = Int(pid) }
        if let sid = record.claudeSessionID { d["claudeSessionID"] = sid }
        if let status = record.exitStatus { d["exitStatus"] = Int(status) }
        return d
    }

    private func handleRequest(_ c: Conn, _ line: [UInt8]) {
        guard let request = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], let op = request["op"] as? String else {
            reply(c, ["ok": false, "error": "bad request"]); drop(c); return
        }
        switch op {
        case "info":
            reply(c, info()); drop(c)
        case "kill":
            if !ended { terminate(state: .killed) }
            reply(c, ["ok": true]); drop(c)
        case "dump":
            reply(c, ["ok": true, "bytes": ring.count, "cols": record.cols, "rows": record.rows])
            _ = writeBounded(c.fd, ring.bytes, budgetMs: 2000)
            drop(c)
        case "attach":
            guard !ended else { reply(c, ["ok": false, "error": "session has ended"]); drop(c); return }
            if let cols = request["cols"] as? Int, let rows = request["rows"] as? Int, (1...1000).contains(cols), (1...1000).contains(rows) {
                resize(cols: UInt16(cols), rows: UInt16(rows))
            }
            reply(c, ["ok": true, "replay": ring.count, "modes": modes.activeModes, "cols": record.cols, "rows": record.rows])
            if !writeBounded(c.fd, ring.bytes, budgetMs: 2000) { drop(c); return }
            c.attached = true
        default:
            reply(c, ["ok": false, "error": "unknown op"]); drop(c)
        }
    }

    private func resize(cols: UInt16, rows: UInt16) {
        guard let child, !ended, cols > 0, rows > 0 else { return }
        let changed = Int(cols) != record.cols || Int(rows) != record.rows
        setWindowSize(child.master, cols: cols, rows: rows)
        record.cols = Int(cols); record.rows = Int(rows)
        // The child has no controlling terminal (the slave is opened before the new session exists), so the kernel never
        // sends it SIGWINCH.
        if changed { killpg(child.pid, SIGWINCH) }
    }

    // MARK: lifecycle

    /// Ends the session the way closing a terminal would: hang up the foreground group, then force it.
    private func terminate(state: SessionRecord.State) {
        guard let child, !ended else { return }
        kill(-child.pid, SIGTERM)
        var status = waitForExit(seconds: 1.5)
        if status == nil {
            kill(-child.pid, SIGKILL)
            status = waitForExit(seconds: 2)
        }
        if status == nil { logLine("session \(record.id) did not exit after SIGKILL; giving up on it") }
        finish(state: state, status: status)
    }

    private func finish(state: SessionRecord.State, status: Int32?) {
        guard !ended, let child else { return }
        var code = status
        if code == nil {
            code = waitForExit(seconds: 1)
            if code == nil {
                kill(child.pid, SIGKILL)
                code = waitForExit(seconds: 2)
            }
        }
        ended = true
        endedAt = Date()
        close(child.master)
        for c in conns where c.attached { drop(c) }
        record.state = state
        record.endedAt = endedAt
        record.exitStatus = code.map(decodeExitStatus)
        persist()
        logLine("session \(record.id) ended state=\(state.rawValue) status=\(record.exitStatus.map(String.init) ?? "?")")
    }

    private func fail(_ message: String) -> SessionRecord {
        logLine(message)
        record.state = .failed
        record.error = message
        record.endedAt = Date()
        persist()
        return record
    }

    private func persist() {
        do { try config.registry.save(record) } catch { logLine("could not write the record: \(error)") }
    }
}
