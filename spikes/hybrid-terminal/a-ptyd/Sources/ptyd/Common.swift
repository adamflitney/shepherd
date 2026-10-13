import Foundation
import Darwin

func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    while off < bytes.count {
        let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN { usleep(1000); continue }
            return false
        }
        off += n
    }
    return true
}

// sun_path is 104 bytes on macOS; long paths are reached by chdir'ing next to the socket.
private func withSocketPath<T>(_ path: String, _ body: (sockaddr_un) -> T) -> T {
    let url = URL(fileURLWithPath: path)
    let old = FileManager.default.currentDirectoryPath
    FileManager.default.changeCurrentDirectoryPath(url.deletingLastPathComponent().path)
    defer { FileManager.default.changeCurrentDirectoryPath(old) }
    var a = sockaddr_un()
    a.sun_family = sa_family_t(AF_UNIX)
    let name = url.lastPathComponent
    let cap = MemoryLayout.size(ofValue: a.sun_path)
    name.withCString { src in
        withUnsafeMutablePointer(to: &a.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: cap) { dst in _ = strncpy(dst, src, cap - 1) }
        }
    }
    return body(a)
}

func listenUnix(_ path: String) -> Int32? {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    fcntl(fd, F_SETFD, FD_CLOEXEC)
    let ok: Bool = withSocketPath(path) { addr in
        var a = addr
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        return r == 0
    }
    guard ok, listen(fd, 16) == 0 else { close(fd); return nil }
    chmod(path, 0o600)
    return fd
}

func connectUnix(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    fcntl(fd, F_SETFD, FD_CLOEXEC)
    let ok: Bool = withSocketPath(path) { addr in
        var a = addr
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        return r == 0
    }
    if !ok { close(fd); return nil }
    return fd
}

func log(_ s: String) {
    FileHandle.standardError.write(Data("[\(ProcessInfo.processInfo.processIdentifier)] \(s)\n".utf8))
}

func json(_ o: Any) -> [UInt8] {
    (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])).map { Array($0) } ?? []
}

func childEnvironment(_ extra: [String: String]) -> [String: String] {
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE_CODE") && $0.key != "CLAUDECODE" }
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    for (k, v) in extra { env[k] = v }
    return env
}

/// Spawns `cmd` on a fresh PTY as a session leader whose controlling tty is the slave.
func spawnPTY(cmd: String, args: [String], cwd: String, env: [String: String], cols: UInt16, rows: UInt16) -> (master: Int32, pid: pid_t)? {
    var master: Int32 = -1, slave: Int32 = -1
    var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
    guard openpty(&master, &slave, nil, nil, &ws) == 0 else { return nil }
    fcntl(master, F_SETFD, FD_CLOEXEC)
    var name = [CChar](repeating: 0, count: 128)
    ttyname_r(slave, &name, 128)

    var fa: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_addchdir_np(&fa, cwd)
    posix_spawn_file_actions_addopen(&fa, 0, String(cString: name), O_RDWR, 0)
    posix_spawn_file_actions_adddup2(&fa, 0, 1)
    posix_spawn_file_actions_adddup2(&fa, 0, 2)
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

    var cargs: [UnsafeMutablePointer<CChar>?] = ([cmd] + args).map { strdup($0) } + [nil]
    var cenv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, cmd, &fa, &attr, cargs, cenv)
    close(slave)
    cargs.forEach { free($0) }; cenv.forEach { free($0) }
    guard rc == 0 else { close(master); log("posix_spawn failed rc=\(rc) cmd=\(cmd)"); return nil }
    return (master, pid)
}
