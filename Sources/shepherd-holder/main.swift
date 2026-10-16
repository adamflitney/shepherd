import Foundation
import Darwin
import ShepherdHolder

// shepherd-holder: owns one agent session on a PTY (`hold`, started by the launcher) and drives holders from the
// command line (everything else). The CLI is the proof for the holder library until the app's backend uses it.

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    usage: shepherd-holder <command>
      spawn [--claude [--sid <uuid>]] [--task <n>] [--cwd <dir>] [--cols n] [--rows n] [--allow-shell] [-- cmd args...]
      list                     every session and whether its holder is live, interrupted or ended
      attach <id>              interactive; Ctrl-\\ detaches
      send <id> <text>         type text (\\r \\n \\e \\t \\c escapes) into a session
      dump <id>                print the replay buffer
      kill <id>                end a session
      resume <id>              bring an interrupted claude session back with --resume
      restore                  resume every interrupted claude session
      remove <id>              forget a session and delete its files
    environment: SHEPHERD_HOME (default ~/.shepherd) holds sessions/
    """)
    exit(2)
}

func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: "--\(name)"), i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") else { return nil }
    return arguments[i + 1]
}
func flag(_ name: String) -> Bool { arguments.contains("--\(name)") }

func selfPath() -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    var size = UInt32(buf.count)
    _NSGetExecutablePath(&buf, &size)
    return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
}

func claudePath() -> String {
    let home = NSHomeDirectory()
    let fromPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
    let usual = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    return (fromPath + usual).first { FileManager.default.isExecutableFile(atPath: $0) } ?? "claude"
}

func unescape(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var it = Array(s.utf8).makeIterator()
    while let b = it.next() {
        if b == 92, let n = it.next() {
            switch n {
            case UInt8(ascii: "r"): out.append(13)
            case UInt8(ascii: "n"): out.append(10)
            case UInt8(ascii: "e"): out.append(27)
            case UInt8(ascii: "t"): out.append(9)
            case UInt8(ascii: "c"): out.append(3)
            case UInt8(ascii: "\\"): out.append(92)
            default: out.append(b); out.append(n)
            }
        } else { out.append(b) }
    }
    return out
}

let registry: SessionRegistry = {
    if let dir = option("registry") { return SessionRegistry(directory: URL(fileURLWithPath: dir)) }
    return .standard
}()
let launcher = HolderLauncher(registry: registry, holderExecutable: selfPath(), allowShell: flag("allow-shell"))

func record(_ id: String?) -> SessionRecord {
    guard let id, let r = registry.load(id) else { print("no such session"); exit(1) }
    return r
}

guard let command = arguments.first else { usage() }
switch command {
case "hold":
    guard let dir = option("registry"), let id = option("id") else { usage() }
    exit(HolderProcess.run(registryDirectory: dir, id: id))

case "spawn":
    var argv = arguments.firstIndex(of: "--").map { Array(arguments[($0 + 1)...]) } ?? []
    let cwd = option("cwd") ?? FileManager.default.currentDirectoryPath
    let id = SessionSpec.newID()
    var env: [String: String] = [:]
    let task = option("task").flatMap(Int.init)
    var sid: String?
    if flag("claude") {
        sid = option("sid") ?? UUID().uuidString.lowercased()
        argv = ClaudeCommand.argv(claudePath: claudePath(), sessionID: sid!, resume: false, extra: argv)
        if let task { env["SHEPHERD_TASK_ID"] = String(task) }
        env["SHEPHERD_SESSION_ID"] = sid
    }
    let spec = SessionSpec(id: id, taskID: task, agent: flag("claude") ? .claude : .shell, claudeSessionID: sid, cwd: cwd, argv: argv, env: env,
                           cols: option("cols").flatMap(Int.init) ?? 100, rows: option("rows").flatMap(Int.init) ?? 30)
    do { print(try launcher.launch(spec).id) } catch { print("error: \(error)"); exit(1) }

case "list":
    for r in registry.all() {
        let live = registry.liveness(r)
        let task = r.taskID.map { "task \($0)" } ?? "no task"
        print("\(r.id)  \(live)  \(r.state.rawValue)  \(task)  \(r.agent.rawValue)  \(r.cwd)")
    }

case "send":
    guard arguments.count >= 3 else { usage() }
    guard let a = HolderClient.attach(socketPath: registry.socketPath(arguments[1])) else { print("cannot attach"); exit(1) }
    a.send(unescape(arguments[2]))
    usleep(200_000)
    a.detach()

case "dump":
    guard arguments.count >= 2, let bytes = HolderClient.dump(socketPath: registry.socketPath(arguments[1])) else { print("dump failed"); exit(1) }
    FileHandle.standardOutput.write(Data(bytes))

case "kill":
    guard arguments.count >= 2 else { usage() }
    print(HolderClient.kill(socketPath: registry.socketPath(arguments[1])) ? "killed" : "unreachable")

case "resume":
    guard arguments.count >= 2 else { usage() }
    do { print(try launcher.resume(arguments[1], claudePath: claudePath()).id) } catch { print("error: \(error)"); exit(1) }

case "restore":
    for r in registry.all() where registry.liveness(r) == .interrupted && r.agent == .claude {
        do { print("resumed \(try launcher.resume(r.id, claudePath: claudePath()).id)") } catch { print("could not resume \(r.id): \(error)") }
    }

case "remove":
    guard arguments.count >= 2 else { usage() }
    registry.remove(arguments[1])

case "attach":
    guard arguments.count >= 2 else { usage() }
    var size = winsize()
    _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
    guard let a = HolderClient.attach(socketPath: registry.socketPath(arguments[1]), cols: Int(size.ws_col), rows: Int(size.ws_row)) else { print("cannot attach"); exit(1) }
    var original = termios()
    tcgetattr(STDIN_FILENO, &original)
    var raw = original
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    defer { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
    FileHandle.standardOutput.write(Data(ShepherdHolder.ModeTracker.restoreSequence(for: a.modes)))
    FileHandle.standardOutput.write(Data(a.replay))
    a.forceRedraw()
    var buf = [UInt8](repeating: 0, count: 4096)
    loop: while true {
        var fds = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0), pollfd(fd: a.fileDescriptor, events: Int16(POLLIN), revents: 0)]
        _ = poll(&fds, 2, -1)
        if fds[0].revents != 0 {
            let n = read(STDIN_FILENO, &buf, buf.count)
            if n <= 0 { break }
            if buf[0..<n].contains(0x1c) { a.detach(); break loop }
            a.send(Array(buf[0..<n]))
        }
        if fds[1].revents != 0 {
            guard let chunk = a.read(timeoutMs: 0), !chunk.isEmpty else { break }
            FileHandle.standardOutput.write(Data(chunk))
        }
    }
    print("\r\n[detached]")

default:
    usage()
}
