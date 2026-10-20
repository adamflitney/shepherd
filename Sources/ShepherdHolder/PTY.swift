import Foundation
import Darwin

/// A child running on a fresh pseudo-terminal as a session leader, so the slave is its controlling tty.
struct PTYChild {
    let master: Int32
    let pid: pid_t
}

func childEnvironment(_ extra: [String: String]) -> [String: String] {
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE_CODE") && $0.key != "CLAUDECODE" }
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    for (key, value) in extra { env[key] = value }
    return env
}

func spawnPTY(argv: [String], cwd: String, env: [String: String], cols: UInt16, rows: UInt16) -> PTYChild? {
    guard let command = argv.first else { return nil }
    var master: Int32 = -1, slave: Int32 = -1
    var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
    guard openpty(&master, &slave, nil, nil, &size) == 0 else { return nil }
    _ = fcntl(master, F_SETFD, FD_CLOEXEC)
    var name = [CChar](repeating: 0, count: 128)
    ttyname_r(slave, &name, 128)

    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addchdir_np(&actions, cwd)
    posix_spawn_file_actions_addopen(&actions, 0, String(cString: name), O_RDWR, 0)
    posix_spawn_file_actions_adddup2(&actions, 0, 1)
    posix_spawn_file_actions_adddup2(&actions, 0, 2)
    var attributes: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Signals the parent ignores stay ignored across exec; the child should start with the defaults.
    var defaults = sigset_t(), none = sigset_t()
    sigfillset(&defaults); sigemptyset(&none)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setsigmask(&attributes, &none)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

    let cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    let cenv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { cargs.forEach { free($0) }; cenv.forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, command, &actions, &attributes, cargs, cenv)
    close(slave)
    guard rc == 0 else { close(master); logLine("posix_spawn failed rc=\(rc) command=\(command)"); return nil }
    return PTYChild(master: master, pid: pid)
}

func setWindowSize(_ master: Int32, cols: UInt16, rows: UInt16) {
    var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
    _ = ioctl(master, TIOCSWINSZ, &size)
}

/// Decodes a `waitpid` status: the exit code, or the negated signal number when the child was killed.
func decodeExitStatus(_ status: Int32) -> Int32 {
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : -signal
}
