import Foundation
import Darwin

struct Opts {
    var pos: [String] = []
    var val: [String: String] = [:]
    var rest: [String] = []   // after "--"
    var multi: [String: [String]] = [:]
}

func parseOpts(_ a: [String]) -> Opts {
    var o = Opts()
    var i = 0
    while i < a.count {
        if a[i] == "--" { o.rest = Array(a[(i + 1)...]); break }
        if a[i].hasPrefix("--") {
            let k = String(a[i].dropFirst(2))
            if k == "seq" {   // consumes everything up to the next --flag
                i += 1
                while i < a.count, !a[i].hasPrefix("--") { o.multi["seq", default: []].append(a[i]); i += 1 }
                continue
            }
            if i + 1 < a.count, !a[i + 1].hasPrefix("--") { o.val[k] = a[i + 1]; i += 2 } else { o.val[k] = "1"; i += 1 }
        } else { o.pos.append(a[i]); i += 1 }
    }
    return o
}

func readLine(_ fd: Int32, leftover: inout [UInt8]) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        if let nl = leftover.firstIndex(of: 10) {
            let line = Array(leftover[0..<nl]); leftover.removeFirst(nl + 1); return line
        }
        let n = read(fd, &buf, buf.count)
        if n <= 0 { return nil }
        leftover += buf[0..<n]
    }
}

func unescape(_ s: String) -> [UInt8] {
    var out = [UInt8](); var it = Array(s.utf8).makeIterator()
    while let b = it.next() {
        if b == 92, let n = it.next() {
            switch n {
            case UInt8(ascii: "r"): out.append(13)
            case UInt8(ascii: "n"): out.append(10)
            case UInt8(ascii: "e"): out.append(27)
            case UInt8(ascii: "t"): out.append(9)
            case UInt8(ascii: "c"): out.append(3)   // \c = ctrl-c
            case UInt8(ascii: "\\"): out.append(92)
            default: out.append(b); out.append(n)
            }
        } else { out.append(b) }
    }
    return out
}

final class Target {
    let home: String, mode: String
    init(_ o: Opts) { home = o.val["home"] ?? ""; mode = o.val["mode"] ?? "daemon" }
    func sock(for id: String?) -> String { mode == "daemon" ? home + "/ptyd.sock" : home + "/s/\(id ?? "").sock" }
    func request(_ id: String?, _ d: [String: Any]) -> (reply: [String: Any], fd: Int32, left: [UInt8])? {
        guard let fd = connectUnix(sock(for: id)) else { return nil }
        _ = writeAll(fd, json(d) + [10])
        var left = [UInt8]()
        guard let line = readLine(fd, leftover: &left),
              let r = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { close(fd); return nil }
        return (r, fd, left)
    }
    func liveIDs() -> [String] {
        if mode == "daemon" {
            guard let r = request(nil, ["op": "list"]) else { return [] }
            close(r.fd)
            return (r.reply["sessions"] as? [[String: Any]] ?? []).filter { $0["alive"] as? Bool == true }.compactMap { $0["id"] as? String }
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: home + "/s")) ?? []
        return files.filter { $0.hasSuffix(".sock") }.map { String($0.dropLast(5)) }.filter {
            if let fd = connectUnix(sock(for: $0)) { close(fd); return true }; return false
        }
    }
}

func detachedSpawn(_ exe: String, _ args: [String], log logPath: String) -> Bool {
    var fa: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fa, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&fa, 1, 2)
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var cargs: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, exe, &fa, &attr, cargs, environ)
    cargs.forEach { free($0) }
    return rc == 0
}

func selfPath() -> String {
    var buf = [CChar](repeating: 0, count: 4096); var size = UInt32(buf.count)
    _NSGetExecutablePath(&buf, &size)
    return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
}

let claudePath = NSHomeDirectory() + "/.local/bin/claude"

func clientMain(_ o: Opts) {
    let t = Target(o)
    guard let op = o.pos.first else { print("usage: ptyd c <spawn|list|kill|stop|dump|drive|restore|start-daemon> ..."); return }
    switch op {
    case "start-daemon":
        try? FileManager.default.createDirectory(atPath: t.home + "/log", withIntermediateDirectories: true)
        _ = detachedSpawn(selfPath(), ["daemon", "--home", t.home], log: t.home + "/log/daemon.log")
        for _ in 0..<50 { if connectUnix(t.sock(for: nil)).map({ close($0); return true }) == true { print("daemon up"); return }; usleep(100_000) }
        print("daemon did not come up")
    case "spawn":
        var cmd = o.rest.first ?? ""
        var args = Array(o.rest.dropFirst())
        if o.val["claude"] != nil { args = o.rest }
        var claudeSID: String?
        if o.val["claude"] != nil {
            cmd = claudePath
            claudeSID = o.val["sid"] ?? UUID().uuidString.lowercased()
            args = [o.val["resume"] != nil ? "--resume" : "--session-id", claudeSID!] + (o.val["model"].map { ["--model", $0] } ?? []) + args
        }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        var req: [String: Any] = ["op": "spawn", "id": id, "cmd": cmd, "args": args, "cwd": o.val["cwd"] ?? NSHomeDirectory(),
                                  "cols": Int(o.val["cols"] ?? "100")!, "rows": Int(o.val["rows"] ?? "30")!]
        if let c = claudeSID { req["claudeSID"] = c }
        if t.mode == "daemon" {
            guard let r = t.request(nil, req) else { print("cannot reach daemon"); exit(1) }
            close(r.fd); print(r.reply["ok"] as? Bool == true ? id : "error: \(r.reply)")
        } else {
            try? FileManager.default.createDirectory(atPath: t.home + "/s", withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: t.home + "/log", withIntermediateDirectories: true)
            var a = ["hold", "--home", t.home, "--id", id, "--cwd", req["cwd"] as! String, "--cols", "\(req["cols"]!)", "--rows", "\(req["rows"]!)"]
            if let c = claudeSID { a += ["--claude-sid", c] }
            a += ["--", cmd] + args
            _ = detachedSpawn(selfPath(), a, log: t.home + "/log/\(id).log")
            for _ in 0..<50 { if connectUnix(t.sock(for: id)).map({ close($0); return true }) == true { print(id); return }; usleep(100_000) }
            print("holder did not come up")
        }
    case "list":
        if t.mode == "daemon" {
            guard let r = t.request(nil, ["op": "list"]) else { print("no daemon"); return }
            close(r.fd)
            for s in r.reply["sessions"] as? [[String: Any]] ?? [] { print(s) }
        } else {
            for id in t.liveIDs() { print("live holder:", id) }
        }
    case "kill":
        let id = o.pos[1]
        if let r = t.request(id, ["op": "kill", "id": id]) { close(r.fd); print(r.reply) } else { print("unreachable") }
    case "stop":
        if let r = t.request(nil, ["op": "stop"]) { close(r.fd); print(r.reply) } else { print("no daemon") }
    case "dump":
        let id = o.pos[1]
        guard let r = t.request(id, ["op": "dump", "id": id]), let n = r.reply["bytes"] as? Int else { print("dump failed"); exit(1) }
        var data = r.left
        var buf = [UInt8](repeating: 0, count: 65536)
        while data.count < n { let k = read(r.fd, &buf, buf.count); if k <= 0 { break }; data += buf[0..<k] }
        close(r.fd)
        FileHandle.standardOutput.write(Data(data))
    case "drive":
        let id = o.pos[1]
        let cols = Int(o.val["cols"] ?? "100")!, rows = Int(o.val["rows"] ?? "30")!
        guard let r = t.request(id, ["op": "attach", "id": id, "cols": cols, "rows": rows]), r.reply["ok"] as? Bool == true else { print("attach failed"); exit(1) }
        let fd = r.fd
        let outPath = o.val["out"]
        var all = r.left
        func pump(_ ms: Int) {
            let end = Date().addingTimeInterval(Double(ms) / 1000)
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let left = Int32(max(0, end.timeIntervalSinceNow * 1000))
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&p, 1, left) <= 0 { return }
                let n = read(fd, &buf, buf.count)
                if n <= 0 { print("\n[connection closed by holder]"); return }
                all += buf[0..<n]
            }
        }
        pump(Int(o.val["settle"] ?? "300")!)
        func frame(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
            let n = payload.count
            return [type, UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)] + payload
        }
        for step in o.multi["seq"] ?? [] {
            if step.hasPrefix("send:") { _ = writeAll(fd, frame(0, unescape(String(step.dropFirst(5))))) }
            else if step.hasPrefix("wait:") { pump(Int(String(step.dropFirst(5)))!) }
            else if step.hasPrefix("resize:") {
                let p = step.dropFirst(7).split(separator: "x").map { Int($0)! }
                _ = writeAll(fd, frame(1, [UInt8(p[0] >> 8), UInt8(p[0] & 255), UInt8(p[1] >> 8), UInt8(p[1] & 255)]))
            }
        }
        if let outPath { try? Data(all).write(to: URL(fileURLWithPath: outPath)) }
        FileHandle.standardOutput.write(Data(all))
        // exiting without a detach frame = a client that vanished
        if o.val["detach"] != nil { _ = writeAll(fd, frame(2, [])) }
        close(fd)
    case "restore":
        let live = Set(t.liveIDs())
        let files = (try? FileManager.default.contentsOfDirectory(atPath: t.home + "/reg")) ?? []
        for f in files.sorted() where f.hasSuffix(".json") {
            guard let d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: t.home + "/reg/" + f)))) as? [String: Any],
                  let id = d["id"] as? String, !live.contains(id), d["state"] as? String == "running", let sid = d["claudeSID"] as? String else { continue }
            let cwd = d["cwd"] as? String ?? NSHomeDirectory()
            print("restoring \(id) -> claude --resume \(sid)")
            var a = ["c", "spawn", "--home", t.home, "--mode", t.mode, "--cwd", cwd, "--cols", "\(d["cols"] ?? 100)", "--rows", "\(d["rows"] ?? 30)", "--sid", sid, "--resume", "1", "--claude", "1"]
            a += o.rest.isEmpty ? [] : ["--"] + o.rest
            let me = Process(); me.executableURL = URL(fileURLWithPath: selfPath()); me.arguments = a
            try? me.run(); me.waitUntilExit()
        }
    default: print("unknown client op")
    }
}
